import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const UniversalDropApp());
}

class UniversalDropApp extends StatelessWidget {
  const UniversalDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UniversalDrop',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _baseUrlController =
      TextEditingController(text: 'http://localhost:8080');
  String _status = 'Idle';
  bool _loading = false;
  bool _creatingSession = false;
  String _sessionStatus = 'No session created yet.';
  SessionCreateResponse? _sessionResponse;
  final TextEditingController _qrPayloadController = TextEditingController();
  final TextEditingController _sessionIdController = TextEditingController();
  final TextEditingController _claimTokenController = TextEditingController();
  final TextEditingController _senderLabelController =
      TextEditingController(text: 'Sender');
  bool _sending = false;
  String _sendStatus = 'Idle';
  String? _claimId;
  String? _claimStatus;
  Timer? _pollTimer;
  bool _refreshingClaims = false;
  String _claimsStatus = 'No pending claims.';
  List<PendingClaim> _pendingClaims = [];
  final Set<String> _trustedFingerprints = {};

  @override
  void dispose() {
    _baseUrlController.dispose();
    _qrPayloadController.dispose();
    _sessionIdController.dispose();
    _claimTokenController.dispose();
    _senderLabelController.dispose();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _pingBackend() async {
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      setState(() {
        _status = 'Enter a base URL first.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _status = 'Pinging...';
    });

    try {
      final baseUri = Uri.parse(baseUrl);
      final response = await http
          .get(baseUri.resolve('/healthz'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        setState(() {
          _status = 'Error: ${response.statusCode}';
        });
        return;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final ok = payload['ok'] == true;
      final version = payload['version']?.toString() ?? 'unknown';
      setState(() {
        _status = ok ? 'OK (version $version)' : 'Unexpected response';
      });
    } catch (err) {
      setState(() {
        _status = 'Failed: $err';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _createSession() async {
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      setState(() {
        _sessionStatus = 'Enter a base URL first.';
      });
      return;
    }

    setState(() {
      _creatingSession = true;
      _sessionStatus = 'Creating session...';
      _sessionResponse = null;
    });

    try {
      final baseUri = Uri.parse(baseUrl);
      final response = await http
          .post(baseUri.resolve('/v1/session/create'))
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        setState(() {
          _sessionStatus = 'Error: ${response.statusCode}';
        });
        return;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final sessionResponse = SessionCreateResponse.fromJson(payload);
      setState(() {
        _sessionResponse = sessionResponse;
        _sessionStatus = 'Session created.';
        _claimsStatus = 'Session created. Refresh to load claims.';
        _pendingClaims = [];
      });
    } catch (err) {
      setState(() {
        _sessionStatus = 'Failed: $err';
      });
    } finally {
      setState(() {
        _creatingSession = false;
      });
    }
  }

  Future<void> _refreshClaims() async {
    final baseUrl = _baseUrlController.text.trim();
    final sessionId = _sessionResponse?.sessionId ?? '';
    if (baseUrl.isEmpty || sessionId.isEmpty) {
      setState(() {
        _claimsStatus = 'Create a session first.';
      });
      return;
    }

    setState(() {
      _refreshingClaims = true;
      _claimsStatus = 'Refreshing claims...';
    });

    try {
      final baseUri = Uri.parse(baseUrl);
      final uri = baseUri.replace(
        path: '/v1/session/poll',
        queryParameters: {'session_id': sessionId},
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) {
        setState(() {
          _claimsStatus = 'Error: ${response.statusCode}';
        });
        return;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final claims = (payload['claims'] as List<dynamic>? ?? [])
          .map((item) => PendingClaim.fromJson(item as Map<String, dynamic>))
          .toList();
      setState(() {
        _pendingClaims = claims;
        _claimsStatus = claims.isEmpty ? 'No pending claims.' : 'Pending claims loaded.';
      });
    } catch (err) {
      setState(() {
        _claimsStatus = 'Failed: $err';
      });
    } finally {
      setState(() {
        _refreshingClaims = false;
      });
    }
  }

  Future<void> _respondToClaim(PendingClaim claim, bool approve) async {
    final baseUrl = _baseUrlController.text.trim();
    final sessionId = _sessionResponse?.sessionId ?? '';
    if (baseUrl.isEmpty || sessionId.isEmpty) {
      setState(() {
        _claimsStatus = 'Create a session first.';
      });
      return;
    }

    setState(() {
      _claimsStatus = approve ? 'Approving...' : 'Rejecting...';
    });

    try {
      final response = await http
          .post(
            Uri.parse(baseUrl).resolve('/v1/session/approve'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'session_id': sessionId,
              'claim_id': claim.claimId,
              'approve': approve,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        setState(() {
          _claimsStatus = 'Error: ${response.statusCode}';
        });
        return;
      }

      if (approve) {
        _trustedFingerprints.add(claim.shortFingerprint);
      }
      await _refreshClaims();
    } catch (err) {
      setState(() {
        _claimsStatus = 'Failed: $err';
      });
    }
  }

  Future<void> _claimSession() async {
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      setState(() {
        _sendStatus = 'Enter a base URL first.';
      });
      return;
    }

    final parsed = _parseQrPayload(_qrPayloadController.text.trim());
    final sessionId = parsed.sessionId.isNotEmpty
        ? parsed.sessionId
        : _sessionIdController.text.trim();
    final claimToken = parsed.claimToken.isNotEmpty
        ? parsed.claimToken
        : _claimTokenController.text.trim();
    final senderLabel = _senderLabelController.text.trim();

    if (sessionId.isEmpty || claimToken.isEmpty) {
      setState(() {
        _sendStatus = 'Provide a QR payload or session ID + claim token.';
      });
      return;
    }
    if (senderLabel.isEmpty) {
      setState(() {
        _sendStatus = 'Provide a sender label.';
      });
      return;
    }

    setState(() {
      _sending = true;
      _sendStatus = 'Claiming session...';
      _claimId = null;
      _claimStatus = null;
    });

    try {
      final keyPair = await X25519().newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final pubKeyB64 = base64Encode(publicKey.bytes);

      final response = await http
          .post(
            Uri.parse(baseUrl).resolve('/v1/session/claim'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'session_id': sessionId,
              'claim_token': claimToken,
              'sender_label': senderLabel,
              'sender_pubkey_b64': pubKeyB64,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        setState(() {
          _sendStatus = 'Error: ${response.statusCode}';
        });
        return;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final claimId = payload['claim_id']?.toString();
      final status = payload['status']?.toString() ?? 'pending';
      setState(() {
        _claimId = claimId;
        _claimStatus = status;
        _sendStatus = 'Claimed. Polling for approval...';
      });
      _startPolling(sessionId, claimToken);
    } catch (err) {
      setState(() {
        _sendStatus = 'Failed: $err';
      });
    } finally {
      setState(() {
        _sending = false;
      });
    }
  }

  void _startPolling(String sessionId, String claimToken) {
    _pollTimer?.cancel();
    _pollTimer = Timer(const Duration(seconds: 1), () {
      _pollOnce(sessionId, claimToken);
    });
  }

  Future<void> _pollOnce(String sessionId, String claimToken) async {
    try {
      final baseUrl = _baseUrlController.text.trim();
      final baseUri = Uri.parse(baseUrl);
      final uri = baseUri.replace(
        path: '/v1/session/poll',
        queryParameters: {
          'session_id': sessionId,
          'claim_token': claimToken,
        },
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        setState(() {
          _sendStatus = 'Poll error: ${response.statusCode}';
        });
        return;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final status = payload['status']?.toString() ?? 'pending';
      setState(() {
        _claimStatus = status;
        _sendStatus = 'Status: $status';
      });

      if (status == 'pending') {
        _pollTimer = Timer(const Duration(seconds: 2), () {
          _pollOnce(sessionId, claimToken);
        });
      }
    } catch (err) {
      setState(() {
        _sendStatus = 'Poll failed: $err';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UniversalDrop')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Backend base URL'),
            const SizedBox(height: 8),
            TextField(
              controller: _baseUrlController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'http://localhost:8080',
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loading ? null : _pingBackend,
              child: Text(_loading ? 'Pinging...' : 'Ping Backend'),
            ),
            const SizedBox(height: 16),
            Text('Status: $_status'),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              'Receive Session',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _creatingSession ? null : _createSession,
              child: Text(
                _creatingSession ? 'Creating...' : 'Create Session',
              ),
            ),
            const SizedBox(height: 12),
            Text(_sessionStatus),
            if (_sessionResponse != null) ...[
              const SizedBox(height: 12),
              Text('Expires at: ${_sessionResponse!.expiresAt}'),
              Text('Short code: ${_sessionResponse!.shortCode}'),
              const SizedBox(height: 8),
              const Text('QR payload:'),
              SelectableText(_sessionResponse!.qrPayload),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _refreshingClaims ? null : _refreshClaims,
                child: Text(_refreshingClaims ? 'Refreshing...' : 'Refresh Claims'),
              ),
              const SizedBox(height: 8),
              Text(_claimsStatus),
              const SizedBox(height: 8),
              ..._pendingClaims.map((claim) {
                final trusted = _trustedFingerprints.contains(claim.shortFingerprint);
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Sender: ${claim.senderLabel}'),
                        Text('Fingerprint: ${claim.shortFingerprint}'),
                        Text('Claim ID: ${claim.claimId}'),
                        if (trusted)
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text(
                              'Seen before',
                              style: TextStyle(color: Colors.green),
                            ),
                          )
                        else
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text(
                              'New device',
                              style: TextStyle(color: Colors.orange),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            ElevatedButton(
                              onPressed: () => _respondToClaim(claim, true),
                              child: const Text('Approve'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: () => _respondToClaim(claim, false),
                              child: const Text('Reject'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              'Send Session',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _qrPayloadController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'QR payload (optional)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sessionIdController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Session ID',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _claimTokenController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Claim token',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _senderLabelController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Sender label',
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _sending ? null : _claimSession,
              child: Text(_sending ? 'Claiming...' : 'Claim Session'),
            ),
            const SizedBox(height: 12),
            Text(_sendStatus),
            if (_claimId != null) Text('Claim ID: $_claimId'),
            if (_claimStatus != null) Text('Claim status: $_claimStatus'),
          ],
        ),
      ),
    );
  }
}

class SessionCreateResponse {
  SessionCreateResponse({
    required this.sessionId,
    required this.expiresAt,
    required this.claimToken,
    required this.receiverPubKeyB64,
    required this.qrPayload,
  }) : shortCode = deriveShortCode(claimToken);

  final String sessionId;
  final String expiresAt;
  final String claimToken;
  final String receiverPubKeyB64;
  final String qrPayload;
  final String shortCode;

  static SessionCreateResponse fromJson(Map<String, dynamic> json) {
    return SessionCreateResponse(
      sessionId: json['session_id']?.toString() ?? '',
      expiresAt: json['expires_at']?.toString() ?? '',
      claimToken: json['claim_token']?.toString() ?? '',
      receiverPubKeyB64: json['receiver_pubkey_b64']?.toString() ?? '',
      qrPayload: json['qr_payload']?.toString() ?? '',
    );
  }
}

class PendingClaim {
  PendingClaim({
    required this.claimId,
    required this.senderLabel,
    required this.shortFingerprint,
  });

  final String claimId;
  final String senderLabel;
  final String shortFingerprint;

  factory PendingClaim.fromJson(Map<String, dynamic> json) {
    return PendingClaim(
      claimId: json['claim_id']?.toString() ?? '',
      senderLabel: json['sender_label']?.toString() ?? '',
      shortFingerprint: json['short_fingerprint']?.toString() ?? '',
    );
  }
}

String deriveShortCode(String claimToken) {
  final sanitized = claimToken.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  if (sanitized.isEmpty) {
    return '';
  }
  if (sanitized.length <= 8) {
    return sanitized.toUpperCase();
  }
  return sanitized.substring(sanitized.length - 8).toUpperCase();
}

ParsedQrPayload _parseQrPayload(String payload) {
  if (payload.isEmpty) {
    return const ParsedQrPayload();
  }
  try {
    final uri = Uri.parse(payload);
    final sessionId = uri.queryParameters['session_id'] ?? '';
    final claimToken = uri.queryParameters['claim_token'] ?? '';
    if (sessionId.isEmpty && claimToken.isEmpty) {
      return const ParsedQrPayload();
    }
    return ParsedQrPayload(sessionId: sessionId, claimToken: claimToken);
  } catch (_) {
    return const ParsedQrPayload();
  }
}

class ParsedQrPayload {
  const ParsedQrPayload({this.sessionId = '', this.claimToken = ''});

  final String sessionId;
  final String claimToken;
}
