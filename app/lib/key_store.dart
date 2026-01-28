import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'transfer_state_store.dart';

enum KeyRole {
  sender,
  receiver,
}

class SecureKeyPairStore {
  SecureKeyPairStore({SecureStore? secureStore})
      : _secureStore = secureStore ?? MethodChannelSecureStore();

  final SecureStore _secureStore;

  Future<void> saveKeyPair({
    required String sessionId,
    required KeyRole role,
    required KeyPair keyPair,
  }) async {
    final bytes = await _extractPrivateKeyBytes(keyPair);
    final encoded = base64Encode(bytes);
    await _secureStore.write(
      key: _key(sessionId, role),
      value: encoded,
    );
  }

  Future<KeyPair?> loadKeyPair({
    required String sessionId,
    required KeyRole role,
  }) async {
    final encoded = await _secureStore.read(key: _key(sessionId, role));
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    final bytes = base64Decode(encoded);
    return SimpleKeyPairData(bytes, type: KeyPairType.x25519);
  }

  Future<void> deleteKeyPair({
    required String sessionId,
    required KeyRole role,
  }) {
    return _secureStore.delete(key: _key(sessionId, role));
  }

  Future<List<int>> _extractPrivateKeyBytes(KeyPair keyPair) async {
    final data = await keyPair.extract();
    return data.bytes;
  }

  String _key(String sessionId, KeyRole role) {
    return 'keypair_${role.name}_$sessionId';
  }
}
