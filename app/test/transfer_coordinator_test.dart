import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/crypto.dart';
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
        packagingMode: packagingModeOriginals,
      ),
      TransferFile(
        id: 'file-2',
        name: 'b.txt',
        bytes: Uint8List.fromList([5, 6, 7, 8]),
        payloadKind: payloadKindFile,
        mimeType: 'text/plain',
        packagingMode: packagingModeOriginals,
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

  test('coordinator resumes uploads after restart', () async {
    final transport = RecordingTransport();
    final store = InMemoryTransferStateStore();
    final coordinator = TransferCoordinator(
      transport: transport,
      store: store,
    );

    final senderKeyPair = await X25519().newKeyPair();
    final receiverKeyPair = await X25519().newKeyPair();
    final receiverPublicKey = await receiverKeyPair.extractPublicKey();

    await store.save(TransferState(
      transferId: 'transfer-1',
      sessionId: 'session-1',
      transferToken: 'token-1',
      direction: uploadDirection,
      status: statusPaused,
      totalBytes: 4,
      chunkSize: 2,
      nextOffset: 123,
      nextChunkIndex: 1,
      peerPublicKeyB64: publicKeyToBase64(receiverPublicKey),
    ));

    await coordinator.resumePendingUploads(
      resolve: (state) async {
        return UploadResumeContext(
          file: TransferFile(
            id: state.transferId,
            name: 'resume.bin',
            bytes: Uint8List.fromList([1, 2, 3, 4]),
            payloadKind: payloadKindFile,
            mimeType: 'application/octet-stream',
            packagingMode: packagingModeOriginals,
          ),
          sessionId: state.sessionId,
          transferToken: state.transferToken,
          receiverPublicKey: receiverPublicKey,
          senderKeyPair: senderKeyPair,
          chunkSize: state.chunkSize,
          scanRequired: false,
          transferId: state.transferId,
        );
      },
    );

    expect(transport.sentOffsets.first, equals(123));
  });

  test('coordinator falls back to HTTP when P2P fails', () async {
    final httpTransport = RecordingTransport();
    final p2pTransport = FakeP2PFallbackTransport(httpTransport)
      ..failSend = true;
    final store = InMemoryTransferStateStore();
    final coordinator = TransferCoordinator(
      transport: httpTransport,
      store: store,
      p2pTransportFactory: (_) => p2pTransport,
    );

    final senderKeyPair = await X25519().newKeyPair();
    final receiverKeyPair = await X25519().newKeyPair();
    final receiverPublicKey = await receiverKeyPair.extractPublicKey();
    final context = P2PContext(
      sessionId: 'session-1',
      claimId: 'claim-1',
      token: 'p2p-token',
      isInitiator: true,
    );

    coordinator.enqueueUploads(
      files: [
        TransferFile(
          id: 'file-1',
          name: 'a.txt',
          bytes: Uint8List.fromList([1, 2, 3, 4]),
          payloadKind: payloadKindFile,
          mimeType: 'text/plain',
          packagingMode: packagingModeOriginals,
        ),
      ],
      sessionId: 'session-1',
      transferToken: 'token-1',
      receiverPublicKey: receiverPublicKey,
      senderKeyPair: senderKeyPair,
      chunkSize: 2,
      p2pContext: context,
    );

    await coordinator.runQueue();

    expect(p2pTransport.forceFallbackCalls, equals(1));
    expect(httpTransport.sentOffsets, isNotEmpty);
  });

  test('stall detection triggers fallback', () async {
    final httpTransport = RecordingTransport();
    final p2pTransport = FakeP2PFallbackTransport(httpTransport)
      ..stallSend = true;
    final store = InMemoryTransferStateStore();
    final coordinator = TransferCoordinator(
      transport: httpTransport,
      store: store,
      p2pTransportFactory: (_) => p2pTransport,
      stallTimeout: const Duration(milliseconds: 5),
      stallFallbackThreshold: 1,
    );

    final senderKeyPair = await X25519().newKeyPair();
    final receiverKeyPair = await X25519().newKeyPair();
    final receiverPublicKey = await receiverKeyPair.extractPublicKey();
    final context = P2PContext(
      sessionId: 'session-1',
      claimId: 'claim-1',
      token: 'p2p-token',
      isInitiator: true,
      iceMode: P2PIceMode.direct,
    );

    coordinator.enqueueUploads(
      files: [
        TransferFile(
          id: 'file-2',
          name: 'b.txt',
          bytes: Uint8List.fromList([5, 6, 7, 8]),
          payloadKind: payloadKindFile,
          mimeType: 'text/plain',
          packagingMode: packagingModeOriginals,
        ),
      ],
      sessionId: 'session-1',
      transferToken: 'token-1',
      receiverPublicKey: receiverPublicKey,
      senderKeyPair: senderKeyPair,
      chunkSize: 2,
      p2pContext: context,
    );

    await coordinator.runQueue();

    expect(p2pTransport.forceFallbackCalls, equals(1));
    expect(httpTransport.sentOffsets, isNotEmpty);
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

  @override
  Future<ScanInitResult> scanInit({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int totalBytes,
    required int chunkSize,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> scanChunk({
    required String scanId,
    required String transferToken,
    required int chunkIndex,
    required Uint8List data,
  }) async {}

  @override
  Future<ScanFinalizeResult> scanFinalize({
    required String scanId,
    required String transferToken,
  }) {
    throw UnimplementedError();
  }
}

class RecordingTransport extends FakeTransport {
  final List<int> sentOffsets = [];

  @override
  Future<void> sendChunk({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required Uint8List data,
  }) async {
    sentOffsets.add(offset);
  }

  @override
  Future<void> finalizeTransfer({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) async {}
}

class FakeP2PFallbackTransport implements P2PFallbackTransport {
  FakeP2PFallbackTransport(this.fallback);

  final RecordingTransport fallback;
  bool failSend = false;
  bool stallSend = false;
  int forceFallbackCalls = 0;
  bool _usingFallback = false;

  @override
  bool get usingFallback => _usingFallback;

  @override
  bool isFallbackRequested(String transferId) => false;

  @override
  void requestFallback(String transferId) {}

  @override
  void forceFallback() {
    _usingFallback = true;
    forceFallbackCalls += 1;
  }

  @override
  Future<TransferInitResult> initTransfer({
    required String sessionId,
    required String transferToken,
    required Uint8List manifestCiphertext,
    required int totalBytes,
    String? transferId,
  }) {
    return fallback.initTransfer(
      sessionId: sessionId,
      transferToken: transferToken,
      manifestCiphertext: manifestCiphertext,
      totalBytes: totalBytes,
      transferId: transferId,
    );
  }

  @override
  Future<void> sendChunk({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required Uint8List data,
  }) async {
    if (_usingFallback) {
      return fallback.sendChunk(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        offset: offset,
        data: data,
      );
    }
    if (stallSend) {
      return Completer<void>().future;
    }
    if (failSend) {
      throw TransportException('p2p_failed');
    }
  }

  @override
  Future<void> finalizeTransfer({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) async {
    return fallback.finalizeTransfer(
      sessionId: sessionId,
      transferId: transferId,
      transferToken: transferToken,
    );
  }

  @override
  Future<Uint8List> fetchManifest({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    return fallback.fetchManifest(
      sessionId: sessionId,
      transferId: transferId,
      transferToken: transferToken,
    );
  }

  @override
  Future<Uint8List> fetchRange({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required int length,
  }) {
    return fallback.fetchRange(
      sessionId: sessionId,
      transferId: transferId,
      transferToken: transferToken,
      offset: offset,
      length: length,
    );
  }

  @override
  Future<void> sendReceipt({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    return fallback.sendReceipt(
      sessionId: sessionId,
      transferId: transferId,
      transferToken: transferToken,
    );
  }

  @override
  Future<ScanInitResult> scanInit({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int totalBytes,
    required int chunkSize,
  }) {
    return fallback.scanInit(
      sessionId: sessionId,
      transferId: transferId,
      transferToken: transferToken,
      totalBytes: totalBytes,
      chunkSize: chunkSize,
    );
  }

  @override
  Future<void> scanChunk({
    required String scanId,
    required String transferToken,
    required int chunkIndex,
    required Uint8List data,
  }) {
    return fallback.scanChunk(
      scanId: scanId,
      transferToken: transferToken,
      chunkIndex: chunkIndex,
      data: data,
    );
  }

  @override
  Future<ScanFinalizeResult> scanFinalize({
    required String scanId,
    required String transferToken,
  }) {
    return fallback.scanFinalize(
      scanId: scanId,
      transferToken: transferToken,
    );
  }
}
