import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto.dart';
import 'transfer_manifest.dart';
import 'transfer_state_store.dart';
import 'transport.dart';

const String uploadDirection = 'upload';
const String downloadDirection = 'download';

const String statusQueued = 'queued';
const String statusUploading = 'uploading';
const String statusPaused = 'paused';
const String statusCompleted = 'completed';
const String statusFailed = 'failed';
const String statusDownloading = 'downloading';

class TransferFile {
  TransferFile({
    required this.id,
    required this.name,
    required this.bytes,
    required this.payloadKind,
    required this.mimeType,
    this.textTitle,
  });

  final String id;
  final String name;
  final Uint8List bytes;
  final String payloadKind;
  final String mimeType;
  final String? textTitle;
}

class TransferCoordinator {
  TransferCoordinator({
    required Transport transport,
    required TransferStateStore store,
    void Function(TransferState state)? onState,
  })  : _transport = transport,
        _store = store,
        _onState = onState;

  final Transport _transport;
  final TransferStateStore _store;
  final void Function(TransferState state)? _onState;
  final List<_TransferJob> _queue = [];
  final Map<String, BytesBuilder> _partialDownloads = {};
  bool _paused = false;
  bool _running = false;

  bool get isPaused => _paused;
  bool get isRunning => _running;
  List<_TransferJob> get queue => List.unmodifiable(_queue);

  void enqueueUploads({
    required List<TransferFile> files,
    required String sessionId,
    required String transferToken,
    required SimplePublicKey receiverPublicKey,
    required KeyPair senderKeyPair,
    int chunkSize = 64 * 1024,
  }) {
    for (final file in files) {
      _queue.add(
        _TransferJob(
          file: file,
          sessionId: sessionId,
          transferToken: transferToken,
          receiverPublicKey: receiverPublicKey,
          senderKeyPair: senderKeyPair,
          chunkSize: chunkSize,
        ),
      );
    }
  }

  Future<void> runQueue() async {
    if (_running) {
      return;
    }
    _running = true;
    while (_queue.isNotEmpty) {
      if (_paused) {
        break;
      }
      final job = _queue.first;
      final completed = await _uploadJob(job);
      if (completed) {
        _queue.removeAt(0);
      } else {
        break;
      }
    }
    _running = false;
  }

  void pause() {
    _paused = true;
  }

  Future<void> resume() async {
    if (!_paused) {
      return;
    }
    _paused = false;
    await runQueue();
  }

  Future<void> sendReceipt({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    return _transport.sendReceipt(
      sessionId: sessionId,
      transferId: transferId,
      transferToken: transferToken,
    );
  }

  Future<TransferDownloadResult?> downloadTransfer({
    required String sessionId,
    required String transferToken,
    required String transferId,
    required SimplePublicKey senderPublicKey,
    required KeyPair receiverKeyPair,
    bool sendReceipt = false,
  }) async {
    final existing = await _store.load(transferId);
    final state = existing ??
        TransferState(
          transferId: transferId,
          sessionId: sessionId,
          transferToken: transferToken,
          direction: downloadDirection,
          status: statusDownloading,
          totalBytes: 0,
          chunkSize: 0,
          nextOffset: 0,
          nextChunkIndex: 0,
        );

    final manifestBytes = await _transport.fetchManifest(
      sessionId: sessionId,
      transferId: transferId,
      transferToken: transferToken,
    );
    final manifestPayload = parseEncryptedPayload(manifestBytes);
    final sessionKey = await deriveSessionKey(
      localKeyPair: receiverKeyPair,
      peerPublicKey: senderPublicKey,
      sessionId: sessionId,
    );
    final manifestPlaintext = await decryptManifest(
      sessionKey: sessionKey,
      sessionId: sessionId,
      transferId: transferId,
      payload: manifestPayload,
    );
    final manifestJson =
        jsonDecode(utf8.decode(manifestPlaintext)) as Map<String, dynamic>;
    final manifest = TransferManifest.fromJson(manifestJson);
    final totalBytes = manifest.totalBytes;
    final chunkSize = manifest.chunkSize;

    var nextOffset = state.nextOffset;
    var nextChunkIndex = state.nextChunkIndex;
    await _saveState(state.copyWith(
      totalBytes: totalBytes,
      chunkSize: chunkSize,
      status: statusDownloading,
    ));

    final builder = _partialDownloads.putIfAbsent(
      transferId,
      () => BytesBuilder(copy: false),
    );
    final totalChunks = chunkSize == 0
        ? 0
        : (totalBytes + chunkSize - 1) ~/ chunkSize;
    while (nextChunkIndex < totalChunks) {
      if (_paused) {
        await _saveState(state.copyWith(
          status: statusPaused,
          nextOffset: nextOffset,
          nextChunkIndex: nextChunkIndex,
        ));
        return null;
      }
      final remaining = totalBytes - (nextChunkIndex * chunkSize);
      if (remaining <= 0) {
        break;
      }
      final plaintextLength = remaining < chunkSize ? remaining : chunkSize;
      final encryptedLength = plaintextLength + _cipherOverhead();
      final encryptedChunk = await _transport.fetchRange(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        offset: nextOffset,
        length: encryptedLength,
      );
      final payload = parseEncryptedPayload(encryptedChunk);
      final plaintext = await decryptChunk(
        sessionKey: sessionKey,
        sessionId: sessionId,
        transferId: transferId,
        chunkIndex: nextChunkIndex,
        payload: payload,
      );
      builder.add(plaintext);
      nextOffset += encryptedLength;
      nextChunkIndex += 1;
      await _saveState(state.copyWith(
        nextOffset: nextOffset,
        nextChunkIndex: nextChunkIndex,
      ));
    }

    final fileBytes = builder.toBytes();
    if (fileBytes.length != totalBytes) {
      await _saveState(state.copyWith(status: statusFailed));
      return null;
    }

    if (sendReceipt) {
      await _transport.sendReceipt(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
      );
    }
    await _saveState(state.copyWith(status: statusCompleted));
    _partialDownloads.remove(transferId);
    return TransferDownloadResult(
      manifest: manifest,
      bytes: fileBytes,
      transferId: transferId,
    );
  }

  Future<bool> _uploadJob(_TransferJob job) async {
    var transferId = job.transferId;
    final existing =
        await _store.load(transferId ?? job.file.id);
    final state = existing ??
        TransferState(
          transferId: transferId ?? job.file.id,
          sessionId: job.sessionId,
          transferToken: job.transferToken,
          direction: uploadDirection,
          status: statusQueued,
          totalBytes: job.file.bytes.length,
          chunkSize: job.chunkSize,
          nextOffset: 0,
          nextChunkIndex: 0,
        );

    final sessionKey = await deriveSessionKey(
      localKeyPair: job.senderKeyPair,
      peerPublicKey: job.receiverPublicKey,
      sessionId: job.sessionId,
    );

    if (transferId == null) {
      transferId = state.transferId;
      final manifest = TransferManifest(
        transferId: transferId,
        payloadKind: job.file.payloadKind,
        totalBytes: job.file.bytes.length,
        chunkSize: job.chunkSize,
        files: job.file.payloadKind == payloadKindText
            ? const []
            : [
                TransferManifestFile(
                  name: job.file.name,
                  bytes: job.file.bytes.length,
                  mime: job.file.mimeType,
                ),
              ],
        textTitle: job.file.payloadKind == payloadKindText
            ? job.file.textTitle
            : null,
        textMime:
            job.file.payloadKind == payloadKindText ? textMimePlain : null,
        textLength: job.file.payloadKind == payloadKindText
            ? job.file.bytes.length
            : null,
      );
      final manifestJson = jsonEncode(manifest.toJson());
      final manifestPayload = await encryptManifest(
        sessionKey: sessionKey,
        sessionId: job.sessionId,
        transferId: transferId,
        plaintext: Uint8List.fromList(utf8.encode(manifestJson)),
      );
      final manifestBytes = serializeEncryptedPayload(manifestPayload);
      final initResult = await _transport.initTransfer(
        sessionId: job.sessionId,
        transferToken: job.transferToken,
        manifestCiphertext: manifestBytes,
        totalBytes: job.file.bytes.length,
        transferId: transferId,
      );
      transferId = initResult.transferId;
      job.transferId = transferId;
      await _saveState(state.copyWith(
        transferId: transferId,
        status: statusUploading,
      ));
    }

    var nextOffset = state.nextOffset;
    var nextChunkIndex = state.nextChunkIndex;
    final totalChunks = job.chunkSize == 0
        ? 0
        : (job.file.bytes.length + job.chunkSize - 1) ~/ job.chunkSize;
    while (nextChunkIndex < totalChunks) {
      if (_paused) {
        await _saveState(state.copyWith(
          status: statusPaused,
          nextOffset: nextOffset,
          nextChunkIndex: nextChunkIndex,
        ));
        return false;
      }

      final remaining = job.file.bytes.length - (nextChunkIndex * job.chunkSize);
      if (remaining <= 0) {
        break;
      }
      final plaintextLength =
          remaining < job.chunkSize ? remaining : job.chunkSize;
      final end = (nextChunkIndex * job.chunkSize) + plaintextLength;
      final chunk = Uint8List.sublistView(
        job.file.bytes,
        nextChunkIndex * job.chunkSize,
        end,
      );
      final encrypted = await encryptChunk(
        sessionKey: sessionKey,
        sessionId: job.sessionId,
        transferId: transferId,
        chunkIndex: nextChunkIndex,
        plaintext: chunk,
      );
      final payload = serializeEncryptedPayload(encrypted);
      await _transport.sendChunk(
        sessionId: job.sessionId,
        transferId: transferId,
        transferToken: job.transferToken,
        offset: nextOffset,
        data: payload,
      );
      nextOffset += payload.length;
      nextChunkIndex += 1;
      await _saveState(state.copyWith(
        status: statusUploading,
        nextOffset: nextOffset,
        nextChunkIndex: nextChunkIndex,
      ));
    }

    await _transport.finalizeTransfer(
      sessionId: job.sessionId,
      transferId: transferId,
      transferToken: job.transferToken,
    );
    await _saveState(state.copyWith(status: statusCompleted));
    return true;
  }

  Future<void> _saveState(TransferState state) async {
    await _store.save(state);
    _onState?.call(state);
  }

  int _cipherOverhead() => 12 + 16;
}

class _TransferJob {
  _TransferJob({
    required this.file,
    required this.sessionId,
    required this.transferToken,
    required this.receiverPublicKey,
    required this.senderKeyPair,
    required this.chunkSize,
    this.transferId,
  });

  final TransferFile file;
  final String sessionId;
  final String transferToken;
  final SimplePublicKey receiverPublicKey;
  final KeyPair senderKeyPair;
  final int chunkSize;
  String? transferId;
}

class TransferDownloadResult {
  TransferDownloadResult({
    required this.manifest,
    required this.bytes,
    required this.transferId,
  });

  final TransferManifest manifest;
  final Uint8List bytes;
  final String transferId;
}
