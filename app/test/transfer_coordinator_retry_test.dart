import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/transfer_coordinator.dart';
import 'package:universaldrop_app/transfer_manifest.dart';
import 'package:universaldrop_app/transfer_state_store.dart';
import 'package:universaldrop_app/transport.dart';

void main() {
  test('chunk_conflict does not retry', () async {
    final transport = FakeTransport(
      sendChunkPlan: [
        TransportException('sendChunk failed: 409', statusCode: 409),
      ],
    );
    final coordinator = TransferCoordinator(
      transport: transport,
      store: InMemoryTransferStateStore(),
    );
    await _runSingleChunkUpload(coordinator);

    expect(transport.sendChunkCalls, equals(1));
  });

  test('503 retries chunk upload', () async {
    final transport = FakeTransport(
      sendChunkPlan: [
        TransportException('sendChunk failed: 503', statusCode: 503),
        null,
      ],
    );
    final coordinator = TransferCoordinator(
      transport: transport,
      store: InMemoryTransferStateStore(),
    );
    await _runSingleChunkUpload(coordinator);

    expect(transport.sendChunkCalls, equals(2));
    expect(transport.finalizeCalls, equals(1));
  });

  test('stall timeout retries', () async {
    final transport = FakeTransport(
      sendChunkPlan: [
        const Duration(milliseconds: 50),
        null,
      ],
    );
    final coordinator = TransferCoordinator(
      transport: transport,
      store: InMemoryTransferStateStore(),
      stallTimeout: const Duration(milliseconds: 10),
    );
    await _runSingleChunkUpload(coordinator);

    expect(transport.sendChunkCalls, equals(2));
  });
}

Future<void> _runSingleChunkUpload(TransferCoordinator coordinator) async {
  final senderKeyPair = await X25519().newKeyPair();
  final receiverKeyPair = await X25519().newKeyPair();
  final receiverPublicKey = await receiverKeyPair.extractPublicKey();

  coordinator.enqueueUploads(
    files: [
      TransferFile(
        id: 'file-1',
        name: 'file.txt',
        bytes: Uint8List.fromList([1, 2, 3]),
        payloadKind: payloadKindFile,
        mimeType: 'application/octet-stream',
        packagingMode: packagingModeOriginals,
      ),
    ],
    sessionId: 'session-1',
    transferToken: 'token-1',
    receiverPublicKey: receiverPublicKey,
    senderKeyPair: senderKeyPair,
    chunkSize: 4,
  );

  await coordinator.runQueue();
}

class FakeTransport implements Transport {
  FakeTransport({required this.sendChunkPlan});

  final List<Object?> sendChunkPlan;
  int sendChunkCalls = 0;
  int finalizeCalls = 0;
  int initCalls = 0;

  @override
  Future<TransferInitResult> initTransfer({
    required String sessionId,
    required String transferToken,
    required Uint8List manifestCiphertext,
    required int totalBytes,
    String? transferId,
  }) async {
    initCalls += 1;
    return TransferInitResult(transferId ?? 'transfer-1');
  }

  @override
  Future<void> sendChunk({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required Uint8List data,
  }) async {
    final idx = sendChunkCalls;
    sendChunkCalls += 1;
    if (idx < sendChunkPlan.length) {
      final step = sendChunkPlan[idx];
      if (step is Exception) {
        throw step;
      }
      if (step is Duration) {
        await Future<void>.delayed(step);
        return;
      }
    }
  }

  @override
  Future<void> finalizeTransfer({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) async {
    finalizeCalls += 1;
  }

  @override
  Future<Uint8List> fetchManifest({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    throw UnimplementedError('fetchManifest not used');
  }

  @override
  Future<Uint8List> fetchRange({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required int length,
  }) {
    throw UnimplementedError('fetchRange not used');
  }

  @override
  Future<void> sendReceipt({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    throw UnimplementedError('sendReceipt not used');
  }

  @override
  Future<ScanInitResult> scanInit({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int totalBytes,
    required int chunkSize,
  }) {
    throw UnimplementedError('scanInit not used');
  }

  @override
  Future<void> scanChunk({
    required String scanId,
    required String transferToken,
    required int chunkIndex,
    required Uint8List data,
  }) {
    throw UnimplementedError('scanChunk not used');
  }

  @override
  Future<ScanFinalizeResult> scanFinalize({
    required String scanId,
    required String transferToken,
  }) {
    throw UnimplementedError('scanFinalize not used');
  }
}
