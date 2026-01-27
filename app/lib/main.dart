import 'dart:convert';

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

  @override
  void dispose() {
    _baseUrlController.dispose();
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
            ],
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
