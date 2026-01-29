import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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

enum P2PIceMode {
  direct,
  relay,
}

class P2PContext {
  P2PContext({
    required this.sessionId,
    required this.claimId,
    required this.token,
    required this.isInitiator,
    this.iceMode = P2PIceMode.direct,
  });

  final String sessionId;
  final String claimId;
  final String token;
  final bool isInitiator;
  final P2PIceMode iceMode;

  String get cacheKey => '$sessionId:$claimId:${isInitiator ? 'offer' : 'answer'}:${iceMode.name}';
}

abstract class P2PFallbackTransport implements Transport {
  bool get usingFallback;
  bool isFallbackRequested(String transferId);
  void requestFallback(String transferId);
  void forceFallback();
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

class OptionalBackgroundTransport implements Transport {
  OptionalBackgroundTransport({
    required BackgroundUrlSessionTransport backgroundTransport,
    required Transport fallbackTransport,
    void Function()? onFallback,
  })  : _background = backgroundTransport,
        _fallback = fallbackTransport,
        _onFallback = onFallback;

  final BackgroundUrlSessionTransport _background;
  final Transport _fallback;
  final void Function()? _onFallback;
  bool _usingFallback = false;
  bool _fallbackNotified = false;

  bool get usingFallback => _usingFallback;

  @override
  Future<TransferInitResult> initTransfer({
    required String sessionId,
    required String transferToken,
    required Uint8List manifestCiphertext,
    required int totalBytes,
    String? transferId,
  }) {
    return _run((transport) {
      return transport.initTransfer(
        sessionId: sessionId,
        transferToken: transferToken,
        manifestCiphertext: manifestCiphertext,
        totalBytes: totalBytes,
        transferId: transferId,
      );
    });
  }

  @override
  Future<void> sendChunk({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required Uint8List data,
  }) {
    return _run((transport) {
      return transport.sendChunk(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        offset: offset,
        data: data,
      );
    });
  }

  @override
  Future<void> finalizeTransfer({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    return _run((transport) {
      return transport.finalizeTransfer(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
      );
    });
  }

  @override
  Future<Uint8List> fetchManifest({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    return _run((transport) {
      return transport.fetchManifest(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
      );
    });
  }

  @override
  Future<Uint8List> fetchRange({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int offset,
    required int length,
  }) {
    return _run((transport) {
      return transport.fetchRange(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        offset: offset,
        length: length,
      );
    });
  }

  @override
  Future<void> sendReceipt({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    return _run((transport) {
      return transport.sendReceipt(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
      );
    });
  }

  @override
  Future<ScanInitResult> scanInit({
    required String sessionId,
    required String transferId,
    required String transferToken,
    required int totalBytes,
    required int chunkSize,
  }) {
    return _run((transport) {
      return transport.scanInit(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        totalBytes: totalBytes,
        chunkSize: chunkSize,
      );
    });
  }

  @override
  Future<void> scanChunk({
    required String scanId,
    required String transferToken,
    required int chunkIndex,
    required Uint8List data,
  }) {
    return _run((transport) {
      return transport.scanChunk(
        scanId: scanId,
        transferToken: transferToken,
        chunkIndex: chunkIndex,
        data: data,
      );
    });
  }

  @override
  Future<ScanFinalizeResult> scanFinalize({
    required String scanId,
    required String transferToken,
  }) {
    return _run((transport) {
      return transport.scanFinalize(
        scanId: scanId,
        transferToken: transferToken,
      );
    });
  }

  Future<T> _run<T>(Future<T> Function(Transport transport) action) async {
    if (_usingFallback) {
      return action(_fallback);
    }
    try {
      return await action(_background);
    } on MissingPluginException {
      _switchToFallback();
      return action(_fallback);
    }
  }

  void _switchToFallback() {
    if (_usingFallback) {
      return;
    }
    _usingFallback = true;
    if (_fallbackNotified) {
      return;
    }
    _fallbackNotified = true;
    _onFallback?.call();
  }
}

class P2PTransport implements P2PFallbackTransport {
  P2PTransport({
    required Uri baseUri,
    required P2PContext context,
    required Transport fallbackTransport,
    http.Client? client,
    Duration pollInterval = const Duration(milliseconds: 800),
  })  : _baseUri = baseUri,
        _context = context,
        _fallback = fallbackTransport,
        _client = client ?? http.Client(),
        _pollInterval = pollInterval;

  final Uri _baseUri;
  final P2PContext _context;
  final Transport _fallback;
  final http.Client _client;
  final Duration _pollInterval;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  Completer<void>? _connectCompleter;
  bool _polling = false;
  bool _usingFallback = false;
  bool _remoteDescriptionSet = false;
  final Map<String, Completer<void>> _pendingAcks = {};
  final Map<String, Completer<Uint8List>> _pendingChunks = {};
  final Map<String, Uint8List> _chunkCache = {};
  final Map<String, bool> _fallbackRequests = {};
  final List<RTCIceCandidate> _queuedCandidates = [];

  @override
  bool get usingFallback => _usingFallback;

  @override
  bool isFallbackRequested(String transferId) {
    return _fallbackRequests[transferId] == true;
  }

  @override
  void requestFallback(String transferId) {
    _fallbackRequests[transferId] = true;
    _sendDataMessage({
      'type': 'fallback',
      'transfer_id': transferId,
    });
  }

  @override
  void forceFallback() {
    if (_usingFallback) {
      return;
    }
    _usingFallback = true;
    _connectCompleter?.complete();
    _connectCompleter = null;
    _peerConnection?.close();
    _dataChannel?.close();
    _failPending(TransportException('p2p_fallback'));
  }

  @override
  Future<TransferInitResult> initTransfer({
    required String sessionId,
    required String transferToken,
    required Uint8List manifestCiphertext,
    required int totalBytes,
    String? transferId,
  }) {
    return _fallback.initTransfer(
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
      return _fallback.sendChunk(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        offset: offset,
        data: data,
      );
    }
    await _ensureConnected();
    if (_usingFallback || _dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen) {
      forceFallback();
      return _fallback.sendChunk(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        offset: offset,
        data: data,
      );
    }
    if (isFallbackRequested(transferId)) {
      forceFallback();
      return _fallback.sendChunk(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        offset: offset,
        data: data,
      );
    }

    final key = _chunkKey(transferId, offset);
    final ack = Completer<void>();
    _pendingAcks[key] = ack;
    _sendDataMessage({
      'type': 'chunk',
      'transfer_id': transferId,
      'offset': offset,
      'data_b64': base64Encode(data),
    });
    await ack.future;
  }

  @override
  Future<void> finalizeTransfer({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    return _fallback.finalizeTransfer(
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
    return _fallback.fetchManifest(
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
    if (_usingFallback) {
      return _fallback.fetchRange(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        offset: offset,
        length: length,
      );
    }
    await _ensureConnected();
    if (_usingFallback || _dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen) {
      forceFallback();
      return _fallback.fetchRange(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        offset: offset,
        length: length,
      );
    }
    if (isFallbackRequested(transferId)) {
      forceFallback();
      return _fallback.fetchRange(
        sessionId: sessionId,
        transferId: transferId,
        transferToken: transferToken,
        offset: offset,
        length: length,
      );
    }

    final key = _chunkKey(transferId, offset);
    final cached = _chunkCache.remove(key);
    if (cached != null) {
      return cached;
    }
    final completer = Completer<Uint8List>();
    _pendingChunks[key] = completer;
    return completer.future;
  }

  @override
  Future<void> sendReceipt({
    required String sessionId,
    required String transferId,
    required String transferToken,
  }) {
    return _fallback.sendReceipt(
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
    return _fallback.scanInit(
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
    return _fallback.scanChunk(
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
    return _fallback.scanFinalize(
      scanId: scanId,
      transferToken: transferToken,
    );
  }

  Future<void> _ensureConnected() async {
    if (_usingFallback) {
      return;
    }
    if (_connectCompleter != null) {
      return _connectCompleter!.future;
    }
    _connectCompleter = Completer<void>();
    unawaited(_connect());
    return _connectCompleter!.future;
  }

  Future<void> _connect() async {
    try {
      final iceConfig = await _fetchIceConfig();
      if (iceConfig == null) {
        forceFallback();
        return;
      }

      final peerConnection = await createPeerConnection({
        'iceServers': _buildIceServers(iceConfig),
      });
      _peerConnection = peerConnection;
      peerConnection.onIceCandidate = _onIceCandidate;
      peerConnection.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          forceFallback();
        }
      };
      peerConnection.onIceConnectionState = (state) {
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
            state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
          forceFallback();
        }
      };

      if (_context.isInitiator) {
        final channel =
            await peerConnection.createDataChannel('ud-data', RTCDataChannelInit());
        _setupDataChannel(channel);
        final offer = await peerConnection.createOffer();
        await peerConnection.setLocalDescription(offer);
        await _postOffer(offer.sdp ?? '');
      } else {
        peerConnection.onDataChannel = (channel) {
          _setupDataChannel(channel);
        };
      }

      _startPolling();
    } catch (_) {
      forceFallback();
    }
  }

  void _setupDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onMessage = _handleDataMessage;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _connectCompleter?.complete();
        _connectCompleter = null;
      }
      if (state == RTCDataChannelState.RTCDataChannelClosed) {
        forceFallback();
      }
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _connectCompleter?.complete();
      _connectCompleter = null;
    }
  }

  void _handleDataMessage(RTCDataChannelMessage message) {
    if (message.isBinary) {
      return;
    }
    final raw = message.text;
    if (raw == null || raw.isEmpty) {
      return;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    final type = decoded['type']?.toString() ?? '';
    final transferId = decoded['transfer_id']?.toString() ?? '';
    if (type == 'fallback') {
      if (transferId.isNotEmpty) {
        _fallbackRequests[transferId] = true;
      }
      forceFallback();
      return;
    }
    if (type == 'ack') {
      if (transferId.isEmpty) {
        return;
      }
      final offset = _parseInt(decoded['offset']);
      final key = _chunkKey(transferId, offset);
      _pendingAcks.remove(key)?.complete();
      return;
    }
    if (type == 'chunk') {
      if (transferId.isEmpty) {
        return;
      }
      final offset = _parseInt(decoded['offset']);
      final payload = decoded['data_b64']?.toString() ?? '';
      if (payload.isEmpty) {
        return;
      }
      final data = base64Decode(payload);
      final key = _chunkKey(transferId, offset);
      final pending = _pendingChunks.remove(key);
      if (pending != null) {
        pending.complete(data);
      } else {
        _chunkCache[key] = data;
      }
      _sendDataMessage({
        'type': 'ack',
        'transfer_id': transferId,
        'offset': offset,
      });
    }
  }

  void _sendDataMessage(Map<String, dynamic> message) {
    if (_usingFallback) {
      return;
    }
    final channel = _dataChannel;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    channel.send(RTCDataChannelMessage(jsonEncode(message)));
  }

  void _startPolling() {
    if (_polling) {
      return;
    }
    _polling = true;
    unawaited(_pollLoop());
  }

  Future<void> _pollLoop() async {
    while (!_usingFallback && _peerConnection != null) {
      await _pollOnce();
      await Future<void>.delayed(_pollInterval);
    }
    _polling = false;
  }

  Future<void> _pollOnce() async {
    final uri = _baseUri.replace(
      path: '/v1/p2p/poll',
      queryParameters: {
        'session_id': _context.sessionId,
        'claim_id': _context.claimId,
      },
    );
    final response = await _client.get(
      uri,
      headers: {'Authorization': 'Bearer ${_context.token}'},
    );
    if (response.statusCode >= 400) {
      return;
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>?;
    final list = payload?['messages'];
    if (list is! List) {
      return;
    }
    for (final item in list) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final message = _P2PSignalMessage.fromJson(item);
      await _handleSignalMessage(message);
    }
  }

  Future<void> _handleSignalMessage(_P2PSignalMessage message) async {
    final pc = _peerConnection;
    if (pc == null) {
      return;
    }
    if (message.type == 'offer' && !_context.isInitiator) {
      if (_remoteDescriptionSet || message.sdp == null) {
        return;
      }
      await pc.setRemoteDescription(
        RTCSessionDescription(message.sdp, 'offer'),
      );
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await _postAnswer(answer.sdp ?? '');
      return;
    }
    if (message.type == 'answer' && _context.isInitiator) {
      if (_remoteDescriptionSet || message.sdp == null) {
        return;
      }
      await pc.setRemoteDescription(
        RTCSessionDescription(message.sdp, 'answer'),
      );
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();
      return;
    }
    if (message.type == 'ice' && message.candidate != null) {
      final candidate = _decodeCandidate(message.candidate!);
      if (candidate == null) {
        return;
      }
      if (!_remoteDescriptionSet) {
        _queuedCandidates.add(candidate);
        return;
      }
      await pc.addCandidate(candidate);
    }
  }

  Future<void> _flushRemoteCandidates() async {
    if (_queuedCandidates.isEmpty) {
      return;
    }
    final pc = _peerConnection;
    if (pc == null) {
      return;
    }
    for (final candidate in _queuedCandidates) {
      await pc.addCandidate(candidate);
    }
    _queuedCandidates.clear();
  }

  Future<_P2PIceConfig?> _fetchIceConfig() async {
    final uri = _baseUri.replace(
      path: '/v1/p2p/ice_config',
      queryParameters: {
        'session_id': _context.sessionId,
        'claim_id': _context.claimId,
        'mode': _context.iceMode == P2PIceMode.relay ? 'relay' : 'direct',
      },
    );
    final response = await _client.get(
      uri,
      headers: {'Authorization': 'Bearer ${_context.token}'},
    );
    if (response.statusCode == 409) {
      return null;
    }
    if (response.statusCode >= 400) {
      return null;
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>?;
    if (payload == null) {
      return null;
    }
    return _P2PIceConfig.fromJson(payload);
  }

  List<Map<String, dynamic>> _buildIceServers(_P2PIceConfig config) {
    final servers = <Map<String, dynamic>>[];
    for (final url in config.stunUrls) {
      servers.add({'urls': [url]});
    }
    for (final url in config.turnUrls) {
      final server = <String, dynamic>{'urls': [url]};
      if (config.username != null && config.credential != null) {
        server['username'] = config.username;
        server['credential'] = config.credential;
      }
      servers.add(server);
    }
    return servers;
  }

  void _onIceCandidate(RTCIceCandidate candidate) {
    if (candidate.candidate == null || candidate.candidate!.isEmpty) {
      return;
    }
    final payload = jsonEncode({
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    });
    unawaited(_postIce(payload));
  }

  Future<void> _postOffer(String sdp) {
    final uri = _baseUri.resolve('/v1/p2p/offer');
    return _client.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_context.token}',
      },
      body: jsonEncode({
        'session_id': _context.sessionId,
        'claim_id': _context.claimId,
        'sdp': sdp,
      }),
    );
  }

  Future<void> _postAnswer(String sdp) {
    final uri = _baseUri.resolve('/v1/p2p/answer');
    return _client.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_context.token}',
      },
      body: jsonEncode({
        'session_id': _context.sessionId,
        'claim_id': _context.claimId,
        'sdp': sdp,
      }),
    );
  }

  Future<void> _postIce(String candidate) {
    final uri = _baseUri.resolve('/v1/p2p/ice');
    return _client.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_context.token}',
      },
      body: jsonEncode({
        'session_id': _context.sessionId,
        'claim_id': _context.claimId,
        'candidate': candidate,
      }),
    );
  }

  RTCIceCandidate? _decodeCandidate(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        final candidate = decoded['candidate']?.toString();
        if (candidate == null || candidate.isEmpty) {
          return null;
        }
        return RTCIceCandidate(
          candidate,
          decoded['sdpMid']?.toString(),
          _parseInt(decoded['sdpMLineIndex']),
        );
      }
    } catch (_) {}
    if (payload.isEmpty) {
      return null;
    }
    return RTCIceCandidate(payload, null, null);
  }

  void _failPending(Object err) {
    for (final entry in _pendingAcks.entries) {
      entry.value.completeError(err);
    }
    _pendingAcks.clear();
    for (final entry in _pendingChunks.entries) {
      entry.value.completeError(err);
    }
    _pendingChunks.clear();
  }

  String _chunkKey(String transferId, int offset) => '$transferId:$offset';

  int _parseInt(dynamic value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _P2PIceConfig {
  _P2PIceConfig({
    required this.stunUrls,
    required this.turnUrls,
    required this.username,
    required this.credential,
  });

  final List<String> stunUrls;
  final List<String> turnUrls;
  final String? username;
  final String? credential;

  factory _P2PIceConfig.fromJson(Map<String, dynamic> json) {
    List<String> parseList(String key) {
      final raw = json[key];
      if (raw is! List) {
        return const [];
      }
      return raw.map((item) => item.toString()).where((item) => item.isNotEmpty).toList();
    }

    return _P2PIceConfig(
      stunUrls: parseList('stun_urls'),
      turnUrls: parseList('turn_urls'),
      username: json['username']?.toString(),
      credential: json['credential']?.toString(),
    );
  }
}

class _P2PSignalMessage {
  const _P2PSignalMessage({
    required this.type,
    this.sdp,
    this.candidate,
  });

  final String type;
  final String? sdp;
  final String? candidate;

  factory _P2PSignalMessage.fromJson(Map<String, dynamic> json) {
    return _P2PSignalMessage(
      type: json['type']?.toString() ?? '',
      sdp: json['sdp']?.toString(),
      candidate: json['candidate']?.toString(),
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
