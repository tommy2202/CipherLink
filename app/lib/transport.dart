import 'dart:typed_data';

import 'package:http/http.dart' as http;

abstract class Transport {
  Future<void> sendChunk({
    required String transferId,
    required int offset,
    required Uint8List data,
  });

  Future<Uint8List> fetchRange({
    required String transferId,
    required int offset,
    required int length,
  });
}

class HttpTransport implements Transport {
  HttpTransport(this.baseUri, {http.Client? client})
      : _client = client ?? http.Client();

  final Uri baseUri;
  final http.Client _client;

  @override
  Future<void> sendChunk({
    required String transferId,
    required int offset,
    required Uint8List data,
  }) async {
    final uri = baseUri.resolve('/v1/transfers/$transferId/chunks');
    final response = await _client.post(
      uri,
      headers: {
        'Content-Type': 'application/octet-stream',
        'X-Chunk-Offset': offset.toString(),
      },
      body: data,
    );

    if (response.statusCode >= 400) {
      throw TransportException('sendChunk failed: ${response.statusCode}');
    }
  }

  @override
  Future<Uint8List> fetchRange({
    required String transferId,
    required int offset,
    required int length,
  }) async {
    final uri = baseUri.resolve(
      '/v1/transfers/$transferId/range?offset=$offset&length=$length',
    );
    final response = await _client.get(uri);
    if (response.statusCode >= 400) {
      throw TransportException('fetchRange failed: ${response.statusCode}');
    }
    return response.bodyBytes;
  }
}

class TransportException implements Exception {
  TransportException(this.message);

  final String message;

  @override
  String toString() => message;
}
