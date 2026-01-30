import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/key_store.dart';
import 'package:universaldrop_app/transfer_state_store.dart';

void main() {
  test('secure key store saves and loads key pairs', () async {
    final store = SecureKeyPairStore(secureStore: MemorySecureStore());
    final keyPair = await X25519().newKeyPair();

    await store.saveKeyPair(
      sessionId: 'session-1',
      role: KeyRole.sender,
      keyPair: keyPair,
    );

    final loaded = await store.loadKeyPair(
      sessionId: 'session-1',
      role: KeyRole.sender,
    );
    expect(loaded, isNotNull);
  });

  test('key store fails closed when storage is unavailable', () async {
    final store = SecureKeyPairStore(secureStore: FailingSecureStore());
    final keyPair = await X25519().newKeyPair();

    final stored = await store.trySaveKeyPair(
      sessionId: 'session-2',
      role: KeyRole.receiver,
      keyPair: keyPair,
    );
    expect(stored, isFalse);

    final loaded = await store.loadKeyPair(
      sessionId: 'session-2',
      role: KeyRole.receiver,
    );
    expect(loaded, isNull);
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

class FailingSecureStore implements SecureStore {
  @override
  Future<void> write({required String key, required String value}) {
    return Future.error(SecureStoreUnavailableException());
  }

  @override
  Future<String?> read({required String key}) {
    return Future.error(SecureStoreUnavailableException());
  }

  @override
  Future<void> delete({required String key}) {
    return Future.error(SecureStoreUnavailableException());
  }
}
