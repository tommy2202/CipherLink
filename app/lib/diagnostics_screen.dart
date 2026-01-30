import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'transfer_state_store.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    super.key,
    required this.baseUrl,
  });

  final String baseUrl;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  String _secureStorageStatus = 'checking...';
  String _connectivityStatus = 'checking...';
  String _connectivityStreamStatus = 'listening';
  String _photosPermissionStatus = 'checking...';
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    _runChecks();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  Future<void> _runChecks() async {
    await Future.wait([
      _checkSecureStorage(),
      _checkConnectivity(),
      _checkPhotosPermission(),
    ]);
  }

  Future<void> _checkSecureStorage() async {
    const key = 'ud_diag_secure_storage';
    final store = FlutterSecureStore();
    try {
      await store.write(key: key, value: 'ok');
      final value = await store.read(key: key);
      await store.delete(key: key);
      if (!mounted) {
        return;
      }
      setState(() {
        _secureStorageStatus = value == 'ok' ? 'available' : 'unavailable';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _secureStorageStatus = 'unavailable';
      });
    }
  }

  Future<void> _checkConnectivity() async {
    try {
      final result = await Connectivity().checkConnectivity();
      if (!mounted) {
        return;
      }
      setState(() {
        _connectivityStatus = _formatConnectivity(result);
        _connectivityStreamStatus = 'listening';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _connectivityStatus = 'error';
        _connectivityStreamStatus = 'error';
      });
      return;
    }

    await _connectivitySubscription?.cancel();
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((result) {
      if (!mounted) {
        return;
      }
      setState(() {
        _connectivityStatus = _formatConnectivity(result);
        _connectivityStreamStatus = 'listening';
      });
    }, onError: (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _connectivityStreamStatus = 'error';
      });
    });
  }

  Future<void> _checkPhotosPermission() async {
    try {
      final state = await PhotoManager.permissionState;
      if (!mounted) {
        return;
      }
      setState(() {
        _photosPermissionStatus = _formatPhotoPermission(state);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _photosPermissionStatus = 'unknown';
      });
    }
  }

  String _formatConnectivity(ConnectivityResult result) {
    switch (result) {
      case ConnectivityResult.bluetooth:
        return 'bluetooth';
      case ConnectivityResult.wifi:
        return 'wifi';
      case ConnectivityResult.ethernet:
        return 'ethernet';
      case ConnectivityResult.mobile:
        return 'mobile';
      case ConnectivityResult.vpn:
        return 'vpn';
      case ConnectivityResult.other:
        return 'other';
      case ConnectivityResult.none:
        return 'none';
    }
  }

  String _formatPhotoPermission(PermissionState state) {
    if (state.isAuth) {
      return 'granted';
    }
    final raw = state.toString().split('.').last;
    if (raw.isEmpty) {
      return 'unknown';
    }
    return raw;
  }

  String _displayBaseUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return 'Not set';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      return trimmed;
    }
    return uri.replace(userInfo: '', query: '', fragment: '').toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Backend base URL'),
            subtitle: Text(_displayBaseUrl(widget.baseUrl)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Secure storage'),
            subtitle: Text(_secureStorageStatus),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Connectivity'),
            subtitle: Text(
              'Current: $_connectivityStatus\n'
              'Stream: $_connectivityStreamStatus',
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Photos permission'),
            subtitle: Text(_photosPermissionStatus),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _runChecks,
            child: const Text('Refresh'),
          ),
        ],
      ),
    );
  }
}
