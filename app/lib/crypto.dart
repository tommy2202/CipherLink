import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const String _direction = 'sender->receiver';

class EncryptedPayload {
  EncryptedPayload({
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;

  EncryptedPayload copyWith({
    Uint8List? nonce,
    Uint8List? cipherText,
    Uint8List? mac,
  }) {
    return EncryptedPayload(
      nonce: nonce ?? this.nonce,
      cipherText: cipherText ?? this.cipherText,
      mac: mac ?? this.mac,
    );
  }
}

Future<SecretKey> deriveSessionKey({
  required KeyPair localKeyPair,
  required SimplePublicKey peerPublicKey,
  required String sessionId,
}) async {
  final sharedSecret = await X25519().sharedSecretKey(
    keyPair: localKeyPair,
    remotePublicKey: peerPublicKey,
  );
  return _hkdfSecretKey(
    sharedSecret,
    salt: _utf8(sessionId),
    info: _utf8('cipherlink-session'),
    length: 32,
  );
}

Future<SecretKey> deriveFileKey({
  required SecretKey sessionKey,
  required String transferId,
}) {
  return _hkdfSecretKey(
    sessionKey,
    salt: _utf8(transferId),
    info: _utf8('file-key'),
    length: 32,
  );
}

Future<SecretKey> deriveManifestKey({
  required SecretKey sessionKey,
  required String transferId,
}) {
  return _hkdfSecretKey(
    sessionKey,
    salt: _utf8(transferId),
    info: _utf8('manifest-key'),
    length: 32,
  );
}

Future<SecretKey> deriveChunkKey({
  required SecretKey fileKey,
  required int chunkIndex,
}) {
  return _hkdfSecretKey(
    fileKey,
    salt: _chunkSalt(chunkIndex),
    info: _utf8('chunk-key'),
    length: 32,
  );
}

Future<EncryptedPayload> encryptManifest({
  required SecretKey sessionKey,
  required String sessionId,
  required String transferId,
  required Uint8List plaintext,
}) async {
  final manifestKey = await deriveManifestKey(
    sessionKey: sessionKey,
    transferId: transferId,
  );
  final nonce = await _hkdfBytes(
    manifestKey,
    salt: _utf8(transferId),
    info: _utf8('manifest-nonce'),
    length: 12,
  );
  final aad = _aad(sessionId, transferId, -1);
  final aead = Chacha20.poly1305Aead();
  final box = await aead.encrypt(
    plaintext,
    secretKey: manifestKey,
    nonce: nonce,
    aad: aad,
  );
  return EncryptedPayload(
    nonce: Uint8List.fromList(box.nonce),
    cipherText: Uint8List.fromList(box.cipherText),
    mac: Uint8List.fromList(box.mac.bytes),
  );
}

Future<Uint8List> decryptManifest({
  required SecretKey sessionKey,
  required String sessionId,
  required String transferId,
  required EncryptedPayload payload,
}) async {
  final manifestKey = await deriveManifestKey(
    sessionKey: sessionKey,
    transferId: transferId,
  );
  final aad = _aad(sessionId, transferId, -1);
  final aead = Chacha20.poly1305Aead();
  final box = SecretBox(
    payload.cipherText,
    nonce: payload.nonce,
    mac: Mac(payload.mac),
  );
  final plaintext = await aead.decrypt(
    box,
    secretKey: manifestKey,
    aad: aad,
  );
  return Uint8List.fromList(plaintext);
}

Future<EncryptedPayload> encryptChunk({
  required SecretKey sessionKey,
  required String sessionId,
  required String transferId,
  required int chunkIndex,
  required Uint8List plaintext,
}) async {
  final fileKey = await deriveFileKey(
    sessionKey: sessionKey,
    transferId: transferId,
  );
  final chunkKey = await deriveChunkKey(
    fileKey: fileKey,
    chunkIndex: chunkIndex,
  );
  final nonce = await _hkdfBytes(
    fileKey,
    salt: _chunkSalt(chunkIndex),
    info: _utf8('chunk-nonce'),
    length: 12,
  );
  final aad = _aad(sessionId, transferId, chunkIndex);
  final aead = Chacha20.poly1305Aead();
  final box = await aead.encrypt(
    plaintext,
    secretKey: chunkKey,
    nonce: nonce,
    aad: aad,
  );
  return EncryptedPayload(
    nonce: Uint8List.fromList(box.nonce),
    cipherText: Uint8List.fromList(box.cipherText),
    mac: Uint8List.fromList(box.mac.bytes),
  );
}

Future<Uint8List> decryptChunk({
  required SecretKey sessionKey,
  required String sessionId,
  required String transferId,
  required int chunkIndex,
  required EncryptedPayload payload,
}) async {
  final fileKey = await deriveFileKey(
    sessionKey: sessionKey,
    transferId: transferId,
  );
  final chunkKey = await deriveChunkKey(
    fileKey: fileKey,
    chunkIndex: chunkIndex,
  );
  final aad = _aad(sessionId, transferId, chunkIndex);
  final aead = Chacha20.poly1305Aead();
  final box = SecretBox(
    payload.cipherText,
    nonce: payload.nonce,
    mac: Mac(payload.mac),
  );
  final plaintext = await aead.decrypt(
    box,
    secretKey: chunkKey,
    aad: aad,
  );
  return Uint8List.fromList(plaintext);
}

SimplePublicKey publicKeyFromBase64(String value) {
  return SimplePublicKey(
    base64Decode(value),
    type: KeyPairType.x25519,
  );
}

String publicKeyToBase64(SimplePublicKey key) {
  return base64Encode(key.bytes);
}

Uint8List _aad(String sessionId, String transferId, int chunkIndex) {
  final value =
      'session_id=$sessionId|transfer_id=$transferId|chunk_index=$chunkIndex|direction=$_direction';
  return _utf8(value);
}

Uint8List _chunkSalt(int chunkIndex) {
  final data = ByteData(8);
  data.setInt64(0, chunkIndex);
  return data.buffer.asUint8List();
}

Uint8List _utf8(String value) => Uint8List.fromList(utf8.encode(value));

Future<SecretKey> _hkdfSecretKey(
  SecretKey key, {
  required Uint8List salt,
  required Uint8List info,
  required int length,
}) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
  return hkdf.deriveKey(
    secretKey: key,
    nonce: salt,
    info: info,
  );
}

Future<Uint8List> _hkdfBytes(
  SecretKey key, {
  required Uint8List salt,
  required Uint8List info,
  required int length,
}) async {
  final derived = await _hkdfSecretKey(
    key,
    salt: salt,
    info: info,
    length: length,
  );
  final bytes = await derived.extractBytes();
  return Uint8List.fromList(bytes);
}
