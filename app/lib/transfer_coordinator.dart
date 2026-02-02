import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'crypto.dart';
import 'destination_preferences.dart';
import 'transfer/background_transfer.dart';
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
const String statusDecrypting = 'decrypting';

typedef P2PTransportFactory = P2PFallbackTransport Function(P2PContext context);

typedef BackgroundDestinationResolver = Future<SaveDestination?> Function(
  TransferManifest manifest,
  bool allowPrompt,
);

typedef DownloadResumeResolver = Future<DownloadResumeContext?> Function(
  TransferState state,
);

class TransferDownloadPolicy {
  const TransferDownloadPolicy({
    this.preferBackground = false,
    this.allowBackgroundOnAppBackground = true,
    this.backgroundThresholdBytes = _defaultBackgroundThresholdBytes,
    this.showNotificationDetails = false,
    this.destinationResolver,
    this.isAppInForeground,
  });

  final bool preferBackground;
  final bool allowBackgroundOnAppBackground;
  final int backgroundThresholdBytes;
  final bool showNotificationDetails;
  final BackgroundDestinationResolver? destinationResolver;
  final bool Function()? isAppInForeground;
}

class TransferSaveResult {
  const TransferSaveResult({
    required this.shouldSendReceipt,
    this.localPath,
  });

  final bool shouldSendReceipt;
  final String? localPath;
}

typedef TransferSaveHandler = Future<TransferSaveResult> Function(
  TransferManifest manifest,
  Uint8List bytes,
  TransferState state,
);

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
    this.localPath,
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
  final String? localPath;
}

class TransferCoordinator {
  TransferCoordinator({
    required Transport transport,
    required TransferStateStore store,
    Uri? baseUri,
    void Function(TransferState state)? onState,
    void Function(String transferId, String status)? onScanStatus,
    BackgroundTransferApi? backgroundTransfer,
    DownloadTokenStore? downloadTokenStore,
    TransferSaveHandler? saveHandler,
    DownloadResumeResolver? downloadResolver,
    P2PTransportFactory? p2pTransportFactory,
    Duration stallTimeout = _defaultStallTimeout,
    int stallFallbackThreshold = _defaultStallFallbackThreshold,
  })  : _transport = transport,
        _baseUri = baseUri ?? _inferBaseUri(transport),
        _store = store,
        _onState = onState,
        _onScanStatus = onScanStatus,
        _backgroundTransfer = backgroundTransfer ?? BackgroundTransferApiImpl(),
        _downloadTokenStore = downloadTokenStore ?? DownloadTokenStore(),
        _saveHandler = saveHandler,
        _downloadResolver = downloadResolver,
        _p2pTransportFactory = p2pTransportFactory,
        _stallTimeout = stallTimeout,
        _stallFallbackThreshold = stallFallbackThreshold {
    _backgroundTransfer.onBackgroundProgress(_handleBackgroundUpdate);
  }

  final Transport _transport;
  final Uri? _baseUri;
  final TransferStateStore _store;
  final void Function(TransferState state)? _onState;
  final void Function(String transferId, String status)? _onScanStatus;
  final BackgroundTransferApi _backgroundTransfer;
  final DownloadTokenStore _downloadTokenStore;
  final TransferSaveHandler? _saveHandler;
  final DownloadResumeResolver? _downloadResolver;
  final P2PTransportFactory? _p2pTransportFactory;
  final Duration _stallTimeout;
  final int _stallFallbackThreshold;
  final List<_TransferJob> _queue = [];
  final Map<String, BytesBuilder> _partialDownloads = {};
  final Map<String, DateTime> _lastProgressAt = {};
  final Map<String, P2PFallbackTransport> _p2pTransports = {};
  final Map<String, String> _taskIdToTransferId = {};
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
    P2PContext? p2pContext,
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
          p2pContext: p2pContext,
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

  Future<TransferManifest?> fetchManifest({
    required String sessionId,
    required String transferToken,
    required String transferId,
    required SimplePublicKey senderPublicKey,
    required KeyPair receiverKeyPair,
    P2PContext? p2pContext,
  }) async {
    final transport = _resolveTransport(p2pContext);
    final bundle = await _fetchManifestBundle(
      transport: transport,
      sessionId: sessionId,
      transferId: transferId,
      transferToken: transferToken,
      senderPublicKey: senderPublicKey,
      receiverKeyPair: receiverKeyPair,
    );
    return bundle?.manifest;
  }

  Future<TransferDownloadResult?> downloadTransfer({
    required String sessionId,
    required String transferToken,
    required String transferId,
    required SimplePublicKey senderPublicKey,
    required KeyPair receiverKeyPair,
    bool sendReceipt = false,
    P2PContext? p2pContext,
    TransferDownloadPolicy? downloadPolicy,
  }) async {
    final transport = _resolveTransport(p2pContext);
    final existing = await _store.load(transferId);
    final peerPubKeyB64 = publicKeyToBase64(senderPublicKey);
    var state = existing ??
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
          peerPublicKeyB64: peerPubKeyB64,
        );

    final manifestBundle = await _fetchManifestBundle(
      transport: transport,
      sessionId: sessionId,
      transferId: transferId,
      transferToken: transferToken,
      senderPublicKey: senderPublicKey,
      receiverKeyPair: receiverKeyPair,
    );
    if (manifestBundle == null) {
      state = state.copyWith(status: statusFailed);
      await _saveState(state);
      return null;
    }
    final manifest = manifestBundle.manifest;
    final sessionKey = manifestBundle.sessionKey;
    final totalBytes = manifest.totalBytes;
    final chunkSize = manifest.chunkSize;

    final policy = downloadPolicy ?? const TransferDownloadPolicy();
    final backgroundBlocked = state.requiresForegroundResume == true;
    final allowBackgroundSwitch = policy.allowBackgroundOnAppBackground &&
        policy.isAppInForeground != null &&
        !backgroundBlocked;
    final prefersBackground = policy.preferBackground && !backgroundBlocked;
    final shouldStartInBackground = prefersBackground ||
        (allowBackgroundSwitch &&
            !policy.isAppInForeground!.call() &&
            totalBytes >= policy.backgroundThresholdBytes);

    var nextOffset = state.nextOffset;
    var nextChunkIndex = state.nextChunkIndex;
    state = state.copyWith(
      totalBytes: totalBytes,
      chunkSize: chunkSize,
      status: statusDownloading,
      peerPublicKeyB64: state.peerPublicKeyB64 ?? peerPubKeyB64,
      manifestHashB64: manifestBundle.manifestHashB64,
      notificationLabel:
          state.notificationLabel ?? _notificationLabelForManifest(manifest),
    );
    await _saveState(state);

    if (shouldStartInBackground) {
      final started = await _startBackgroundDownload(
        state: state,
        manifest: manifest,
        sessionId: sessionId,
        transferToken: transferToken,
        policy: policy,
        allowPrompt: policy.isAppInForeground?.call() ?? true,
      );
      if (!started) {
        state = state.copyWith(
          status: statusPaused,
          requiresForegroundResume: true,
        );
        await _saveState(state);
      }
      return null;
    }

    RandomAccessFile? cipherSink;
    String? cipherPath;
    if (prefersBackground || allowBackgroundSwitch) {
      final paths = await _ciphertextPaths(transferId);
      cipherPath = state.ciphertextPath ?? paths.filePath;
      final file = File(cipherPath);
      await file.parent.create(recursive: true);
      var fileLength = await file.exists() ? await file.length() : 0;
      if (fileLength < nextOffset) {
        nextOffset = fileLength;
      }
      final alignedOffset =
          _alignCiphertextOffset(nextOffset, chunkSize, totalBytes);
      if (alignedOffset != nextOffset) {
        nextOffset = alignedOffset;
        await file.truncate(nextOffset);
        fileLength = nextOffset;
      }
      if (fileLength != nextOffset) {
        await file.truncate(nextOffset);
      }
      nextChunkIndex = _chunkIndexForOffset(nextOffset, chunkSize);
      cipherSink = await file.open(mode: FileMode.append);
      await cipherSink.setPosition(nextOffset);
      state = state.copyWith(
        ciphertextPath: cipherPath,
        ciphertextComplete: false,
        nextOffset: nextOffset,
        nextChunkIndex: nextChunkIndex,
      );
      await _saveState(state);
    }

    final builder = _partialDownloads.putIfAbsent(
      transferId,
      () => BytesBuilder(copy: false),
    );
    final totalChunks = chunkSize == 0
        ? 0
        : (totalBytes + chunkSize - 1) ~/ chunkSize;
    while (nextChunkIndex < totalChunks) {
      if (_paused) {
        await cipherSink?.close();
        state = state.copyWith(
          status: statusPaused,
          nextOffset: nextOffset,
          nextChunkIndex: nextChunkIndex,
        );
        await _saveState(state);
        return null;
      }
      if (allowBackgroundSwitch &&
          policy.isAppInForeground != null &&
          !policy.isAppInForeground!.call() &&
          totalBytes >= policy.backgroundThresholdBytes) {
        await cipherSink?.flush();
        await cipherSink?.close();
        final switched = await _startBackgroundDownload(
          state: state,
          manifest: manifest,
          sessionId: sessionId,
          transferToken: transferToken,
          policy: policy,
          allowPrompt: false,
        );
        if (!switched) {
          state = state.copyWith(
            status: statusPaused,
            requiresForegroundResume: true,
            nextOffset: nextOffset,
            nextChunkIndex: nextChunkIndex,
          );
          await _saveState(state);
        }
        return null;
      }
      _ensureFallbackSync(transport, transferId);
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
            if (_triggerFallback(transport, transferId)) {
              return;
            }
            nextOffset = _encryptedOffsetForChunk(nextChunkIndex, chunkSize);
            state = state.copyWith(
              status: statusPaused,
              nextOffset: nextOffset,
              nextChunkIndex: nextChunkIndex,
            );
            await _saveState(state);
            _paused = true;
          },
          action: () => transport.fetchRange(
            sessionId: sessionId,
            transferId: transferId,
            transferToken: transferToken,
            offset: nextOffset,
            length: encryptedLength,
          ),
        );
      } catch (err) {
        if (_triggerFallback(transport, transferId)) {
          continue;
        }
        final transient = _isTransient(err);
        state = state.copyWith(
          status: transient ? statusPaused : statusFailed,
          nextOffset: nextOffset,
          nextChunkIndex: nextChunkIndex,
        );
        await _saveState(state);
        if (transient) {
          _paused = true;
        }
        return null;
      }
      await cipherSink?.writeFrom(encryptedChunk);
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
      state = state.copyWith(
        nextOffset: nextOffset,
        nextChunkIndex: nextChunkIndex,
      );
      await _saveState(state);
    }

    await cipherSink?.close();
    final fileBytes = builder.toBytes();
    if (fileBytes.length != totalBytes) {
      state = state.copyWith(status: statusFailed);
      await _saveState(state);
      return null;
    }

    if (sendReceipt) {
      try {
        await _withRetry(
          transferId: transferId,
          action: () => transport.sendReceipt(
            sessionId: sessionId,
            transferId: transferId,
            transferToken: transferToken,
          ),
        );
      } catch (_) {
        state = state.copyWith(status: statusFailed);
        await _saveState(state);
        return null;
      }
    }
    state = state.copyWith(status: statusCompleted);
    await _saveState(state);
    _partialDownloads.remove(transferId);
    if (cipherPath != null) {
      await _deleteCiphertextFile(cipherPath);
    }
    return TransferDownloadResult(
      manifest: manifest,
      bytes: fileBytes,
      transferId: transferId,
    );
  }

  Future<_ManifestBundle?> _fetchManifestBundle({
    required Transport transport,
    required String sessionId,
    required String transferId,
    required String transferToken,
    required SimplePublicKey senderPublicKey,
    required KeyPair receiverKeyPair,
  }) async {
    Uint8List manifestBytes;
    try {
      manifestBytes = await _withRetry(
        transferId: transferId,
        action: () => transport.fetchManifest(
          sessionId: sessionId,
          transferId: transferId,
          transferToken: transferToken,
        ),
      );
    } catch (_) {
      return null;
    }
    final manifestHashB64 = await _hashBytes(manifestBytes);
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
    return _ManifestBundle(
      manifest: manifest,
      sessionKey: sessionKey,
      manifestHashB64: manifestHashB64,
    );
  }

  Future<bool> _startBackgroundDownload({
    required TransferState state,
    required TransferManifest manifest,
    required String sessionId,
    required String transferToken,
    required TransferDownloadPolicy policy,
    required bool allowPrompt,
  }) async {
    final destination =
        await _resolveBackgroundDestination(manifest, policy, allowPrompt);
    if (destination == null) {
      return false;
    }
    final label = state.notificationLabel ?? _notificationLabelForManifest(manifest);
    return _enqueueBackgroundDownload(
      state: state,
      sessionId: sessionId,
      transferToken: transferToken,
      totalBytes: manifest.totalBytes,
      chunkSize: manifest.chunkSize,
      destination: destination,
      notificationLabel: label,
      showNotificationDetails: policy.showNotificationDetails,
    );
  }

  Future<bool> _enqueueBackgroundDownload({
    required TransferState state,
    required String sessionId,
    required String transferToken,
    required int totalBytes,
    required int chunkSize,
    required SaveDestination destination,
    required String notificationLabel,
    required bool showNotificationDetails,
  }) async {
    final paths = await _ciphertextPaths(state.transferId);
    final cipherPath = state.ciphertextPath ?? paths.filePath;
    final file = File(cipherPath);
    await file.parent.create(recursive: true);
    final expectedCiphertext = _ciphertextLength(totalBytes, chunkSize);
    if (expectedCiphertext <= 0) {
      return false;
    }
    var offset = await file.exists() ? await file.length() : 0;
    offset = _alignCiphertextOffset(offset, chunkSize, totalBytes);
    if (offset > 0 && offset < expectedCiphertext) {
      await file.truncate(offset);
    }
    if (offset >= expectedCiphertext && expectedCiphertext > 0) {
      final updated = state.copyWith(
        ciphertextPath: cipherPath,
        ciphertextComplete: true,
        nextOffset: expectedCiphertext,
        nextChunkIndex: _chunkIndexForOffset(expectedCiphertext, chunkSize),
      );
      await _saveState(updated);
      await _decryptAndSaveCiphertext(updated);
      return true;
    }
    final token = await _ensureDownloadToken(state, forceRefresh: false);
    if (token == null) {
      return false;
    }
    final taskId =
        state.backgroundTaskId?.isNotEmpty == true ? state.backgroundTaskId! : 'dl_${state.transferId}';
    final downloadUri = _downloadUri(sessionId, state.transferId);
    if (downloadUri.toString().isEmpty) {
      return false;
    }
    final task = TransferTask(
      taskId: taskId,
      url: downloadUri.toString(),
      headers: {
        'download_token': token.token,
        'Range': 'bytes=$offset-${expectedCiphertext - 1}',
      },
      filename: paths.filename,
      directory: paths.relativeDirectory,
      displayName: notificationLabel,
      showNotificationDetails: showNotificationDetails,
    );
    final queued = await _backgroundTransfer.enqueueBackgroundDownload(task);
    if (!queued) {
      return false;
    }
    final updated = state.copyWith(
      status: statusDownloading,
      ciphertextPath: cipherPath,
      ciphertextComplete: false,
      backgroundTaskId: task.taskId,
      destination: destination.name,
      notificationLabel: notificationLabel,
      requiresForegroundResume: false,
      nextOffset: offset,
      nextChunkIndex: _chunkIndexForOffset(offset, chunkSize),
    );
    await _saveState(updated);
    return true;
  }

  Future<SaveDestination?> _resolveBackgroundDestination(
    TransferManifest manifest,
    TransferDownloadPolicy policy,
    bool allowPrompt,
  ) async {
    final resolver = policy.destinationResolver;
    if (resolver == null) {
      return null;
    }
    return resolver(manifest, allowPrompt);
  }

  Future<StoredDownloadToken?> _ensureDownloadToken(
    TransferState state, {
    required bool forceRefresh,
  }) async {
    final cached = await _downloadTokenStore.loadToken(state.transferId);
    if (!forceRefresh && cached != null && !cached.isExpired) {
      return cached;
    }
    if (state.sessionId.isEmpty || state.transferToken.isEmpty) {
      return null;
    }
    try {
      final token = await _transport.fetchDownloadToken(
        sessionId: state.sessionId,
        transferId: state.transferId,
        transferToken: state.transferToken,
      );
      await _downloadTokenStore.saveToken(
        transferId: state.transferId,
        token: token.token,
        expiresAt: token.expiresAt,
      );
      return StoredDownloadToken(
        token: token.token,
        expiresAt: token.expiresAt,
      );
    } catch (_) {
      return null;
    }
  }

  static Uri? _inferBaseUri(Transport transport) {
    if (transport is HttpTransport) {
      return transport.baseUri;
    }
    if (transport is BackgroundUrlSessionTransport) {
      return transport.baseUri;
    }
    return null;
  }

  Uri _downloadUri(String sessionId, String transferId) {
    final baseUri = _baseUri;
    if (baseUri == null) {
      return Uri();
    }
    return baseUri.replace(
      path: '/v1/transfer/download',
      queryParameters: {
        'session_id': sessionId,
        'transfer_id': transferId,
      },
    );
  }

  String _notificationLabelForManifest(TransferManifest manifest) {
    if (manifest.payloadKind == payloadKindText) {
      return manifest.textTitle?.trim().isNotEmpty == true
          ? manifest.textTitle!.trim()
          : 'Text transfer';
    }
    if (manifest.packagingMode == packagingModeAlbum) {
      return manifest.albumTitle?.trim().isNotEmpty == true
          ? manifest.albumTitle!.trim()
          : 'Album transfer';
    }
    if (manifest.packagingMode == packagingModeZip) {
      final name = manifest.outputFilename ?? manifest.packageTitle;
      if (name != null && name.trim().isNotEmpty) {
        return name.trim();
      }
    }
    if (manifest.files.isNotEmpty) {
      final name = manifest.files.first.relativePath;
      if (name.trim().isNotEmpty) {
        return name.trim();
      }
    }
    return 'Transfer';
  }

  Future<_CiphertextPaths> _ciphertextPaths(String transferId) async {
    final baseDir = await getApplicationSupportDirectory();
    final directoryPath = p.join(baseDir.path, _ciphertextDirName);
    final filename = '$transferId.cipher';
    final filePath = p.join(directoryPath, filename);
    return _CiphertextPaths(
      filePath: filePath,
      relativeDirectory: _ciphertextDirName,
      filename: filename,
    );
  }

  int _ciphertextLength(int totalBytes, int chunkSize) {
    if (totalBytes <= 0 || chunkSize <= 0) {
      return 0;
    }
    final totalChunks = (totalBytes + chunkSize - 1) ~/ chunkSize;
    if (totalChunks == 0) {
      return 0;
    }
    final lastPlaintext = totalBytes - ((totalChunks - 1) * chunkSize);
    return ((totalChunks - 1) * (chunkSize + _cipherOverhead())) +
        lastPlaintext +
        _cipherOverhead();
  }

  int _alignCiphertextOffset(int offset, int chunkSize, int totalBytes) {
    final maxOffset = _ciphertextLength(totalBytes, chunkSize);
    if (offset >= maxOffset) {
      return maxOffset;
    }
    if (offset <= 0 || chunkSize <= 0) {
      return 0;
    }
    final stride = chunkSize + _cipherOverhead();
    return offset - (offset % stride);
  }

  int _chunkIndexForOffset(int offset, int chunkSize) {
    if (chunkSize <= 0) {
      return 0;
    }
    final stride = chunkSize + _cipherOverhead();
    return offset ~/ stride;
  }

  void _handleBackgroundUpdate(BackgroundTransferUpdate update) {
    unawaited(_processBackgroundUpdate(update));
  }

  Future<void> _processBackgroundUpdate(BackgroundTransferUpdate update) async {
    final taskId = update.update.task.taskId;
    final transferId = await _resolveTransferId(taskId);
    if (transferId == null) {
      return;
    }
    final state = await _store.load(transferId);
    if (state == null || state.direction != downloadDirection) {
      return;
    }
    final statusUpdate = update.statusUpdate;
    if (statusUpdate != null) {
      await _handleBackgroundStatusUpdate(state, statusUpdate);
      return;
    }
    final progressUpdate = update.progressUpdate;
    if (progressUpdate != null) {
      await _handleBackgroundProgressUpdate(state, progressUpdate);
    }
  }

  Future<String?> _resolveTransferId(String taskId) async {
    final cached = _taskIdToTransferId[taskId];
    if (cached != null) {
      return cached;
    }
    final pending = await _store.listPending(direction: downloadDirection);
    for (final state in pending) {
      if (state.backgroundTaskId == taskId) {
        _taskIdToTransferId[taskId] = state.transferId;
        return state.transferId;
      }
    }
    return null;
  }

  Future<void> _handleBackgroundStatusUpdate(
    TransferState state,
    TaskStatusUpdate update,
  ) async {
    final status = update.status;
    if (status == TaskStatus.complete) {
      await _handleBackgroundComplete(state);
      return;
    }
    if (status == TaskStatus.failed || status == TaskStatus.notFound) {
      await _handleBackgroundFailure(state, update);
      return;
    }
    if (status == TaskStatus.canceled) {
      await _saveState(state.copyWith(
        status: statusPaused,
        requiresForegroundResume: true,
      ));
      return;
    }
    if (status == TaskStatus.paused) {
      await _saveState(state.copyWith(status: statusPaused));
      return;
    }
    if (status == TaskStatus.running ||
        status == TaskStatus.enqueued ||
        status == TaskStatus.waitingToRetry) {
      await _saveState(state.copyWith(status: statusDownloading));
    }
  }

  Future<void> _handleBackgroundProgressUpdate(
    TransferState state,
    TaskProgressUpdate update,
  ) async {
    final totalCiphertext =
        _ciphertextLength(state.totalBytes, state.chunkSize);
    final expected = update.hasExpectedFileSize
        ? update.expectedFileSize
        : totalCiphertext;
    if (expected <= 0 || update.progress < 0) {
      return;
    }
    final offset = (expected * update.progress).round();
    final aligned = _alignCiphertextOffset(
      offset,
      state.chunkSize,
      state.totalBytes,
    );
    await _saveState(state.copyWith(
      nextOffset: aligned,
      nextChunkIndex: _chunkIndexForOffset(aligned, state.chunkSize),
      status: statusDownloading,
    ));
  }

  Future<bool> _isBackgroundTaskActive(TransferState state) async {
    final taskId = state.backgroundTaskId;
    if (taskId == null || taskId.isEmpty) {
      return false;
    }
    final status = await _backgroundTransfer.queryBackgroundStatus(taskId);
    if (status == null) {
      return false;
    }
    return status.status.isNotFinalState;
  }

  Future<bool> _resumeIfCiphertextComplete(
    TransferState state,
    DownloadResumeContext context,
  ) async {
    final path = state.ciphertextPath;
    if (path == null || path.isEmpty) {
      return false;
    }
    var totalBytes = state.totalBytes;
    var chunkSize = state.chunkSize;
    if (totalBytes == 0 || chunkSize == 0) {
      final bundle = await _fetchManifestBundle(
        transport: _transport,
        sessionId: context.sessionId,
        transferId: context.transferId,
        transferToken: context.transferToken,
        senderPublicKey: context.senderPublicKey,
        receiverKeyPair: context.receiverKeyPair,
      );
      if (bundle == null) {
        return false;
      }
      totalBytes = bundle.manifest.totalBytes;
      chunkSize = bundle.manifest.chunkSize;
      final updated = state.copyWith(
        totalBytes: totalBytes,
        chunkSize: chunkSize,
        manifestHashB64: bundle.manifestHashB64,
      );
      await _saveState(updated);
      state = updated;
    }
    final expected = _ciphertextLength(totalBytes, chunkSize);
    if (expected == 0) {
      return false;
    }
    final file = File(path);
    if (!await file.exists()) {
      return false;
    }
    final length = await file.length();
    if (length < expected && state.ciphertextComplete != true) {
      return false;
    }
    final updated = state.copyWith(
      ciphertextComplete: true,
      nextOffset: expected,
      nextChunkIndex: _chunkIndexForOffset(expected, chunkSize),
    );
    await _saveState(updated);
    await _decryptAndSaveCiphertext(updated);
    return true;
  }

  Future<void> _handleBackgroundComplete(TransferState state) async {
    final path = state.ciphertextPath;
    if (path == null || path.isEmpty) {
      await _saveState(state.copyWith(
        status: statusPaused,
        requiresForegroundResume: true,
      ));
      return;
    }
    final expectedCiphertext =
        _ciphertextLength(state.totalBytes, state.chunkSize);
    if (expectedCiphertext > 0) {
      final file = File(path);
      if (!await file.exists()) {
        await _saveState(state.copyWith(
          status: statusPaused,
          requiresForegroundResume: true,
        ));
        return;
      }
      final length = await file.length();
      if (length < expectedCiphertext) {
        await _saveState(state.copyWith(
          status: statusPaused,
          requiresForegroundResume: true,
        ));
        return;
      }
    }
    final updated = state.copyWith(
      ciphertextComplete: true,
      nextOffset: expectedCiphertext,
      nextChunkIndex: _chunkIndexForOffset(expectedCiphertext, state.chunkSize),
    );
    await _saveState(updated);
    await _decryptAndSaveCiphertext(updated);
  }

  Future<void> _handleBackgroundFailure(
    TransferState state,
    TaskStatusUpdate update,
  ) async {
    if (state.requiresForegroundResume == true) {
      return;
    }
    final statusCode = update.responseStatusCode ?? 0;
    if (statusCode == 401 || statusCode == 403) {
      final failures = state.downloadTokenRefreshFailures ?? 0;
      if (failures >= _maxDownloadTokenRefreshFailures) {
        await _saveState(state.copyWith(
          status: statusPaused,
          requiresForegroundResume: true,
        ));
        return;
      }
      final refreshed =
          await _ensureDownloadToken(state, forceRefresh: true);
      if (refreshed == null) {
        await _saveState(state.copyWith(
          status: statusPaused,
          requiresForegroundResume: true,
        ));
        return;
      }
      final destination = _destinationFromState(state.destination) ??
          SaveDestination.files;
      final label = state.notificationLabel ?? 'Transfer';
      final retried = await _enqueueBackgroundDownload(
        state: state.copyWith(
          downloadTokenRefreshFailures: failures + 1,
        ),
        sessionId: state.sessionId,
        transferToken: state.transferToken,
        totalBytes: state.totalBytes,
        chunkSize: state.chunkSize,
        destination: destination,
        notificationLabel: label,
        showNotificationDetails: false,
      );
      if (!retried) {
        await _saveState(state.copyWith(
          status: statusPaused,
          requiresForegroundResume: true,
        ));
      }
      return;
    }
    await _saveState(state.copyWith(
      status: statusPaused,
      requiresForegroundResume: true,
    ));
  }

  Future<void> _decryptAndSaveCiphertext(TransferState state) async {
    final resolver = _downloadResolver;
    final saveHandler = _saveHandler;
    if (resolver == null || saveHandler == null) {
      await _saveState(state.copyWith(
        status: statusPaused,
        requiresForegroundResume: true,
      ));
      return;
    }
    final context = await resolver(state);
    if (context == null) {
      await _saveState(state.copyWith(
        status: statusPaused,
        requiresForegroundResume: true,
      ));
      return;
    }
    final manifestBundle = await _fetchManifestBundle(
      transport: _transport,
      sessionId: context.sessionId,
      transferId: context.transferId,
      transferToken: context.transferToken,
      senderPublicKey: context.senderPublicKey,
      receiverKeyPair: context.receiverKeyPair,
    );
    if (manifestBundle == null) {
      await _saveState(state.copyWith(status: statusFailed));
      return;
    }
    if (state.manifestHashB64 != null &&
        state.manifestHashB64!.isNotEmpty &&
        state.manifestHashB64 != manifestBundle.manifestHashB64) {
      await _saveState(state.copyWith(
        status: statusPaused,
        requiresForegroundResume: true,
      ));
      return;
    }
    final cipherPath = state.ciphertextPath;
    if (cipherPath == null || cipherPath.isEmpty) {
      await _saveState(state.copyWith(
        status: statusPaused,
        requiresForegroundResume: true,
      ));
      return;
    }
    final request = await _DecryptRequest.fromContext(
      context: context,
      transferId: state.transferId,
      ciphertextPath: cipherPath,
      totalBytes: manifestBundle.manifest.totalBytes,
      chunkSize: manifestBundle.manifest.chunkSize,
    );
    final decrypted =
        await Isolate.run(() => _decryptCiphertextIsolate(request));
    if (decrypted.length != manifestBundle.manifest.totalBytes) {
      await _saveState(state.copyWith(status: statusFailed));
      return;
    }
    await _saveState(state.copyWith(status: statusDecrypting));
    final result =
        await saveHandler(manifestBundle.manifest, decrypted, state);
    if (!result.shouldSendReceipt) {
      await _saveState(state.copyWith(
        status: statusPaused,
        requiresForegroundResume: true,
      ));
      return;
    }
    try {
      await _withRetry(
        transferId: state.transferId,
        action: () => _transport.sendReceipt(
          sessionId: context.sessionId,
          transferId: context.transferId,
          transferToken: context.transferToken,
        ),
      );
    } catch (_) {
      await _saveState(state.copyWith(status: statusFailed));
      return;
    }
    await _downloadTokenStore.deleteToken(state.transferId);
    await _deleteCiphertextFile(cipherPath);
    await _saveState(state.copyWith(status: statusCompleted));
  }

  SaveDestination? _destinationFromState(String? destination) {
    if (destination == null || destination.isEmpty) {
      return null;
    }
    for (final value in SaveDestination.values) {
      if (value.name == destination) {
        return value;
      }
    }
    return null;
  }

  Future<void> _deleteCiphertextFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<String> _hashBytes(Uint8List payload) async {
    final digest = await Sha256().hash(payload);
    return base64Encode(digest.bytes);
  }

  Future<bool> _uploadJob(_TransferJob job) async {
    var transferId = job.transferId;
    final transport = _resolveTransport(job.p2pContext);
    final existing = await _store.load(transferId ?? job.file.id);
    if (transferId == null && existing != null && existing.transferId.isNotEmpty) {
      transferId = existing.transferId;
      job.transferId = transferId;
    }
    final resumeChunkSize = existing?.chunkSize ?? 0;
    final effectiveChunkSize =
        resumeChunkSize > 0 ? resumeChunkSize : _chooseChunkSize(job.chunkSize);
    final receiverPubKeyB64 = publicKeyToBase64(job.receiverPublicKey);
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
          peerPublicKeyB64: receiverPubKeyB64,
          payloadPath: job.file.localPath,
          scanRequired: job.scanRequired,
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
          action: () => transport.initTransfer(
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
        peerPublicKeyB64: state.peerPublicKeyB64 ?? receiverPubKeyB64,
        payloadPath: state.payloadPath ?? job.file.localPath,
        scanRequired: state.scanRequired ?? job.scanRequired,
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
      _ensureFallbackSync(transport, transferId);

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
          onStallLimit: () async {
            _triggerFallback(transport, transferId);
          },
          action: () => transport.sendChunk(
            sessionId: job.sessionId,
            transferId: transferId,
            transferToken: job.transferToken,
            offset: nextOffset,
            data: payload,
          ),
        );
      } catch (err) {
        if (_triggerFallback(transport, transferId)) {
          continue;
        }
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
        peerPublicKeyB64: state.peerPublicKeyB64 ?? receiverPubKeyB64,
        payloadPath: state.payloadPath ?? job.file.localPath,
        scanRequired: state.scanRequired ?? job.scanRequired,
      ));
    }

    try {
      await _withRetry(
        transferId: transferId,
        action: () => transport.finalizeTransfer(
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
        transport: transport,
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
    required Transport transport,
  }) async {
    final totalBytes = job.file.bytes.length;
    final scanInit = await _withRetry(
      transferId: transferId,
      action: () => transport.scanInit(
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
        action: () => transport.scanChunk(
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
      action: () => transport.scanFinalize(
        scanId: scanInit.scanId,
        transferToken: job.transferToken,
      ),
    );
    return finalize.status;
  }

  Future<void> _saveState(TransferState state) async {
    final taskId = state.backgroundTaskId;
    if (taskId != null && taskId.isNotEmpty) {
      _taskIdToTransferId[taskId] = state.transferId;
    }
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
    Duration? timeout,
    Future<void> Function()? onStallLimit,
  }) async {
    final startedAt = DateTime.now();
    var attempt = 0;
    var stallCount = 0;
    var stallFallbackTriggered = false;
    final effectiveTimeout = timeout ?? _stallTimeout;
    while (true) {
      attempt += 1;
      try {
        final result = await action().timeout(effectiveTimeout);
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
        if (!_shouldRetry(const TimeoutException('timeout'), attempt, startedAt, maxRetries)) {
          rethrow;
        }
      } catch (err) {
        if (!_shouldRetry(err, attempt, startedAt, maxRetries)) {
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

  bool _shouldRetry(
    Object err,
    int attempt,
    DateTime startedAt,
    int maxRetries,
  ) {
    if (_classifyError(err) == _ErrorCategory.permanent) {
      return false;
    }
    if (attempt > maxRetries) {
      return false;
    }
    if (DateTime.now().difference(startedAt) > _maxRetryElapsed) {
      return false;
    }
    return true;
  }

  bool _isTransient(Object err) {
    return _classifyError(err) == _ErrorCategory.transient;
  }

  _ErrorCategory _classifyError(Object err) {
    if (err is TimeoutException) {
      return _ErrorCategory.transient;
    }
    if (err is SocketException) {
      return _ErrorCategory.transient;
    }
    if (_isConnectionReset(err)) {
      return _ErrorCategory.transient;
    }
    if (err is TransportException) {
      final status = err.statusCode;
      if (status == null) {
        return _ErrorCategory.transient;
      }
      if (status == 400 || status == 401 || status == 403 || status == 409) {
        return _ErrorCategory.permanent;
      }
      if (status == 429 || status == 503 || status == 408) {
        return _ErrorCategory.transient;
      }
      if (status >= 500) {
        return _ErrorCategory.transient;
      }
      return _ErrorCategory.transient;
    }
    return _ErrorCategory.transient;
  }

  bool _isConnectionReset(Object err) {
    final message = err.toString().toLowerCase();
    return message.contains('connection reset') ||
        message.contains('broken pipe') ||
        message.contains('connection abort');
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

  Transport _resolveTransport(P2PContext? p2pContext) {
    if (p2pContext == null || _p2pTransportFactory == null) {
      return _transport;
    }
    return _p2pTransports.putIfAbsent(
      p2pContext.cacheKey,
      () => _p2pTransportFactory!(p2pContext),
    );
  }

  void _ensureFallbackSync(Transport transport, String transferId) {
    if (transport is! P2PFallbackTransport) {
      return;
    }
    if (transport.isFallbackRequested(transferId)) {
      transport.forceFallback();
    }
  }

  bool _triggerFallback(Transport transport, String transferId) {
    if (transport is! P2PFallbackTransport) {
      return false;
    }
    if (transport.usingFallback) {
      return false;
    }
    transport.requestFallback(transferId);
    transport.forceFallback();
    return true;
  }

  Future<void> resumePendingDownloads({
    DownloadResumeResolver? resolve,
    bool sendReceipt = false,
    TransferDownloadPolicy? downloadPolicy,
  }) async {
    final resolver = resolve ?? _downloadResolver;
    if (resolver == null) {
      return;
    }
    final pending = await _store.listPending(direction: downloadDirection);
    for (final state in pending) {
      if (_paused) {
        break;
      }
      final context = await resolver(state);
      if (context == null) {
        continue;
      }
      final handled = await _resumeIfCiphertextComplete(state, context);
      if (handled) {
        continue;
      }
      if (await _isBackgroundTaskActive(state)) {
        continue;
      }
      await downloadTransfer(
        sessionId: context.sessionId,
        transferToken: context.transferToken,
        transferId: context.transferId,
        senderPublicKey: context.senderPublicKey,
        receiverKeyPair: context.receiverKeyPair,
        sendReceipt: sendReceipt,
        downloadPolicy: downloadPolicy,
      );
    }
  }

  Future<void> resumePendingUploads({
    required Future<UploadResumeContext?> Function(TransferState state) resolve,
  }) async {
    final pending = await _store.listPending(direction: uploadDirection);
    for (final state in pending) {
      if (_paused) {
        break;
      }
      final context = await resolve(state);
      if (context == null) {
        continue;
      }
      _queue.add(_TransferJob(
        file: context.file,
        sessionId: context.sessionId,
        transferToken: context.transferToken,
        receiverPublicKey: context.receiverPublicKey,
        senderKeyPair: context.senderKeyPair,
        chunkSize: context.chunkSize,
        scanRequired: context.scanRequired,
        transferId: context.transferId,
      ));
    }
    if (!_running) {
      await runQueue();
    }
  }
}

enum _ErrorCategory {
  transient,
  permanent,
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
const Duration _maxRetryElapsed = Duration(minutes: 2);
const int _defaultStallFallbackThreshold = 3;
// No progress within this duration is treated as a transient stall.
const Duration _defaultStallTimeout = Duration(seconds: 15);
const int _defaultBackgroundThresholdBytes = 8 * 1024 * 1024;
const String _ciphertextDirName = 'ciphertext';
const int _maxDownloadTokenRefreshFailures = 1;

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
    this.p2pContext,
  });

  final TransferFile file;
  final String sessionId;
  final String transferToken;
  final SimplePublicKey receiverPublicKey;
  final KeyPair senderKeyPair;
  final int chunkSize;
  final bool scanRequired;
  String? transferId;
  final P2PContext? p2pContext;
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

class DownloadResumeContext {
  DownloadResumeContext({
    required this.sessionId,
    required this.transferToken,
    required this.transferId,
    required this.senderPublicKey,
    required this.receiverKeyPair,
  });

  final String sessionId;
  final String transferToken;
  final String transferId;
  final SimplePublicKey senderPublicKey;
  final KeyPair receiverKeyPair;
}

class UploadResumeContext {
  UploadResumeContext({
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
  final String? transferId;
}

class _ManifestBundle {
  _ManifestBundle({
    required this.manifest,
    required this.sessionKey,
    required this.manifestHashB64,
  });

  final TransferManifest manifest;
  final SecretKey sessionKey;
  final String manifestHashB64;
}

class _CiphertextPaths {
  _CiphertextPaths({
    required this.filePath,
    required this.relativeDirectory,
    required this.filename,
  });

  final String filePath;
  final String relativeDirectory;
  final String filename;
}

class _DecryptRequest {
  _DecryptRequest({
    required this.sessionId,
    required this.transferId,
    required this.senderPublicKey,
    required this.receiverPrivateKey,
    required this.ciphertextPath,
    required this.totalBytes,
    required this.chunkSize,
  });

  final String sessionId;
  final String transferId;
  final Uint8List senderPublicKey;
  final Uint8List receiverPrivateKey;
  final String ciphertextPath;
  final int totalBytes;
  final int chunkSize;

  static Future<_DecryptRequest> fromContext({
    required DownloadResumeContext context,
    required String transferId,
    required String ciphertextPath,
    required int totalBytes,
    required int chunkSize,
  }) async {
    final keyData = await context.receiverKeyPair.extract();
    return _DecryptRequest(
      sessionId: context.sessionId,
      transferId: transferId,
      senderPublicKey: context.senderPublicKey.bytes,
      receiverPrivateKey: Uint8List.fromList(keyData.bytes),
      ciphertextPath: ciphertextPath,
      totalBytes: totalBytes,
      chunkSize: chunkSize,
    );
  }
}

const int _cipherOverheadBytes = 12 + 16;

Future<Uint8List> _decryptCiphertextIsolate(_DecryptRequest request) async {
  final receiverKeyPair = SimpleKeyPairData(
    request.receiverPrivateKey,
    type: KeyPairType.x25519,
  );
  final senderPublicKey = SimplePublicKey(
    request.senderPublicKey,
    type: KeyPairType.x25519,
  );
  final sessionKey = await deriveSessionKey(
    localKeyPair: receiverKeyPair,
    peerPublicKey: senderPublicKey,
    sessionId: request.sessionId,
  );
  final file = File(request.ciphertextPath);
  final raf = await file.open();
  final builder = BytesBuilder(copy: false);
  try {
    await raf.setPosition(0);
    final totalChunks = request.chunkSize == 0
        ? 0
        : (request.totalBytes + request.chunkSize - 1) ~/ request.chunkSize;
    for (var chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
      final remaining = request.totalBytes - (chunkIndex * request.chunkSize);
      if (remaining <= 0) {
        break;
      }
      final plaintextLength =
          remaining < request.chunkSize ? remaining : request.chunkSize;
      final encryptedLength = plaintextLength + _cipherOverheadBytes;
      final encryptedChunk = await raf.read(encryptedLength);
      if (encryptedChunk.length != encryptedLength) {
        throw FormatException('incomplete ciphertext chunk');
      }
      final payload = parseEncryptedPayload(encryptedChunk);
      final plaintext = await decryptChunk(
        sessionKey: sessionKey,
        sessionId: request.sessionId,
        transferId: request.transferId,
        chunkIndex: chunkIndex,
        payload: payload,
      );
      builder.add(plaintext);
    }
  } finally {
    await raf.close();
  }
  final bytes = builder.toBytes();
  if (bytes.length != request.totalBytes) {
    throw FormatException('decrypted length mismatch');
  }
  return bytes;
}
