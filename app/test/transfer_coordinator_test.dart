import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/transfer_coordinator.dart';
import 'package:universaldrop_app/transfer_manifest.dart';
import 'package:universaldrop_app/transfer_state_store.dart';
import 'package:universaldrop_app/transport.dart';

void main() {
  test('coordinator queue transitions sequentially', () async {
    final transport = FakeTransport();
    final store = InMemoryTransferStateStore();
    final coordinator = TransferCoordinator(
      transport: transport,
      store: store,
    );

    final senderKeyPair = await X25519().newKeyPair();
    final receiverKeyPair = await X25519().newKeyPair();
    final receiverPublicKey = await receiverKeyPair.extractPublicKey();

    final files = [
      TransferFile(
        id: 'file-1',
        name: 'a.txt',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        payloadKind: payloadKindFile,
        mimeType: 'text/plain',
      ),
      TransferFile(
        id: 'file-2',
        name: 'b.txt',
        bytes: Uint8List.fromList([5, 6, 7, 8]),
        payloadKind: payloadKindFile,
        mimeType: 'text/plain',
      ),
    ];

    coordinator.enqueueUploads(
      files: files,
      sessionId: 'session-1',
      transferToken: 'token-1',
      receiverPublicKey: receiverPublicKey,
      senderKeyPair: senderKeyPair,
      chunkSize: 2,
    );

    await coordinator.runQueue();

    expect(transport.initOrder, equals(['file-1', 'file-2']));
    final state1 = await store.load('file-1');
    final state2 = await store.load('file-2');
    expect(state1?.status, equals(statusCompleted));
    expect(state2?.status, equals(statusCompleted));
  });
}

class FakeTransport implements Transport {
  final List<String> initOrder = [];

  @override
  Future<TransferInitResult> initTransfer({
    required String sessionId,
    required String transferToken,
    required Uint8List manifestCiphertext,
    required int totalBytes,
    String? transferId,
  }) async {
    final id = transferId ?? 'generated';
    initOrder.add(id);
    return TransferInitResult(id);
  }

  @override
  Future<void> sendChunk({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required Uint8List data,
  }) async {}

  @override
  Future<void> finalizeTransfer({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) async {}

  @override
  Future<Uint8List> fetchManifest({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    throw UnimplementedError();
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
  }) async {}
}
