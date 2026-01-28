import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';

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
      throw TransportException(
        'initTransfer failed: ${response.statusCode}',
        statusCode: response.statusCode,
      );
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
      throw TransportException(
        'sendChunk failed: ${response.statusCode}',
        statusCode: response.statusCode,
      );
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
      throw TransportException(
        'finalizeTransfer failed: ${response.statusCode}',
        statusCode: response.statusCode,
      );
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
      throw TransportException(
        'fetchManifest failed: ${response.statusCode}',
        statusCode: response.statusCode,
      );
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
      throw TransportException(
        'fetchRange failed: ${response.statusCode}',
        statusCode: response.statusCode,
      );
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
      throw TransportException(
        'sendReceipt failed: ${response.statusCode}',
        statusCode: response.statusCode,
      );
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
      throw TransportException(
        'scanInit failed: ${response.statusCode}',
        statusCode: response.statusCode,
      );
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
      throw TransportException(
        'scanChunk failed: ${response.statusCode}',
        statusCode: response.statusCode,
      );
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
      throw TransportException(
        'scanFinalize failed: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final status = payload['status']?.toString() ?? '';
    return ScanFinalizeResult(status);
  }
}

class BackgroundUrlSessionTransport implements Transport {
  BackgroundUrlSessionTransport(
    this.baseUri, {
    http.Client? client,
    MethodChannel? channel,
  })  : _http = HttpTransport(baseUri, client: client),
        _channel = channel ??
            const MethodChannel('universaldrop/background_url_session');

  final Uri baseUri;
  final HttpTransport _http;
  final MethodChannel _channel;

  @override
  Future<TransferInitResult> initTransfer({
    required String sessionId,
    required String transferToken,
    required Uint8List manifestCiphertext,
    required int totalBytes,
    String? transferId,
  }) {
    return _http.initTransfer(
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
  }) {
    return _http.sendChunk(
      sessionId: sessionId,
      transferId: transferId,
      transferToken: transferToken,
      offset: offset,
      data: data,
    );
  }

  @override
  Future<void> finalizeTransfer({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    return _http.finalizeTransfer(
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
  }) async {
    if (!Platform.isIOS) {
      return _http.fetchManifest(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
      );
    }
    final uri = baseUri.replace(
      path: '/v1/transfer/manifest',
      queryParameters: {
        'session_id': sessionId,
        'transfer_id': transferId,
      },
    );
    final bytes = await _channel.invokeMethod<Uint8List>('fetchBytes', {
      'url': uri.toString(),
      'headers': {'Authorization': 'Bearer $transferToken'},
    });
    if (bytes != null) {
      return bytes;
    }
    return _http.fetchManifest(
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
  }) async {
    if (!Platform.isIOS) {
      return _http.fetchRange(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        offset: offset,
        length: length,
      );
    }
    final uri = baseUri.replace(
      path: '/v1/transfer/download',
      queryParameters: {
        'session_id': sessionId,
        'transfer_id': transferId,
      },
    );
    final bytes = await _channel.invokeMethod<Uint8List>('fetchRange', {
      'url': uri.toString(),
      'headers': {
        'Authorization': 'Bearer $transferToken',
        'Range': 'bytes=$offset-${offset + length - 1}',
      },
    });
    if (bytes != null) {
      return bytes;
    }
    return _http.fetchRange(
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
    return _http.sendReceipt(
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
    return _http.scanInit(
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
    return _http.scanChunk(
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
    return _http.scanFinalize(
      scanId: scanId,
      transferToken: transferToken,
    );
  }
}

class TransportException implements Exception {
  TransportException(
    this.message, {
    this.statusCode,
    this.cause,
  });

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => message;
}
