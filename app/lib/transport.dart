import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class TransferInitResult {
  const TransferInitResult(this.transferId);

  final String transferId;
}

class ScanInitResult {
  const ScanInitResult({
    required this.scanId,
    required this.scanKeyB64,
  });

  final String scanId;
  final String scanKeyB64;
}

class ScanFinalizeResult {
  const ScanFinalizeResult(this.status);

  final String status;
}

abstract class Transport {
  Future<TransferInitResult> initTransfer({
    required String sessionId,
    required String transferToken,
    required Uint8List manifestCiphertext,
    required int totalBytes,
    String? transferId,
  });

  Future<void> sendChunk({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required Uint8List data,
  });

  Future<void> finalizeTransfer({
    required String sessionId,
    required String transferId,
    required String transferToken,
  });

  Future<Uint8List> fetchManifest({
    required String sessionId,
    required String transferId,
    required String transferToken,
  });

  Future<Uint8List> fetchRange({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required int length,
  });

  Future<void> sendReceipt({
    required String sessionId,
    required String transferId,
    required String transferToken,
  });

  Future<ScanInitResult> scanInit({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int totalBytes,
    required int chunkSize,
  });

  Future<void> scanChunk({
    required String scanId,
    required String transferToken,
    required int chunkIndex,
    required Uint8List data,
  });

  Future<ScanFinalizeResult> scanFinalize({
    required String scanId,
    required String transferToken,
  });
}

class HttpTransport implements Transport {
  HttpTransport(this.baseUri, {http.Client? client})
      : _client = client ?? http.Client();

  final Uri baseUri;
  final http.Client _client;

  @override
  Future<TransferInitResult> initTransfer({
    required String sessionId,
    required String transferToken,
    required Uint8List manifestCiphertext,
    required int totalBytes,
    String? transferId,
  }) async {
    final uri = baseUri.resolve('/v1/transfer/init');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'session_id': sessionId,
        'transfer_token': transferToken,
        'file_manifest_ciphertext_b64': base64Encode(manifestCiphertext),
        'total_bytes': totalBytes,
        if (transferId != null) 'transfer_id': transferId,
      }),
    );

    if (response.statusCode >= 400) {
      throw TransportException('initTransfer failed: ${response.statusCode}');
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final id = payload['transfer_id']?.toString() ?? '';
    if (id.isEmpty) {
      throw TransportException('initTransfer missing transfer_id');
    }
    return TransferInitResult(id);
  }

  @override
  Future<void> sendChunk({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required Uint8List data,
  }) async {
    final uri = baseUri.resolve('/v1/transfer/chunk');
    final response = await _client.put(
      uri,
      headers: {
        'Content-Type': 'application/octet-stream',
        'Authorization': 'Bearer $transferToken',
        'session_id': sessionId,
        'transfer_id': transferId,
        'offset': offset.toString(),
      },
      body: data,
    );

    if (response.statusCode >= 400) {
      throw TransportException('sendChunk failed: ${response.statusCode}');
    }
  }

  @override
  Future<void> finalizeTransfer({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) async {
    final uri = baseUri.resolve('/v1/transfer/finalize');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'session_id': sessionId,
        'transfer_id': transferId,
        'transfer_token': transferToken,
      }),
    );

    if (response.statusCode >= 400) {
      throw TransportException('finalizeTransfer failed: ${response.statusCode}');
    }
  }

  @override
  Future<Uint8List> fetchManifest({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) async {
    final uri = baseUri.replace(
      path: '/v1/transfer/manifest',
      queryParameters: {
        'session_id': sessionId,
        'transfer_id': transferId,
      },
    );
    final response = await _client.get(
      uri,
      headers: {'Authorization': 'Bearer $transferToken'},
    );
    if (response.statusCode >= 400) {
      throw TransportException('fetchManifest failed: ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  @override
  Future<Uint8List> fetchRange({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required int length,
  }) async {
    final uri = baseUri.replace(
      path: '/v1/transfer/download',
      queryParameters: {
        'session_id': sessionId,
        'transfer_id': transferId,
      },
    );
    final response = await _client.get(
      uri,
      headers: {
        'Authorization': 'Bearer $transferToken',
        'Range': 'bytes=$offset-${offset + length - 1}',
      },
    );
    if (response.statusCode >= 400) {
      throw TransportException('fetchRange failed: ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  @override
  Future<void> sendReceipt({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) async {
    final uri = baseUri.resolve('/v1/transfer/receipt');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'session_id': sessionId,
        'transfer_id': transferId,
        'transfer_token': transferToken,
        'status': 'complete',
      }),
    );

    if (response.statusCode >= 400) {
      throw TransportException('sendReceipt failed: ${response.statusCode}');
    }
  }

  @override
  Future<ScanInitResult> scanInit({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int totalBytes,
    required int chunkSize,
  }) async {
    final uri = baseUri.resolve('/v1/transfer/scan_init');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'session_id': sessionId,
        'transfer_id': transferId,
        'transfer_token': transferToken,
        'total_bytes': totalBytes,
        'chunk_size': chunkSize,
      }),
    );
    if (response.statusCode >= 400) {
      throw TransportException('scanInit failed: ${response.statusCode}');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final scanId = payload['scan_id']?.toString() ?? '';
    final scanKey = payload['scan_key_b64']?.toString() ?? '';
    if (scanId.isEmpty || scanKey.isEmpty) {
      throw TransportException('scanInit missing fields');
    }
    return ScanInitResult(scanId: scanId, scanKeyB64: scanKey);
  }

  @override
  Future<void> scanChunk({
    required String scanId,
    required String transferToken,
    required int chunkIndex,
    required Uint8List data,
  }) async {
    final uri = baseUri.resolve('/v1/transfer/scan_chunk');
    final response = await _client.put(
      uri,
      headers: {
        'Content-Type': 'application/octet-stream',
        'Authorization': 'Bearer $transferToken',
        'scan_id': scanId,
        'chunk_index': chunkIndex.toString(),
      },
      body: data,
    );
    if (response.statusCode >= 400) {
      throw TransportException('scanChunk failed: ${response.statusCode}');
    }
  }

  @override
  Future<ScanFinalizeResult> scanFinalize({
    required String scanId,
    required String transferToken,
  }) async {
    final uri = baseUri.resolve('/v1/transfer/scan_finalize');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'scan_id': scanId,
        'transfer_token': transferToken,
      }),
    );
    if (response.statusCode >= 400) {
      throw TransportException('scanFinalize failed: ${response.statusCode}');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final status = payload['status']?.toString() ?? '';
    return ScanFinalizeResult(status);
  }
}

class TransportException implements Exception {
  TransportException(this.message);

  final String message;

  @override
  String toString() => message;
}
