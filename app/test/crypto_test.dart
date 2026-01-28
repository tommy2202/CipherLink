import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/crypto.dart';

void main() {
  test('manifest encrypt/decrypt roundtrip; tamper fails', () async {
    final sessionId = 'session-123';
    final transferId = 'transfer-abc';
    final senderKeyPair = await X25519().newKeyPair();
    final receiverKeyPair = await X25519().newKeyPair();
    final senderPublicKey = await senderKeyPair.extractPublicKey();
    final receiverPublicKey = await receiverKeyPair.extractPublicKey();

    final senderSessionKey = await deriveSessionKey(
      localKeyPair: senderKeyPair,
      peerPublicKey: receiverPublicKey,
      sessionId: sessionId,
    );
    final receiverSessionKey = await deriveSessionKey(
      localKeyPair: receiverKeyPair,
      peerPublicKey: senderPublicKey,
      sessionId: sessionId,
    );

    final plaintext = Uint8List.fromList(utf8.encode('manifest'));
    final encrypted = await encryptManifest(
      sessionKey: senderSessionKey,
      sessionId: sessionId,
      transferId: transferId,
      plaintext: plaintext,
    );
    final decrypted = await decryptManifest(
      sessionKey: receiverSessionKey,
      sessionId: sessionId,
      transferId: transferId,
      payload: encrypted,
    );

    expect(utf8.decode(decrypted), equals('manifest'));

    final tampered = encrypted.copyWith(
      cipherText: _flipFirstByte(encrypted.cipherText),
    );
    await expectLater(
      decryptManifest(
        sessionKey: receiverSessionKey,
        sessionId: sessionId,
        transferId: transferId,
        payload: tampered,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('chunk reorder/tamper fails', () async {
    final sessionId = 'session-456';
    final transferId = 'transfer-xyz';
    final senderKeyPair = await X25519().newKeyPair();
    final receiverKeyPair = await X25519().newKeyPair();
    final senderPublicKey = await senderKeyPair.extractPublicKey();
    final receiverPublicKey = await receiverKeyPair.extractPublicKey();

    final senderSessionKey = await deriveSessionKey(
      localKeyPair: senderKeyPair,
      peerPublicKey: receiverPublicKey,
      sessionId: sessionId,
    );
    final receiverSessionKey = await deriveSessionKey(
      localKeyPair: receiverKeyPair,
      peerPublicKey: senderPublicKey,
      sessionId: sessionId,
    );

    final chunk0 = await encryptChunk(
      sessionKey: senderSessionKey,
      sessionId: sessionId,
      transferId: transferId,
      chunkIndex: 0,
      plaintext: Uint8List.fromList(utf8.encode('chunk-0')),
    );
    final chunk1 = await encryptChunk(
      sessionKey: senderSessionKey,
      sessionId: sessionId,
      transferId: transferId,
      chunkIndex: 1,
      plaintext: Uint8List.fromList(utf8.encode('chunk-1')),
    );

    final decrypted0 = await decryptChunk(
      sessionKey: receiverSessionKey,
      sessionId: sessionId,
      transferId: transferId,
      chunkIndex: 0,
      payload: chunk0,
    );
    expect(utf8.decode(decrypted0), equals('chunk-0'));

    await expectLater(
      decryptChunk(
        sessionKey: receiverSessionKey,
        sessionId: sessionId,
        transferId: transferId,
        chunkIndex: 0,
        payload: chunk1,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );

    final tampered = chunk0.copyWith(
      cipherText: _flipFirstByte(chunk0.cipherText),
    );
    await expectLater(
      decryptChunk(
        sessionKey: receiverSessionKey,
        sessionId: sessionId,
        transferId: transferId,
        chunkIndex: 0,
        payload: tampered,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });
}

Uint8List _flipFirstByte(Uint8List data) {
  if (data.isEmpty) {
    return Uint8List.fromList(data);
  }
  final copy = Uint8List.fromList(data);
  copy[0] = copy[0] ^ 0xFF;
  return copy;
}
