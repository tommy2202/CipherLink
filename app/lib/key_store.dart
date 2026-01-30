import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'transfer_state_store.dart';

enum KeyRole {
  sender,
  receiver,
}

class SecureKeyPairStore {
  SecureKeyPairStore({SecureStore? secureStore})
      : _secureStore = secureStore ?? FlutterSecureStore();

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

  Future<bool> trySaveKeyPair({
    required String sessionId,
    required KeyRole role,
    required KeyPair keyPair,
  }) async {
    try {
      await saveKeyPair(sessionId: sessionId, role: role, keyPair: keyPair);
      return true;
    } on SecureStoreUnavailableException {
      return false;
    } on Exception {
      return false;
    }
  }

  Future<KeyPair?> loadKeyPair({
    required String sessionId,
    required KeyRole role,
  }) async {
    String? encoded;
    try {
      encoded = await _secureStore.read(key: _key(sessionId, role));
    } on SecureStoreUnavailableException {
      return null;
    }
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    try {
      final bytes = base64Decode(encoded);
      return SimpleKeyPairData(bytes, type: KeyPairType.x25519);
    } on FormatException {
      return null;
    }
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
