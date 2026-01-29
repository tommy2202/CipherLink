import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:universaldrop_app/transfer_coordinator.dart';
import 'package:universaldrop_app/transfer_state_store.dart';
import 'package:universaldrop_app/transport.dart';

void main() {
  test('coordinator falls back when background transport is unavailable',
      () async {
    final baseUri = Uri.parse('http://example.com');
    final client = _RecordingClient();
    final httpTransport = HttpTransport(baseUri, client: client);
    final backgroundTransport = _FailingBackgroundTransport(baseUri);
    var fallbackNotified = false;

    final transport = OptionalBackgroundTransport(
      backgroundTransport: backgroundTransport,
      fallbackTransport: httpTransport,
      onFallback: () {
        fallbackNotified = true;
      },
    );
    final coordinator = TransferCoordinator(
      transport: transport,
      store: InMemoryTransferStateStore(),
    );

    await coordinator.sendReceipt(
      sessionId: 'session-1',
      transferId: 'transfer-1',
      transferToken: 'token-1',
    );

    expect(fallbackNotified, isTrue);
    expect(client.requestCount, equals(1));
  });
}

class _FailingBackgroundTransport extends BackgroundUrlSessionTransport {
  _FailingBackgroundTransport(Uri baseUri) : super(baseUri);

  @override
  Future<void> sendReceipt({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    throw MissingPluginException('Missing background transport');
  }
}

class _RecordingClient extends http.BaseClient {
  int requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount += 1;
    return http.StreamedResponse(Stream<List<int>>.empty(), 200);
  }
}
