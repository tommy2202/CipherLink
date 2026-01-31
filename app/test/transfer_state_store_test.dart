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
