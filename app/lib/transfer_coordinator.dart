import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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
    required this.packagingMode,
    this.textTitle,
    this.packageTitle,
    this.entries = const [],
  });

  final String id;
  final String name;
  final Uint8List bytes;
  final String payloadKind;
  final String mimeType;
  final String packagingMode;
  final String? textTitle;
  final String? packageTitle;
  final List<TransferManifestFile> entries;
}

class TransferCoordinator {
  TransferCoordinator({
    required Transport transport,
    required TransferStateStore store,
    void Function(TransferState state)? onState,
    void Function(String transferId, String status)? onScanStatus,
  })  : _transport = transport,
        _store = store,
        _onState = onState,
        _onScanStatus = onScanStatus;

  final Transport _transport;
  final TransferStateStore _store;
  final void Function(TransferState state)? _onState;
  final void Function(String transferId, String status)? _onScanStatus;
  final List<_TransferJob> _queue = [];
  final Map<String, BytesBuilder> _partialDownloads = {};
  final Map<String, DateTime> _lastProgressAt = {};
  final Random _jitter = Random();
  bool _paused = false;
  bool _running = false;
  int _preferredChunkSize = _defaultChunkSize;

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
    bool scanRequired = false,
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
          scanRequired: scanRequired,
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

    Uint8List manifestBytes;
    try {
      manifestBytes = await _withRetry(
        transferId: transferId,
        action: () => _transport.fetchManifest(
          sessionId: sessionId,
          transferId: transferId,
          transferToken: transferToken,
        ),
      );
    } catch (err) {
      await _saveState(state.copyWith(status: statusFailed));
      return null;
    }
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
      final startedAt = DateTime.now();
      Uint8List encryptedChunk;
      try {
        encryptedChunk = await _withRetry(
          transferId: transferId,
          maxRetries: _maxChunkRetries,
          onStallLimit: () async {
            nextOffset = _encryptedOffsetForChunk(nextChunkIndex, chunkSize);
            await _saveState(state.copyWith(
              status: statusPaused,
              nextOffset: nextOffset,
              nextChunkIndex: nextChunkIndex,
            ));
            _paused = true;
          },
          action: () => _transport.fetchRange(
            sessionId: sessionId,
            transferId: transferId,
            transferToken: transferToken,
            offset: nextOffset,
            length: encryptedLength,
          ),
        );
      } catch (err) {
        final transient = _isTransient(err);
        await _saveState(state.copyWith(
          status: transient ? statusPaused : statusFailed,
          nextOffset: nextOffset,
          nextChunkIndex: nextChunkIndex,
        ));
        if (transient) {
          _paused = true;
        }
        return null;
      }
      final payload = parseEncryptedPayload(encryptedChunk);
      final plaintext = await decryptChunk(
        sessionKey: sessionKey,
        sessionId: sessionId,
        transferId: transferId,
        chunkIndex: nextChunkIndex,
        payload: payload,
      );
      builder.add(plaintext);
      _recordThroughput(plaintextLength, DateTime.now().difference(startedAt));
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
      try {
        await _withRetry(
          transferId: transferId,
          action: () => _transport.sendReceipt(
            sessionId: sessionId,
            transferId: transferId,
            transferToken: transferToken,
          ),
        );
      } catch (_) {
        await _saveState(state.copyWith(status: statusFailed));
        return null;
      }
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
    final existing = await _store.load(transferId ?? job.file.id);
    final resumeChunkSize = existing?.chunkSize ?? 0;
    final effectiveChunkSize =
        resumeChunkSize > 0 ? resumeChunkSize : _chooseChunkSize(job.chunkSize);
    final state = existing ??
        TransferState(
          transferId: transferId ?? job.file.id,
          sessionId: job.sessionId,
          transferToken: job.transferToken,
          direction: uploadDirection,
          status: statusQueued,
          totalBytes: job.file.bytes.length,
          chunkSize: effectiveChunkSize,
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
      final manifestEntries = job.file.entries.isNotEmpty
          ? job.file.entries
          : [
              TransferManifestFile(
                relativePath: job.file.name,
                mediaType: mediaTypeFromMime(job.file.mimeType),
                sizeBytes: job.file.bytes.length,
                originalFilename: job.file.name,
                mime: job.file.mimeType,
              ),
            ];
      final packageTitle = job.file.packageTitle ?? job.file.name;
      final manifest = TransferManifest(
        transferId: transferId,
        payloadKind: job.file.payloadKind,
        packagingMode: job.file.packagingMode,
        packageTitle: packageTitle,
        totalBytes: job.file.bytes.length,
        chunkSize: effectiveChunkSize,
        files: job.file.payloadKind == payloadKindText
            ? const []
            : manifestEntries,
        textTitle: job.file.payloadKind == payloadKindText
            ? job.file.textTitle
            : null,
        textMime:
            job.file.payloadKind == payloadKindText ? textMimePlain : null,
        textLength: job.file.payloadKind == payloadKindText
            ? job.file.bytes.length
            : null,
        outputFilename:
            job.file.payloadKind == payloadKindZip ? job.file.name : null,
        albumTitle:
            job.file.payloadKind == payloadKindAlbum ? packageTitle : null,
        albumItemCount: job.file.payloadKind == payloadKindAlbum
            ? manifestEntries.length
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
      TransferInitResult initResult;
      final initKey = transferId ?? state.transferId;
      try {
        initResult = await _withRetry(
          transferId: initKey,
          action: () => _transport.initTransfer(
            sessionId: job.sessionId,
            transferToken: job.transferToken,
            manifestCiphertext: manifestBytes,
            totalBytes: job.file.bytes.length,
            transferId: transferId,
          ),
        );
      } catch (err) {
        final transient = _isTransient(err);
        await _saveState(state.copyWith(
          status: transient ? statusPaused : statusFailed,
        ));
        if (transient) {
          _paused = true;
        }
        return false;
      }
      transferId = initResult.transferId;
      job.transferId = transferId;
      await _saveState(state.copyWith(
        transferId: transferId,
        status: statusUploading,
        chunkSize: effectiveChunkSize,
      ));
    }

    var nextOffset = state.nextOffset;
    var nextChunkIndex = state.nextChunkIndex;
    final totalChunks = effectiveChunkSize == 0
        ? 0
        : (job.file.bytes.length + effectiveChunkSize - 1) ~/ effectiveChunkSize;
    while (nextChunkIndex < totalChunks) {
      if (_paused) {
        await _saveState(state.copyWith(
          status: statusPaused,
          nextOffset: nextOffset,
          nextChunkIndex: nextChunkIndex,
        ));
        return false;
      }

      final remaining =
          job.file.bytes.length - (nextChunkIndex * effectiveChunkSize);
      if (remaining <= 0) {
        break;
      }
      final plaintextLength =
          remaining < effectiveChunkSize ? remaining : effectiveChunkSize;
      final end = (nextChunkIndex * effectiveChunkSize) + plaintextLength;
      final chunk = Uint8List.sublistView(
        job.file.bytes,
        nextChunkIndex * effectiveChunkSize,
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
      final startedAt = DateTime.now();
      try {
        await _withRetry(
          transferId: transferId,
          maxRetries: _maxChunkRetries,
          action: () => _transport.sendChunk(
            sessionId: job.sessionId,
            transferId: transferId,
            transferToken: job.transferToken,
            offset: nextOffset,
            data: payload,
          ),
        );
      } catch (err) {
        final transient = _isTransient(err);
        await _saveState(state.copyWith(
          status: transient ? statusPaused : statusFailed,
          nextOffset: nextOffset,
          nextChunkIndex: nextChunkIndex,
        ));
        if (transient) {
          _paused = true;
        }
        return false;
      }
      _recordThroughput(plaintextLength, DateTime.now().difference(startedAt));
      nextOffset += payload.length;
      nextChunkIndex += 1;
      await _saveState(state.copyWith(
        status: statusUploading,
        nextOffset: nextOffset,
        nextChunkIndex: nextChunkIndex,
        chunkSize: effectiveChunkSize,
      ));
    }

    try {
      await _withRetry(
        transferId: transferId,
        action: () => _transport.finalizeTransfer(
          sessionId: job.sessionId,
          transferId: transferId,
          transferToken: job.transferToken,
        ),
      );
    } catch (err) {
      final transient = _isTransient(err);
      await _saveState(state.copyWith(
        status: transient ? statusPaused : statusFailed,
      ));
      if (transient) {
        _paused = true;
      }
      return false;
    }
    if (job.scanRequired) {
      final status = await _uploadScanCopy(
        job: job,
        transferId: transferId,
        chunkSize: effectiveChunkSize,
      );
      _onScanStatus?.call(transferId, status);
    }
    await _saveState(state.copyWith(status: statusCompleted));
    return true;
  }

  Future<String> _uploadScanCopy({
    required _TransferJob job,
    required String transferId,
    required int chunkSize,
  }) async {
    final totalBytes = job.file.bytes.length;
    final scanInit = await _withRetry(
      transferId: transferId,
      action: () => _transport.scanInit(
        sessionId: job.sessionId,
        transferId: transferId,
        transferToken: job.transferToken,
        totalBytes: totalBytes,
        chunkSize: chunkSize,
      ),
    );
    final scanKey = base64Decode(scanInit.scanKeyB64);
    var chunkIndex = 0;
    for (var offset = 0; offset < totalBytes; offset += chunkSize) {
      if (_paused) {
        return 'paused';
      }
      final end = (offset + chunkSize).clamp(0, totalBytes);
      final chunk = Uint8List.sublistView(job.file.bytes, offset, end);
      final encrypted = await encryptScanChunk(
        scanKey: scanKey,
        chunkIndex: chunkIndex,
        plaintext: chunk,
      );
      await _withRetry(
        transferId: transferId,
        maxRetries: _maxChunkRetries,
        action: () => _transport.scanChunk(
          scanId: scanInit.scanId,
          transferToken: job.transferToken,
          chunkIndex: chunkIndex,
          data: encrypted,
        ),
      );
      chunkIndex += 1;
    }
    final finalize = await _withRetry(
      transferId: transferId,
      action: () => _transport.scanFinalize(
        scanId: scanInit.scanId,
        transferToken: job.transferToken,
      ),
    );
    return finalize.status;
  }

  Future<void> _saveState(TransferState state) async {
    await _store.save(state);
    _onState?.call(state);
  }

  int _cipherOverhead() => 12 + 16;

  int _encryptedOffsetForChunk(int chunkIndex, int chunkSize) {
    return chunkIndex * (chunkSize + _cipherOverhead());
  }

  Future<T> _withRetry<T>({
    required String transferId,
    required Future<T> Function() action,
    int maxRetries = _maxRequestRetries,
    Duration timeout = _stallTimeout,
    Future<void> Function()? onStallLimit,
  }) async {
    var attempt = 0;
    var stallCount = 0;
    var stallFallbackTriggered = false;
    while (true) {
      final lastProgress = _lastProgressAt[transferId];
      if (lastProgress != null &&
          DateTime.now().difference(lastProgress) > timeout &&
          onStallLimit != null &&
          !stallFallbackTriggered) {
        stallFallbackTriggered = true;
        await onStallLimit();
      }
      attempt += 1;
      try {
        final result = await action().timeout(timeout);
        _lastProgressAt[transferId] = DateTime.now();
        return result;
      } on TimeoutException catch (_) {
        stallCount += 1;
        if (stallCount >= _stallFallbackThreshold &&
            onStallLimit != null &&
            !stallFallbackTriggered) {
          stallFallbackTriggered = true;
          await onStallLimit();
        }
        if (attempt > maxRetries) {
          rethrow;
        }
      } catch (err) {
        if (!_isTransient(err) || attempt > maxRetries) {
          rethrow;
        }
      }
      final delay = _backoffDelay(attempt);
      await Future.delayed(delay);
    }
  }

  Duration _backoffDelay(int attempt) {
    final baseMs = _baseBackoffMs * pow(2, attempt - 1);
    final capped = baseMs > _maxBackoffMs ? _maxBackoffMs : baseMs;
    final jitter = 0.6 + _jitter.nextDouble() * 0.8;
    return Duration(milliseconds: (capped * jitter).round());
  }

  bool _isTransient(Object err) {
    if (err is TimeoutException) {
      return true;
    }
    if (err is SocketException) {
      return true;
    }
    if (err is TransportException) {
      final status = err.statusCode;
      if (status == null) {
        return true;
      }
      if (status == 408 || status == 429) {
        return true;
      }
      return status >= 500;
    }
    return true;
  }

  int _chooseChunkSize(int fallback) {
    final candidate =
        _preferredChunkSize > 0 ? _preferredChunkSize : fallback;
    return _closestTier(candidate > 0 ? candidate : _defaultChunkSize);
  }

  void _recordThroughput(int bytes, Duration elapsed) {
    if (bytes <= 0 || elapsed.inMilliseconds <= 0) {
      return;
    }
    final bytesPerSecond = bytes * 1000 / elapsed.inMilliseconds;
    _preferredChunkSize = _chunkSizeForThroughput(bytesPerSecond);
  }

  int _chunkSizeForThroughput(double bytesPerSecond) {
    if (bytesPerSecond < 128 * 1024) {
      return 32 * 1024;
    }
    if (bytesPerSecond < 512 * 1024) {
      return 128 * 1024;
    }
    if (bytesPerSecond < 2 * 1024 * 1024) {
      return 512 * 1024;
    }
    return 1024 * 1024;
  }

  int _closestTier(int value) {
    var closest = _chunkSizeTiers.first;
    var closestDiff = (value - closest).abs();
    for (final tier in _chunkSizeTiers.skip(1)) {
      final diff = (value - tier).abs();
      if (diff < closestDiff) {
        closest = tier;
        closestDiff = diff;
      }
    }
    return closest;
  }
}

const int _defaultChunkSize = 128 * 1024;
const List<int> _chunkSizeTiers = [
  32 * 1024,
  128 * 1024,
  512 * 1024,
  1024 * 1024,
];
const int _maxRequestRetries = 4;
const int _maxChunkRetries = 5;
const int _baseBackoffMs = 400;
const int _maxBackoffMs = 8000;
const int _stallFallbackThreshold = 3;
const Duration _stallTimeout = Duration(seconds: 15);

class _TransferJob {
  _TransferJob({
    required this.file,
    required this.sessionId,
    required this.transferToken,
    required this.receiverPublicKey,
    required this.senderKeyPair,
    required this.chunkSize,
    required this.scanRequired,
    this.transferId,
  });

  final TransferFile file;
  final String sessionId;
  final String transferToken;
  final SimplePublicKey receiverPublicKey;
  final KeyPair senderKeyPair;
  final int chunkSize;
  final bool scanRequired;
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
