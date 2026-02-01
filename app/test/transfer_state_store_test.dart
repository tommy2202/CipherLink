import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/transfer_state_store.dart';

void main() {
  test('secure store persists and lists pending transfers', () async {
    final secure = MemorySecureStore();
    final store = SecureTransferStateStore(secureStore: secure);
    final state = TransferState(
      transferId: 'transfer-1',
      sessionId: 'session-1',
      transferToken: 'token-1',
      direction: 'download',
      status: 'downloading',
      totalBytes: 8,
      chunkSize: 4,
      nextOffset: 4,
      nextChunkIndex: 1,
      peerPublicKeyB64: 'peer',
      payloadPath: '/tmp/payload',
      scanRequired: false,
    );

    await store.save(state);

    final reloaded = await store.load('transfer-1');
    expect(reloaded, isNotNull);
    expect(reloaded?.sessionId, equals('session-1'));
    expect(reloaded?.transferToken, equals('token-1'));
    expect(reloaded?.nextChunkIndex, equals(1));
    expect(reloaded?.peerPublicKeyB64, equals('peer'));

    final pending = await store.listPending(direction: 'download');
    expect(pending.length, equals(1));

    await store.delete('transfer-1');
    expect(await store.load('transfer-1'), isNull);
  });

  test('persists ciphertext download state across restart', () async {
    final secure = MemorySecureStore();
    final store = SecureTransferStateStore(secureStore: secure);
    final state = TransferState(
      transferId: 'transfer-2',
      sessionId: 'session-2',
      transferToken: 'token-2',
      direction: 'download',
      status: 'downloading',
      totalBytes: 64,
      chunkSize: 32,
      nextOffset: 32,
      nextChunkIndex: 1,
      peerPublicKeyB64: 'peer',
      ciphertextPath: '/tmp/cipher.bin',
      ciphertextComplete: false,
      backgroundTaskId: 'task-2',
      manifestHashB64: 'hash-b64',
      destination: 'files',
      requiresForegroundResume: false,
      downloadTokenRefreshFailures: 0,
      notificationLabel: 'Transfer',
    );

    await store.save(state);

    final restarted = SecureTransferStateStore(secureStore: secure);
    final reloaded = await restarted.load('transfer-2');
    expect(reloaded, isNotNull);
    expect(reloaded?.ciphertextPath, equals('/tmp/cipher.bin'));
    expect(reloaded?.ciphertextComplete, isFalse);
    expect(reloaded?.backgroundTaskId, equals('task-2'));
    expect(reloaded?.manifestHashB64, equals('hash-b64'));
    expect(reloaded?.destination, equals('files'));
    expect(reloaded?.requiresForegroundResume, isFalse);
    expect(reloaded?.downloadTokenRefreshFailures, equals(0));
    expect(reloaded?.notificationLabel, equals('Transfer'));
  });

  test('listPending excludes terminal transfers', () async {
    final secure = MemorySecureStore();
    final store = SecureTransferStateStore(secureStore: secure);
    await store.save(TransferState(
      transferId: 'done',
      sessionId: 'session-1',
      transferToken: 'token-1',
      direction: 'download',
      status: 'completed',
      totalBytes: 4,
      chunkSize: 2,
      nextOffset: 4,
      nextChunkIndex: 2,
    ));
    final pending = await store.listPending();
    expect(pending, isEmpty);
  });
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
