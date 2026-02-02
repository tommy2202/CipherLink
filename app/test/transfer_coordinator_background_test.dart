import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:universaldrop_app/crypto.dart';
import 'package:universaldrop_app/transfer/background_transfer.dart';
import 'package:universaldrop_app/transfer_coordinator.dart';
import 'package:universaldrop_app/transfer_manifest.dart';
import 'package:universaldrop_app/transfer_state_store.dart';
import 'package:universaldrop_app/transport.dart';

void main() {
  test('background progress update advances offset', () async {
    final store = InMemoryTransferStateStore();
    final background = FakeBackgroundTransfer();
    final coordinator = TransferCoordinator(
      transport: FakeTransport(),
      store: store,
      backgroundTransfer: background,
      downloadTokenStore: DownloadTokenStore(secureStore: MemorySecureStore()),
    );
    expect(coordinator.isRunning, isFalse);

    await store.save(TransferState(
      transferId: 'transfer-1',
      sessionId: 'session-1',
      transferToken: 'token-1',
      direction: downloadDirection,
      status: statusDownloading,
      totalBytes: 20,
      chunkSize: 10,
      nextOffset: 0,
      nextChunkIndex: 0,
      backgroundTaskId: 'task-1',
    ));

    final task = DownloadTask(
      taskId: 'task-1',
      url: 'https://example.com',
      filename: 'cipher.bin',
      directory: 'tmp',
    );
    final update = _buildProgressUpdate(
      task,
      0.5,
      expectedFileSize: 76,
    );
    background.emit(update);

    await Future<void>.delayed(Duration.zero);

    final updated = await store.load('transfer-1');
    expect(updated?.nextOffset, equals(38));
    expect(updated?.nextChunkIndex, equals(1));
    expect(updated?.status, equals(statusDownloading));
  });

  test('token refresh failure pauses background download', () async {
    final store = InMemoryTransferStateStore();
    final background = FakeBackgroundTransfer();
    final coordinator = TransferCoordinator(
      transport: FakeTransport(throwOnFetchDownloadToken: true),
      store: store,
      backgroundTransfer: background,
      downloadTokenStore: DownloadTokenStore(secureStore: MemorySecureStore()),
    );
    expect(coordinator.isRunning, isFalse);

    await store.save(TransferState(
      transferId: 'transfer-2',
      sessionId: 'session-2',
      transferToken: 'token-2',
      direction: downloadDirection,
      status: statusDownloading,
      totalBytes: 20,
      chunkSize: 10,
      nextOffset: 0,
      nextChunkIndex: 0,
      backgroundTaskId: 'task-2',
    ));

    final task = DownloadTask(
      taskId: 'task-2',
      url: 'https://example.com',
      filename: 'cipher.bin',
      directory: 'tmp',
    );
    final update = _buildStatusUpdate(
      task,
      TaskStatus.failed,
      responseStatusCode: 401,
    );
    background.emit(update);

    await Future<void>.delayed(Duration.zero);

    final updated = await store.load('transfer-2');
    expect(updated?.status, equals(statusPaused));
    expect(updated?.requiresForegroundResume, isTrue);
  });

  test('resumePendingDownloads decrypts completed ciphertext', () async {
    final senderKeyPair = await X25519().newKeyPair();
    final receiverKeyPair = await X25519().newKeyPair();
    final senderPublicKey = await senderKeyPair.extractPublicKey();
    final receiverPublicKey = await receiverKeyPair.extractPublicKey();
    final sessionId = 'session-3';
    final transferId = 'transfer-3';
    final transferToken = 'token-3';

    final plaintext = Uint8List.fromList([1, 2, 3, 4]);
    final sessionKey = await deriveSessionKey(
      localKeyPair: senderKeyPair,
      peerPublicKey: receiverPublicKey,
      sessionId: sessionId,
    );
    final manifest = TransferManifest(
      transferId: transferId,
      payloadKind: payloadKindFile,
      packagingMode: packagingModeOriginals,
      totalBytes: plaintext.length,
      chunkSize: plaintext.length,
      files: [
        TransferManifestFile(
          relativePath: 'sample.bin',
          mediaType: mediaTypeOther,
          sizeBytes: plaintext.length,
        ),
      ],
    );
    final manifestPlaintext =
        Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson())));
    final manifestEncrypted = await encryptManifest(
      sessionKey: sessionKey,
      sessionId: sessionId,
      transferId: transferId,
      plaintext: manifestPlaintext,
    );
    final manifestBytes = serializeEncryptedPayload(manifestEncrypted);

    final encryptedChunk = await encryptChunk(
      sessionKey: sessionKey,
      sessionId: sessionId,
      transferId: transferId,
      chunkIndex: 0,
      plaintext: plaintext,
    );
    final ciphertextBytes = serializeEncryptedPayload(encryptedChunk);
    final tempDir = await Directory.systemTemp.createTemp('ciphertext');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final ciphertextPath = p.join(tempDir.path, 'cipher.bin');
    await File(ciphertextPath).writeAsBytes(ciphertextBytes);

    final store = InMemoryTransferStateStore();
    await store.save(TransferState(
      transferId: transferId,
      sessionId: sessionId,
      transferToken: transferToken,
      direction: downloadDirection,
      status: statusDownloading,
      totalBytes: plaintext.length,
      chunkSize: plaintext.length,
      nextOffset: ciphertextBytes.length,
      nextChunkIndex: 1,
      ciphertextPath: ciphertextPath,
      ciphertextComplete: true,
    ));

    final transport = FakeTransport(manifestBytes: manifestBytes);
    final background = FakeBackgroundTransfer();
    final tokenStore = DownloadTokenStore(secureStore: MemorySecureStore());
    Uint8List? savedBytes;

    final coordinator = TransferCoordinator(
      transport: transport,
      store: store,
      backgroundTransfer: background,
      downloadTokenStore: tokenStore,
      downloadResolver: (state) async {
        return DownloadResumeContext(
          sessionId: sessionId,
          transferToken: transferToken,
          transferId: transferId,
          senderPublicKey: senderPublicKey,
          receiverKeyPair: receiverKeyPair,
        );
      },
      saveHandler: (manifest, bytes, state) async {
        savedBytes = bytes;
        return const TransferSaveResult(shouldSendReceipt: true);
      },
    );

    await coordinator.resumePendingDownloads(resolve: (state) async {
      return DownloadResumeContext(
        sessionId: sessionId,
        transferToken: transferToken,
        transferId: transferId,
        senderPublicKey: senderPublicKey,
        receiverKeyPair: receiverKeyPair,
      );
    });

    expect(savedBytes, isNotNull);
    expect(savedBytes, equals(plaintext));
    expect(transport.receiptCount, equals(1));

    final updated = await store.load(transferId);
    expect(updated?.status, equals(statusCompleted));
  });
}

class FakeBackgroundTransfer implements BackgroundTransferApi {
  final List<BackgroundProgressCallback> _callbacks = [];

  @override
  Future<bool> enqueueBackgroundDownload(TransferTask task) async {
    return true;
  }

  @override
  Future<BackgroundTaskStatus?> queryBackgroundStatus(String taskId) async {
    return null;
  }

  @override
  Future<bool> cancelBackgroundTask(String taskId) async {
    return true;
  }

  @override
  void onBackgroundProgress(BackgroundProgressCallback callback) {
    _callbacks.add(callback);
  }

  void emit(TaskUpdate update) {
    final wrapped = BackgroundTransferUpdate(update);
    for (final callback in List<BackgroundProgressCallback>.from(_callbacks)) {
      callback(wrapped);
    }
  }
}

TaskProgressUpdate _buildProgressUpdate(
  Task task,
  double progress, {
  int? expectedFileSize,
}) {
  final ctor = TaskProgressUpdate.new;
  try {
    return Function.apply(
      ctor,
      [task, progress],
      {#expectedFileSize: expectedFileSize},
    ) as TaskProgressUpdate;
  } catch (_) {
    return Function.apply(
      ctor,
      [],
      {
        #task: task,
        #progress: progress,
        #expectedFileSize: expectedFileSize,
      },
    ) as TaskProgressUpdate;
  }
}

TaskStatusUpdate _buildStatusUpdate(
  Task task,
  TaskStatus status, {
  int? responseStatusCode,
}) {
  final ctor = TaskStatusUpdate.new;
  try {
    return Function.apply(
      ctor,
      [task, status],
      {#responseStatusCode: responseStatusCode},
    ) as TaskStatusUpdate;
  } catch (_) {
    return Function.apply(
      ctor,
      [],
      {
        #task: task,
        #status: status,
        #responseStatusCode: responseStatusCode,
      },
    ) as TaskStatusUpdate;
  }
}

class FakeTransport implements Transport {
  FakeTransport({
    this.manifestBytes,
    this.throwOnFetchDownloadToken = false,
  });

  final Uint8List? manifestBytes;
  final bool throwOnFetchDownloadToken;
  int receiptCount = 0;

  @override
  Future<TransferInitResult> initTransfer({
    required String sessionId,
    required String transferToken,
    required Uint8List manifestCiphertext,
    required int totalBytes,
    String? transferId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> sendChunk({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required Uint8List data,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> finalizeTransfer({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> fetchManifest({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) async {
    if (manifestBytes == null) {
      throw StateError('manifest not configured');
    }
    return manifestBytes!;
  }

  @override
  Future<Uint8List> fetchRange({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required int length,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> sendReceipt({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) async {
    receiptCount += 1;
  }

  @override
  Future<ScanInitResult> scanInit({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int totalBytes,
    required int chunkSize,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> scanChunk({
    required String scanId,
    required String transferToken,
    required int chunkIndex,
    required Uint8List data,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ScanFinalizeResult> scanFinalize({
    required String scanId,
    required String transferToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<DownloadTokenResult> fetchDownloadToken({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) async {
    if (throwOnFetchDownloadToken) {
      throw StateError('token refresh failed');
    }
    return DownloadTokenResult(
      token: 'download-token',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );
  }
}

class MemorySecureStore implements SecureStore {
  final Map<String, String> _store = {};

  @override
  Future<void> write({required String key, required String value}) async {
    _store[key] = value;
  }

  @override
  Future<String?> read({required String key}) async {
    return _store[key];
  }

  @override
  Future<void> delete({required String key}) async {
    _store.remove(key);
  }
}
