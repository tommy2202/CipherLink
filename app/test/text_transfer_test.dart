import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/crypto.dart';
import 'package:universaldrop_app/transfer_manifest.dart';

void main() {
  test('text manifest serialize/deserialize', () {
    final manifest = TransferManifest(
      transferId: 'transfer-1',
      payloadKind: payloadKindText,
      totalBytes: 12,
      chunkSize: 4,
      files: const [],
      textTitle: 'Note',
      textMime: textMimePlain,
      textLength: 12,
    );

    final encoded = manifest.toJson();
    final decoded = TransferManifest.fromJson(encoded);

    expect(decoded.payloadKind, equals(payloadKindText));
    expect(decoded.textTitle, equals('Note'));
    expect(decoded.textMime, equals(textMimePlain));
    expect(decoded.textLength, equals(12));
    expect(decoded.totalBytes, equals(12));
    expect(decoded.chunkSize, equals(4));
  });

  test('text payload encrypt/decrypt roundtrip', () async {
    final senderKeyPair = await X25519().newKeyPair();
    final receiverKeyPair = await X25519().newKeyPair();
    final senderPub = await senderKeyPair.extractPublicKey();
    final receiverPub = await receiverKeyPair.extractPublicKey();
    final sessionId = 'sess-123';
    final transferId = 'transfer-abc';

    final senderSessionKey = await deriveSessionKey(
      localKeyPair: senderKeyPair,
      peerPublicKey: receiverPub,
      sessionId: sessionId,
    );
    final receiverSessionKey = await deriveSessionKey(
      localKeyPair: receiverKeyPair,
      peerPublicKey: senderPub,
      sessionId: sessionId,
    );

    final text = 'Hello clipboard transfer';
    final bytes = Uint8List.fromList(utf8.encode(text));
    const chunkSize = 8;
    final chunks = <EncryptedPayload>[];
    var index = 0;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      final chunk = Uint8List.sublistView(bytes, offset, end);
      final encrypted = await encryptChunk(
        sessionKey: senderSessionKey,
        sessionId: sessionId,
        transferId: transferId,
        chunkIndex: index,
        plaintext: chunk,
      );
      chunks.add(encrypted);
      index += 1;
    }

    final builder = BytesBuilder(copy: false);
    index = 0;
    for (final encrypted in chunks) {
      final decrypted = await decryptChunk(
        sessionKey: receiverSessionKey,
        sessionId: sessionId,
        transferId: transferId,
        chunkIndex: index,
        payload: encrypted,
      );
      builder.add(decrypted);
      index += 1;
    }

    expect(utf8.decode(builder.toBytes()), equals(text));
  });
}
