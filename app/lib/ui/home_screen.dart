import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:universaldrop_app/clipboard_service.dart';
import 'package:universaldrop_app/crypto.dart';
import 'package:universaldrop_app/diagnostics_screen.dart';
import 'package:universaldrop_app/destination_preferences.dart';
import 'package:universaldrop_app/destination_rules.dart';
import 'package:universaldrop_app/destination_selector.dart';
import 'package:universaldrop_app/key_store.dart';
import 'package:universaldrop_app/packaging_builder.dart';
import 'package:universaldrop_app/save_service.dart';
import 'package:universaldrop_app/transfer/background_transfer.dart';
import 'package:universaldrop_app/transfer_coordinator.dart';
import 'package:universaldrop_app/transfer_manifest.dart';
import 'package:universaldrop_app/transfer_state_store.dart';
import 'package:universaldrop_app/transport.dart';
import 'package:universaldrop_app/trust_store.dart';
import 'package:universaldrop_app/trusted_device_badge.dart';
import 'package:universaldrop_app/zip_extract.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    ClipboardService? clipboardService,
    this.saveService,
    this.destinationStore,
    this.onTransportSelected,
    this.runStartupTasks = true,
  }) : clipboardService = clipboardService ?? const SystemClipboardService();

  final ClipboardService clipboardService;
  final SaveService? saveService;
  final DestinationPreferenceStore? destinationStore;
  final void Function(Transport transport)? onTransportSelected;
  final bool runStartupTasks;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _baseUrlController =
      TextEditingController(text: 'http://localhost:8080');
  String _status = 'Idle';
  bool _loading = false;
  bool _creatingSession = false;
  String _sessionStatus = 'No session created yet.';
  SessionCreateResponse? _sessionResponse;
  KeyPair? _receiverKeyPair;
  final Map<String, String> _senderPubKeysByClaim = {};
  final Map<String, String> _transferTokensByClaim = {};
  String _manifestStatus = 'No manifest downloaded.';
  final Map<String, TransferState> _transferStates = {};
  final List<TransferFile> _selectedFiles = [];
  TransferCoordinator? _coordinator;
  late final SecureTransferStateStore _transferStore =
      SecureTransferStateStore();
  final BackgroundTransferApi _backgroundTransfer = BackgroundTransferApiImpl();
  final DownloadTokenStore _downloadTokenStore = DownloadTokenStore();
  final SecureKeyPairStore _keyStore = SecureKeyPairStore();
  late final DestinationPreferenceStore _destinationStore;
  late final SaveService _saveService;
  late final DestinationSelector _destinationSelector;
  final TrustStore _trustStore = const TrustStore();
  final TextEditingController _textTitleController = TextEditingController();
  final TextEditingController _textContentController = TextEditingController();
  bool _sendTextMode = false;
  String _receivedText = '';
  String _saveStatus = '';
  String? _lastSavedPath;
  bool _lastSaveIsMedia = false;
  String? _lastSavedMime;
  String _packagingMode = packagingModeOriginals;
  final TextEditingController _packageTitleController = TextEditingController();
  Uint8List? _lastZipBytes;
  TransferManifest? _lastManifest;
  bool _extracting = false;
  ExtractProgress? _extractProgress;
  String _extractStatus = '';
  final TextEditingController _qrPayloadController = TextEditingController();
  final TextEditingController _sessionIdController = TextEditingController();
  final TextEditingController _claimTokenController = TextEditingController();
  final TextEditingController _senderLabelController =
      TextEditingController(text: 'Sender');
  bool _sending = false;
  String _sendStatus = 'Idle';
  String? _claimId;
  String? _claimStatus;
  String? _senderTransferToken;
  String? _senderReceiverPubKeyB64;
  String? _senderPubKeyB64;
  String? _senderSasCode;
  String _senderSasState = 'pending';
  bool _senderSasConfirmed = false;
  bool _senderSasConfirming = false;
  KeyPair? _senderKeyPair;
  String? _senderSessionId;
  String? _senderP2PToken;
  bool _scanRequired = false;
  String _scanStatus = '';
  Timer? _pollTimer;
  bool _refreshingClaims = false;
  String _claimsStatus = 'No pending claims.';
  List<PendingClaim> _pendingClaims = [];
  final Map<String, String> _p2pTokensByClaim = {};
  bool _preferDirect = true;
  bool _alwaysRelay = false;
  bool _p2pDisclosureShown = false;
  bool _experimentalDisclosureShown = false;
  bool _preferBackgroundDownloads = false;
  bool _showNotificationDetails = false;
  bool _isForeground = true;
  final Set<String> _trustedFingerprints = {};
  final Map<String, String> _receiverSasByClaim = {};
  final Set<String> _receiverSasConfirming = {};

  static const _p2pPreferDirectKey = 'p2pPreferDirect';
  static const _p2pAlwaysRelayKey = 'p2pAlwaysRelay';
  static const _p2pDisclosureKey = 'p2pDirectDisclosureShown';
  static const _experimentalDisclosureKey = 'experimentalDisclosureShown';
  static const _preferBackgroundDownloadsKey = 'preferBackgroundDownloads';
  static const _notificationDetailsKey =
      'showNotificationDetailsInNotifications';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _destinationStore =
        widget.destinationStore ?? SharedPreferencesDestinationStore();
    _saveService = widget.saveService ?? DefaultSaveService();
    _destinationSelector = DestinationSelector(_destinationStore);
    if (widget.runStartupTasks) {
      _loadSettings();
      _resumePendingTransfers();
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _qrPayloadController.dispose();
    _sessionIdController.dispose();
    _claimTokenController.dispose();
    _senderLabelController.dispose();
    _textTitleController.dispose();
    _textContentController.dispose();
    _packageTitleController.dispose();
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    if (isForeground == _isForeground) {
      return;
    }
    if (!mounted) {
      _isForeground = isForeground;
      return;
    }
    setState(() {
      _isForeground = isForeground;
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final preferDirect = prefs.getBool(_p2pPreferDirectKey) ?? true;
    final alwaysRelay = prefs.getBool(_p2pAlwaysRelayKey) ?? false;
    final disclosureShown = prefs.getBool(_p2pDisclosureKey) ?? false;
    final experimentalDisclosureShown =
        prefs.getBool(_experimentalDisclosureKey) ?? false;
    final preferBackgroundDownloads =
        prefs.getBool(_preferBackgroundDownloadsKey) ?? false;
    final showNotificationDetails =
        prefs.getBool(_notificationDetailsKey) ?? false;
    final trustedFingerprints = await _trustStore.loadFingerprints();
    if (!mounted) {
      return;
    }
    setState(() {
      _preferDirect = preferDirect;
      _alwaysRelay = alwaysRelay;
      _p2pDisclosureShown = disclosureShown;
      _experimentalDisclosureShown = experimentalDisclosureShown;
      _preferBackgroundDownloads = preferBackgroundDownloads;
      _showNotificationDetails = showNotificationDetails;
      _trustedFingerprints
        ..clear()
        ..addAll(trustedFingerprints);
    });
  }

  Future<void> _persistP2PSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_p2pPreferDirectKey, _preferDirect);
    await prefs.setBool(_p2pAlwaysRelayKey, _alwaysRelay);
  }

  Future<void> _setPreferDirect(bool value) async {
    if (value) {
      await _maybeShowDirectDisclosure();
    }
    setState(() {
      _preferDirect = value;
      if (!value) {
        _alwaysRelay = false;
      }
    });
    await _persistP2PSettings();
  }

  Future<void> _setAlwaysRelay(bool value) async {
    if (!_preferDirect) {
      return;
    }
    setState(() {
      _alwaysRelay = value;
    });
    await _persistP2PSettings();
  }

  Future<void> _setPreferBackgroundDownloads(bool value) async {
    if (value) {
      await _maybeShowExperimentalDisclosure();
    }
    setState(() {
      _preferBackgroundDownloads = value;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_preferBackgroundDownloadsKey, value);
  }

  Future<void> _setNotificationDetails(bool value) async {
    setState(() {
      _showNotificationDetails = value;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationDetailsKey, value);
  }

  Future<void> _maybeShowDirectDisclosure() async {
    if (_p2pDisclosureShown || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Direct transfer disclosure'),
          content: const Text(
            'Direct transfer may reveal IP address to the other device. '
            'Use "Always relay" to avoid direct exposure.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_p2pDisclosureKey, true);
    if (!mounted) {
      return;
    }
    setState(() {
      _p2pDisclosureShown = true;
    });
  }

  Future<void> _maybeShowExperimentalDisclosure() async {
    if (_experimentalDisclosureShown || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Experimental features'),
          content: const Text(
            'May not be available on all devices. If unavailable, '
            'CipherLink uses standard mode.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_experimentalDisclosureKey, true);
    if (!mounted) {
      return;
    }
    setState(() {
      _experimentalDisclosureShown = true;
    });
  }

  Future<void> _addTrustedFingerprint(String fingerprint) async {
    final updated = await _trustStore.addFingerprint(fingerprint);
    if (!mounted) {
      return;
    }
    setState(() {
      _trustedFingerprints
        ..clear()
        ..addAll(updated);
    });
  }

  Future<void> _removeTrustedFingerprint(String fingerprint) async {
    final updated = await _trustStore.removeFingerprint(fingerprint);
    if (!mounted) {
      return;
    }
    setState(() {
      _trustedFingerprints
        ..clear()
        ..addAll(updated);
    });
  }

  String _formatFingerprint(String fingerprint) {
    final trimmed = fingerprint.trim();
    if (trimmed.length <= 12) {
      return trimmed;
    }
    return '${trimmed.substring(0, 6)}...${trimmed.substring(trimmed.length - 4)}';
  }

  List<Widget> _buildTrustedDevicesSection() {
    final entries = _trustedFingerprints.toList()..sort();
    if (entries.isEmpty) {
      return const [
        Text(
          'Trusted devices',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 8),
        Text('No trusted devices yet.'),
      ];
    }
    return [
      const Text(
        'Trusted devices',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      ...entries.map((fingerprint) {
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_formatFingerprint(fingerprint)),
          trailing: IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              _removeTrustedFingerprint(fingerprint);
            },
          ),
        );
      }),
    ];
  }

  void _openDiagnostics() {
    final baseUrl = _baseUrlController.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DiagnosticsScreen(baseUrl: baseUrl),
      ),
    );
  }

  void _ensureCoordinator() {
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      return;
    }
    final baseUri = Uri.parse(baseUrl);
    final transport = HttpTransport(baseUri);
    widget.onTransportSelected?.call(transport);
    _coordinator = TransferCoordinator(
      transport: transport,
      baseUri: baseUri,
      p2pTransportFactory: (context) => P2PTransport(
        baseUri: baseUri,
        context: context,
        fallbackTransport: transport,
      ),
      store: _transferStore,
      onState: (state) {
        setState(() {
          _transferStates[state.transferId] = state;
        });
      },
      onScanStatus: (transferId, status) {
        setState(() {
          _scanStatus = status;
        });
      },
      backgroundTransfer: _backgroundTransfer,
      downloadTokenStore: _downloadTokenStore,
      saveHandler: _handleTransferSave,
      downloadResolver: _resolveDownloadResumeContext,
    );
  }

  TransferDownloadPolicy _downloadPolicy() {
    return TransferDownloadPolicy(
      preferBackground: _preferBackgroundDownloads,
      showNotificationDetails: _showNotificationDetails,
      destinationResolver: _resolveBackgroundDestination,
      isAppInForeground: () => _isForeground,
    );
  }

  Future<SaveDestination?> _resolveBackgroundDestination(
    TransferManifest manifest,
    bool allowPrompt,
  ) async {
    if (allowPrompt && mounted) {
      final defaultDestination =
          await _destinationSelector.defaultDestination(manifest);
      final choice = await _showDestinationSelector(
        defaultDestination,
        isMediaManifest(manifest),
      );
      if (choice == null) {
        return null;
      }
      await _destinationSelector.rememberChoice(manifest, choice);
      return choice.destination;
    }
    final prefs = await _destinationStore.load();
    if (isMediaManifest(manifest)) {
      return prefs.defaultMediaDestination ?? SaveDestination.files;
    }
    return prefs.defaultFileDestination ?? SaveDestination.files;
  }

  SaveDestination? _destinationFromState(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    for (final destination in SaveDestination.values) {
      if (destination.name == value) {
        return destination;
      }
    }
    return null;
  }

  Future<TransferSaveResult> _handleTransferSave(
    TransferManifest manifest,
    Uint8List bytes,
    TransferState state,
  ) async {
    final destination = _destinationFromState(state.destination) ??
        await _resolveBackgroundDestination(manifest, false) ??
        SaveDestination.files;

    if (manifest.payloadKind == payloadKindText) {
      final text = utf8.decode(bytes);
      if (mounted) {
        setState(() {
          _receivedText = text;
          _manifestStatus = 'Text received.';
          _saveStatus = 'Ready to copy.';
        });
      } else {
        _receivedText = text;
      }
      return const TransferSaveResult(shouldSendReceipt: true);
    }

    if (manifest.packagingMode == packagingModeAlbum) {
      final outcome = await _saveAlbumPayload(
        bytes: bytes,
        manifest: manifest,
        destination: destination,
        allowUserInteraction: false,
      );
      if (mounted) {
        setState(() {
          _manifestStatus =
              'Album: ${manifest.albumItemCount ?? manifest.files.length} items';
          _saveStatus =
              outcome.success ? 'Album saved.' : 'Album saved with fallback.';
        });
      }
      return TransferSaveResult(
        shouldSendReceipt: outcome.success || outcome.localPath != null,
        localPath: outcome.localPath,
      );
    }

    _lastManifest = manifest;
    _extractStatus = '';
    _extractProgress = null;
    if (manifest.packagingMode == packagingModeZip) {
      _lastZipBytes = bytes;
    } else {
      _lastZipBytes = null;
    }
    final fileName = _suggestFileName(manifest);
    final mime = _suggestMime(manifest);
    final isMedia = isMediaManifest(manifest);
    final outcome = await _saveService.saveBytes(
      bytes: bytes,
      name: fileName,
      mime: mime,
      isMedia: isMedia,
      destination: destination,
      allowUserInteraction: false,
    );
    _lastSavedPath = outcome.localPath;
    _lastSaveIsMedia = isMedia;
    _lastSavedMime = mime;
    if (mounted) {
      setState(() {
        if (manifest.packagingMode == packagingModeZip) {
          _manifestStatus = 'ZIP: ${manifest.outputFilename ?? fileName}';
        } else if (manifest.files.isNotEmpty) {
          _manifestStatus = 'File: ${manifest.files.first.relativePath}';
        } else {
          _manifestStatus = 'Downloaded ${bytes.length} bytes.';
        }
        _saveStatus = outcome.success ? 'Saved.' : 'Saved locally with fallback.';
      });
    }
    return TransferSaveResult(
      shouldSendReceipt: outcome.success || outcome.localPath != null,
      localPath: outcome.localPath,
    );
  }

  Future<void> _resumePendingTransfers() async {
    _ensureCoordinator();
    final coordinator = _coordinator;
    if (coordinator == null) {
      return;
    }
    await coordinator.resumePendingDownloads(
      resolve: _resolveDownloadResumeContext,
      downloadPolicy: _downloadPolicy(),
    );
    await coordinator.resumePendingUploads(
      resolve: _resolveUploadResumeContext,
    );
  }

  Future<DownloadResumeContext?> _resolveDownloadResumeContext(
    TransferState state,
  ) async {
    if (state.sessionId.isEmpty ||
        state.transferToken.isEmpty ||
        state.transferId.isEmpty) {
      return null;
    }
    final senderPubKeyB64 = state.peerPublicKeyB64 ?? '';
    if (senderPubKeyB64.isEmpty) {
      return null;
    }
    final receiverKeyPair = await _keyStore.loadKeyPair(
      sessionId: state.sessionId,
      role: KeyRole.receiver,
    );
    if (receiverKeyPair == null) {
      return null;
    }
    return DownloadResumeContext(
      sessionId: state.sessionId,
      transferToken: state.transferToken,
      transferId: state.transferId,
      senderPublicKey: publicKeyFromBase64(senderPubKeyB64),
      receiverKeyPair: receiverKeyPair,
    );
  }

  Future<UploadResumeContext?> _resolveUploadResumeContext(
    TransferState state,
  ) async {
    if (state.sessionId.isEmpty ||
        state.transferToken.isEmpty ||
        state.transferId.isEmpty) {
      return null;
    }
    final payloadPath = state.payloadPath ?? '';
    if (payloadPath.isEmpty) {
      return null;
    }
    final payloadFile = File(payloadPath);
    if (!await payloadFile.exists()) {
      return null;
    }
    final senderKeyPair = await _keyStore.loadKeyPair(
      sessionId: state.sessionId,
      role: KeyRole.sender,
    );
    if (senderKeyPair == null) {
      return null;
    }
    final receiverPubKeyB64 = state.peerPublicKeyB64 ?? '';
    if (receiverPubKeyB64.isEmpty) {
      return null;
    }
    final bytes = await payloadFile.readAsBytes();
    final transferFile = TransferFile(
      id: state.transferId,
      name: p.basename(payloadPath),
      bytes: bytes,
      payloadKind: payloadKindFile,
      mimeType: 'application/octet-stream',
      packagingMode: packagingModeOriginals,
      localPath: payloadPath,
    );
    return UploadResumeContext(
      file: transferFile,
      sessionId: state.sessionId,
      transferToken: state.transferToken,
      receiverPublicKey: publicKeyFromBase64(receiverPubKeyB64),
      senderKeyPair: senderKeyPair,
      chunkSize: state.chunkSize,
      scanRequired: state.scanRequired ?? false,
      transferId: state.transferId,
    );
  }

  P2PContext? _buildP2PContext({
    required String sessionId,
    required String claimId,
    required String token,
    required bool isInitiator,
  }) {
    if (!_preferDirect) {
      return null;
    }
    if (sessionId.isEmpty || claimId.isEmpty || token.isEmpty) {
      return null;
    }
    return P2PContext(
      sessionId: sessionId,
      claimId: claimId,
      token: token,
      isInitiator: isInitiator,
      iceMode: _alwaysRelay ? P2PIceMode.relay : P2PIceMode.direct,
    );
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

    if (_preferDirect) {
      await _maybeShowDirectDisclosure();
    }
    final p2pToken = _p2pTokensByClaim[claim.claimId] ?? transferToken;
    final p2pContext = _buildP2PContext(
      sessionId: sessionId,
      claimId: claim.claimId,
      token: p2pToken,
      isInitiator: false,
    );

    setState(() {
      _manifestStatus = 'Downloading manifest...';
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
      final keyPair = await X25519().newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final receiverPubKeyB64 = publicKeyToBase64(publicKey);

      final baseUri = Uri.parse(baseUrl);
      final response = await http
          .post(
            baseUri.resolve('/v1/session/create'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'receiver_pubkey_b64': receiverPubKeyB64}),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        setState(() {
          _sessionStatus = 'Error: ${response.statusCode}';
        });
        return;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final sessionResponse = SessionCreateResponse.fromJson(payload);
      final stored = await _keyStore.trySaveKeyPair(
        sessionId: sessionResponse.sessionId,
        role: KeyRole.receiver,
        keyPair: keyPair,
      );
      if (!stored) {
        setState(() {
          _sessionStatus =
              'Secure storage unavailable. Cannot persist session keys.';
        });
        return;
      }
      setState(() {
        _sessionResponse = sessionResponse;
        _sessionStatus = 'Session created.';
        _claimsStatus = 'Session created. Refresh to load claims.';
        _pendingClaims = [];
        _receiverSasByClaim.clear();
        _receiverSasConfirming.clear();
        _receiverKeyPair = keyPair;
        _receivedText = '';
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
        _claimsStatus =
            claims.isEmpty ? 'No pending claims.' : 'Pending claims loaded.';
      });
      await _updateReceiverSasCodes(claims);
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

  Future<void> _updateReceiverSasCodes(List<PendingClaim> claims) async {
    final receiverPubKeyB64 = _sessionResponse?.receiverPubKeyB64 ?? '';
    final sessionId = _sessionResponse?.sessionId ?? '';
    if (receiverPubKeyB64.isEmpty || sessionId.isEmpty) {
      return;
    }
    final updates = <String, String>{};
    for (final claim in claims) {
      if (claim.senderPubKeyB64.isEmpty) {
        continue;
      }
      if (_receiverSasByClaim.containsKey(claim.claimId)) {
        continue;
      }
      final sas = await deriveSasDigits(
        sessionId: sessionId,
        claimId: claim.claimId,
        receiverPubKeyB64: receiverPubKeyB64,
        senderPubKeyB64: claim.senderPubKeyB64,
      );
      updates[claim.claimId] = sas;
    }
    if (updates.isEmpty || !mounted) {
      return;
    }
    setState(() {
      _receiverSasByClaim.addAll(updates);
    });
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

    var scanRequired = false;
    if (approve) {
      final choice = await _promptScanChoice();
      if (choice == null) {
        return;
      }
      scanRequired = choice;
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
              if (approve) 'scan_required': scanRequired,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        final payload = jsonDecode(response.body) as Map<String, dynamic>?;
        final error = payload?['error']?.toString();
        setState(() {
          _claimsStatus = error == 'sas_required'
              ? 'SAS must be verified by both devices.'
              : 'Error: ${response.statusCode}';
        });
        return;
      }

      if (approve) {
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        final transferToken = payload['transfer_token']?.toString() ?? '';
        final p2pToken = payload['p2p_token']?.toString() ?? '';
        final senderPubKey = payload['sender_pubkey_b64']?.toString() ?? '';
        if (transferToken.isNotEmpty) {
          _transferTokensByClaim[claim.claimId] = transferToken;
        }
        if (p2pToken.isNotEmpty) {
          _p2pTokensByClaim[claim.claimId] = p2pToken;
        }
        if (senderPubKey.isNotEmpty) {
          _senderPubKeysByClaim[claim.claimId] = senderPubKey;
        }
        await _addTrustedFingerprint(claim.shortFingerprint);
      }
      await _refreshClaims();
    } catch (err) {
      setState(() {
        _claimsStatus = 'Failed: $err';
      });
    }
  }

  Future<bool> _commitSas({
    required String sessionId,
    required String claimId,
    required String role,
  }) async {
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      return false;
    }
    final response = await http
        .post(
          Uri.parse(baseUrl).resolve('/v1/session/sas/commit'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'session_id': sessionId,
            'claim_id': claimId,
            'role': role,
            'sas_confirmed': true,
          }),
        )
        .timeout(const Duration(seconds: 8));
    return response.statusCode == 200;
  }

  Future<void> _confirmReceiverSas(PendingClaim claim) async {
    final sessionId = _sessionResponse?.sessionId ?? '';
    if (sessionId.isEmpty) {
      setState(() {
        _claimsStatus = 'Create a session first.';
      });
      return;
    }
    if (_receiverSasConfirming.contains(claim.claimId)) {
      return;
    }
    setState(() {
      _receiverSasConfirming.add(claim.claimId);
      _claimsStatus = 'Confirming SAS...';
    });
    try {
      final ok = await _commitSas(
        sessionId: sessionId,
        claimId: claim.claimId,
        role: 'receiver',
      );
      if (!ok) {
        setState(() {
          _claimsStatus = 'Failed to confirm SAS.';
        });
        return;
      }
      await _refreshClaims();
      setState(() {
        _claimsStatus = 'SAS confirmed.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _receiverSasConfirming.remove(claim.claimId);
        });
      }
    }
  }

  Future<void> _confirmSenderSas() async {
    final sessionId = _senderSessionId ?? '';
    final claimId = _claimId ?? '';
    if (sessionId.isEmpty || claimId.isEmpty) {
      setState(() {
        _sendStatus = 'Claim a session first.';
      });
      return;
    }
    if (_senderSasConfirming) {
      return;
    }
    setState(() {
      _senderSasConfirming = true;
      _sendStatus = 'Confirming SAS...';
    });
    try {
      final ok = await _commitSas(
        sessionId: sessionId,
        claimId: claimId,
        role: 'sender',
      );
      if (!ok) {
        setState(() {
          _sendStatus = 'Failed to confirm SAS.';
        });
        return;
      }
      setState(() {
        _senderSasConfirmed = true;
        _sendStatus = 'SAS confirmed. Awaiting approval...';
      });
    } finally {
      if (mounted) {
        setState(() {
          _senderSasConfirming = false;
        });
      }
    }
  }

  Future<void> _updateSenderSasCode() async {
    if (_senderSasCode != null) {
      return;
    }
    final sessionId = _senderSessionId ?? '';
    final claimId = _claimId ?? '';
    final receiverPubKeyB64 = _senderReceiverPubKeyB64 ?? '';
    final senderPubKeyB64 = _senderPubKeyB64 ?? '';
    if (sessionId.isEmpty ||
        claimId.isEmpty ||
        receiverPubKeyB64.isEmpty ||
        senderPubKeyB64.isEmpty) {
      return;
    }
    final sas = await deriveSasDigits(
      sessionId: sessionId,
      claimId: claimId,
      receiverPubKeyB64: receiverPubKeyB64,
      senderPubKeyB64: senderPubKeyB64,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _senderSasCode = sas;
    });
  }

  Future<bool?> _promptScanChoice() {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        bool scanRequired = false;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Trust decision'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<bool>(
                    value: false,
                    groupValue: scanRequired,
                    onChanged: (value) {
                      setState(() {
                        scanRequired = value ?? false;
                      });
                    },
                    title: const Text('Trust (no scan)'),
                  ),
                  RadioListTile<bool>(
                    value: true,
                    groupValue: scanRequired,
                    onChanged: (value) {
                      setState(() {
                        scanRequired = value ?? false;
                      });
                    },
                    title: const Text('Don’t trust but accept w/ scan'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(scanRequired),
                  child: const Text('Continue'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _downloadManifest(PendingClaim claim) async {
    final baseUrl = _baseUrlController.text.trim();
    final sessionId = _sessionResponse?.sessionId ?? '';
    final transferToken = _transferTokensByClaim[claim.claimId] ?? '';
    final senderPubKeyB64 = _senderPubKeysByClaim[claim.claimId] ?? '';
    if (baseUrl.isEmpty || sessionId.isEmpty) {
      setState(() {
        _manifestStatus = 'Create a session first.';
      });
      return;
    }
    if (claim.transferId.isEmpty) {
      setState(() {
        _manifestStatus = 'No transfer ID yet.';
      });
      return;
    }
    if (transferToken.isEmpty ||
        senderPubKeyB64.isEmpty ||
        _receiverKeyPair == null) {
      setState(() {
        _manifestStatus = 'Missing auth context or keys.';
      });
      return;
    }

    if (_preferDirect) {
      await _maybeShowDirectDisclosure();
    }
    final p2pToken = _p2pTokensByClaim[claim.claimId] ?? transferToken;
    final p2pContext = _buildP2PContext(
      sessionId: sessionId,
      claimId: claim.claimId,
      token: p2pToken,
      isInitiator: false,
    );

    setState(() {
      _manifestStatus = 'Downloading manifest...';
    });

    try {
      _ensureCoordinator();
      final coordinator = _coordinator;
      if (coordinator == null) {
        setState(() {
          _manifestStatus = 'Invalid base URL.';
        });
        return;
      }
      final senderPublicKey = publicKeyFromBase64(senderPubKeyB64);
      final result = await coordinator.downloadTransfer(
        sessionId: sessionId,
        transferToken: transferToken,
        transferId: claim.transferId,
        senderPublicKey: senderPublicKey,
        receiverKeyPair: _receiverKeyPair!,
        sendReceipt: false,
        p2pContext: p2pContext,
        downloadPolicy: _downloadPolicy(),
      );
      if (result == null) {
        final pending = await _transferStore.load(claim.transferId);
        if (!mounted) {
          return;
        }
        setState(() {
          if (pending?.backgroundTaskId?.isNotEmpty == true) {
            _manifestStatus = 'Download running in background.';
          } else if (pending?.requiresForegroundResume == true) {
            _manifestStatus = 'Download paused. Resume in foreground.';
          } else {
            _manifestStatus = 'Download paused or failed.';
          }
        });
        return;
      }
      final manifest = result.manifest;
      _lastManifest = manifest;
      _extractStatus = '';
      _extractProgress = null;
      if (manifest.packagingMode != packagingModeZip) {
        _lastZipBytes = null;
      }
      if (manifest.payloadKind == payloadKindText) {
        final text = utf8.decode(result.bytes);
        setState(() {
          _receivedText = text;
          _manifestStatus = 'Text received.';
          _saveStatus = 'Ready to copy.';
        });
        await coordinator.sendReceipt(
          sessionId: sessionId,
          transferId: result.transferId,
          transferToken: transferToken,
        );
        return;
      }

      final defaultDestination =
          await _destinationSelector.defaultDestination(manifest);
      final choice = await _showDestinationSelector(
        defaultDestination,
        isMediaManifest(manifest),
      );
      if (choice == null) {
        setState(() {
          _manifestStatus = 'Save cancelled.';
        });
        return;
      }
      await _destinationSelector.rememberChoice(manifest, choice);

      if (manifest.packagingMode == packagingModeAlbum) {
        final outcome = await _saveAlbumPayload(
          bytes: result.bytes,
          manifest: manifest,
          destination: choice.destination,
        );
        setState(() {
          _manifestStatus =
              'Album: ${manifest.albumItemCount ?? manifest.files.length} items';
          _saveStatus =
              outcome.success ? 'Album saved.' : 'Album saved with fallback.';
        });
        if (outcome.success || outcome.localPath != null) {
          await coordinator.sendReceipt(
            sessionId: sessionId,
            transferId: result.transferId,
            transferToken: transferToken,
          );
        }
        return;
      }

      if (manifest.packagingMode == packagingModeZip) {
        _lastZipBytes = result.bytes;
      }
      final fileName = _suggestFileName(manifest);
      final mime = _suggestMime(manifest);
      final isMedia = isMediaManifest(manifest);
      final outcome = await _saveService.saveBytes(
        bytes: result.bytes,
        name: fileName,
        mime: mime,
        isMedia: isMedia,
        destination: choice.destination,
      );
      _lastSavedPath = outcome.localPath;
      _lastSaveIsMedia = isMedia;
      _lastSavedMime = mime;
      setState(() {
        if (manifest.packagingMode == packagingModeZip) {
          _manifestStatus = 'ZIP: ${manifest.outputFilename ?? fileName}';
        } else if (manifest.files.isNotEmpty) {
          _manifestStatus = 'File: ${manifest.files.first.relativePath}';
        } else {
          _manifestStatus = 'Downloaded ${result.bytes.length} bytes.';
        }
        _saveStatus = outcome.success ? 'Saved.' : 'Saved locally with fallback.';
      });

      if (outcome.success || outcome.localPath != null) {
        await coordinator.sendReceipt(
          sessionId: sessionId,
          transferId: result.transferId,
          transferToken: transferToken,
        );
      }
    } catch (err) {
      setState(() {
        _manifestStatus = 'Manifest error: $err';
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

      final stored = await _keyStore.trySaveKeyPair(
        sessionId: sessionId,
        role: KeyRole.sender,
        keyPair: keyPair,
      );
      if (!stored) {
        setState(() {
          _sendStatus = 'Secure storage unavailable. Cannot continue.';
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
        _senderKeyPair = keyPair;
        _senderPubKeyB64 = pubKeyB64;
        _senderSessionId = sessionId;
        _senderReceiverPubKeyB64 = null;
        _senderTransferToken = null;
        _senderP2PToken = null;
        _senderSasCode = null;
        _senderSasState = 'pending';
        _senderSasConfirmed = false;
        _senderSasConfirming = false;
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

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) {
      return;
    }
    final files = <TransferFile>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) {
        continue;
      }
      final id = _randomId();
      final localPath = await _cacheUploadPayload(id, bytes);
      final mimeType = lookupMimeType(file.name, headerBytes: bytes) ??
          'application/octet-stream';
      files.add(
        TransferFile(
          id: id,
          name: file.name,
          bytes: bytes,
          payloadKind: payloadKindFile,
          mimeType: mimeType,
          packagingMode: packagingModeOriginals,
          localPath: localPath,
        ),
      );
    }
    if (files.isEmpty) {
      setState(() {
        _sendStatus = 'No files loaded.';
      });
      return;
    }
    setState(() {
      _selectedFiles
        ..clear()
        ..addAll(files);
    });
  }

  Future<void> _pickMedia() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.media,
    );
    if (result == null) {
      return;
    }
    final files = <TransferFile>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) {
        continue;
      }
      final id = _randomId();
      final localPath = await _cacheUploadPayload(id, bytes);
      final name = file.name.isNotEmpty ? file.name : 'media';
      final mimeType = lookupMimeType(name, headerBytes: bytes) ??
          'application/octet-stream';
      files.add(
        TransferFile(
          id: id,
          name: name,
          bytes: bytes,
          payloadKind: payloadKindFile,
          mimeType: mimeType,
          packagingMode: packagingModeOriginals,
          localPath: localPath,
        ),
      );
    }
    if (files.isEmpty) {
      setState(() {
        _sendStatus = 'No media loaded.';
      });
      return;
    }
    setState(() {
      _selectedFiles
        ..clear()
        ..addAll(files);
    });
  }

  Future<String?> _cacheUploadPayload(String id, Uint8List bytes) async {
    final dir = await getApplicationSupportDirectory();
    final uploadDir = Directory(p.join(dir.path, 'upload_cache'));
    await uploadDir.create(recursive: true);
    final path = p.join(uploadDir.path, id);
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<void> _startQueue() async {
    if (_senderTransferToken == null ||
        _senderReceiverPubKeyB64 == null ||
        _senderKeyPair == null ||
        _senderSessionId == null) {
      setState(() {
        _sendStatus = 'Claim and wait for approval first.';
      });
      return;
    }
    if (_selectedFiles.isEmpty) {
      setState(() {
        _sendStatus = 'Select files first.';
      });
      return;
    }
    if (_preferDirect) {
      await _maybeShowDirectDisclosure();
    }
    _ensureCoordinator();
    final coordinator = _coordinator;
    if (coordinator == null) {
      setState(() {
        _sendStatus = 'Invalid base URL.';
      });
      return;
    }
    final p2pToken = _senderP2PToken ?? _senderTransferToken ?? '';
    final p2pContext = _buildP2PContext(
      sessionId: _senderSessionId!,
      claimId: _claimId ?? '',
      token: p2pToken,
      isInitiator: true,
    );
    if (_packagingMode == packagingModeOriginals) {
      coordinator.enqueueUploads(
        files: _selectedFiles,
        sessionId: _senderSessionId!,
        transferToken: _senderTransferToken!,
        receiverPublicKey: publicKeyFromBase64(_senderReceiverPubKeyB64!),
        senderKeyPair: _senderKeyPair!,
        chunkSize: 64 * 1024,
        scanRequired: _scanRequired,
        p2pContext: p2pContext,
      );
      setState(() {
        _sendStatus = 'Queue started.';
      });
      await coordinator.runQueue();
      return;
    }

    final packageTitle = _packageTitleController.text.trim().isEmpty
        ? _defaultPackageTitle()
        : _packageTitleController.text.trim();
    try {
      final package = buildZipPackage(
        files: _selectedFiles,
        packageTitle: packageTitle,
        albumMode: _packagingMode == packagingModeAlbum,
      );
      final payloadKind = _packagingMode == packagingModeAlbum
          ? payloadKindAlbum
          : payloadKindZip;
      final id = _randomId();
      final localPath = await _cacheUploadPayload(id, package.bytes);
      final transferFile = TransferFile(
        id: id,
        name: package.outputName,
        bytes: package.bytes,
        payloadKind: payloadKind,
        mimeType: 'application/zip',
        packagingMode: _packagingMode,
        packageTitle: packageTitle,
        entries: package.entries,
        localPath: localPath,
      );
      coordinator.enqueueUploads(
        files: [transferFile],
        sessionId: _senderSessionId!,
        transferToken: _senderTransferToken!,
        receiverPublicKey: publicKeyFromBase64(_senderReceiverPubKeyB64!),
        senderKeyPair: _senderKeyPair!,
        chunkSize: 64 * 1024,
        scanRequired: _scanRequired,
        p2pContext: p2pContext,
      );
      setState(() {
        _sendStatus = 'Package queued.';
        _selectedFiles.clear();
      });
      await coordinator.runQueue();
    } catch (err) {
      setState(() {
        _sendStatus = 'Packaging failed: $err';
      });
    }
  }

  void _pauseQueue() {
    _coordinator?.pause();
    setState(() {
      _sendStatus = 'Paused.';
    });
  }

  Future<void> _resumeQueue() async {
    await _coordinator?.resume();
    setState(() {
      _sendStatus = 'Resumed.';
    });
  }

  Future<void> _sendText() async {
    final text = _textContentController.text;
    if (text.trim().isEmpty) {
      setState(() {
        _sendStatus = 'Enter text first.';
      });
      return;
    }
    if (_senderTransferToken == null ||
        _senderReceiverPubKeyB64 == null ||
        _senderKeyPair == null ||
        _senderSessionId == null) {
      setState(() {
        _sendStatus = 'Claim and wait for approval first.';
      });
      return;
    }
    if (_preferDirect) {
      await _maybeShowDirectDisclosure();
    }

    _ensureCoordinator();
    final coordinator = _coordinator;
    if (coordinator == null) {
      setState(() {
        _sendStatus = 'Invalid base URL.';
      });
      return;
    }

    final textBytes = Uint8List.fromList(utf8.encode(text));
    final id = _randomId();
    final localPath = await _cacheUploadPayload(id, textBytes);
    final payload = TransferFile(
      id: id,
      name: _textTitleController.text.trim().isEmpty
          ? 'Text'
          : _textTitleController.text.trim(),
      bytes: textBytes,
      payloadKind: payloadKindText,
      mimeType: textMimePlain,
      packagingMode: packagingModeOriginals,
      textTitle: _textTitleController.text.trim().isEmpty
          ? null
          : _textTitleController.text.trim(),
      localPath: localPath,
    );
    final p2pToken = _senderP2PToken ?? _senderTransferToken ?? '';
    final p2pContext = _buildP2PContext(
      sessionId: _senderSessionId!,
      claimId: _claimId ?? '',
      token: p2pToken,
      isInitiator: true,
    );

    coordinator.enqueueUploads(
      files: [payload],
      sessionId: _senderSessionId!,
      transferToken: _senderTransferToken!,
      receiverPublicKey: publicKeyFromBase64(_senderReceiverPubKeyB64!),
      senderKeyPair: _senderKeyPair!,
      chunkSize: 16 * 1024,
      scanRequired: _scanRequired,
      p2pContext: p2pContext,
    );
    setState(() {
      _sendStatus = 'Sending text...';
      _selectedFiles.clear();
    });
    await coordinator.runQueue();
  }

  Future<void> _pasteFromClipboard() async {
    final text = await widget.clipboardService.readText();
    if (text == null || text.isEmpty) {
      setState(() {
        _sendStatus = 'Clipboard empty.';
      });
      return;
    }
    setState(() {
      _textContentController.text = text;
    });
  }

  Future<DestinationChoice?> _showDestinationSelector(
    SaveDestination defaultDestination,
    bool isMedia,
  ) async {
    SaveDestination selected =
        isMedia ? defaultDestination : SaveDestination.files;
    bool remember = false;
    return showDialog<DestinationChoice>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Choose destination'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<SaveDestination>(
                    value: SaveDestination.photos,
                    groupValue: selected,
                    onChanged: isMedia
                        ? (value) {
                            if (value == null) return;
                            setState(() {
                              selected = value;
                            });
                          }
                        : null,
                    title: const Text('Save to Photos/Gallery'),
                  ),
                  RadioListTile<SaveDestination>(
                    value: SaveDestination.files,
                    groupValue: selected,
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        selected = value;
                      });
                    },
                    title: const Text('Save to Files'),
                  ),
                  Row(
                    children: [
                      Checkbox(
                        value: remember,
                        onChanged: (value) {
                          setState(() {
                            remember = value ?? false;
                          });
                        },
                      ),
                      const Text('Remember my choice'),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop(
                      DestinationChoice(
                        destination: selected,
                        remember: remember,
                      ),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<SaveOutcome> _saveAlbumPayload({
    required Uint8List bytes,
    required TransferManifest manifest,
    required SaveDestination destination,
    bool allowUserInteraction = true,
  }) async {
    final entries = decodeZipEntries(bytes);
    final fileMap = <String, TransferManifestFile>{};
    for (final entry in manifest.files) {
      fileMap[entry.relativePath] = entry;
    }

    SaveOutcome lastOutcome = SaveOutcome(
      success: false,
      usedFallback: false,
      savedToGallery: false,
    );
    for (final entry in entries) {
      if (!entry.isFile) {
        continue;
      }
      final name = entry.name;
      if (!name.startsWith('media/')) {
        continue;
      }
      final relativePath = name.substring('media/'.length);
      final metadata = fileMap[relativePath];
      final mime =
          metadata?.mime ?? lookupMimeType(relativePath) ?? 'application/octet-stream';
      final outcome = await _saveService.saveBytes(
        bytes: entry.bytes,
        name: relativePath,
        mime: mime,
        isMedia: true,
        destination: destination,
        allowUserInteraction: allowUserInteraction,
      );
      if (_lastSavedPath == null && outcome.localPath != null) {
        _lastSavedPath = outcome.localPath;
        _lastSaveIsMedia = true;
        _lastSavedMime = mime;
      }
      lastOutcome = outcome;
      if (!outcome.success && outcome.localPath == null) {
        return outcome;
      }
    }
    return lastOutcome;
  }

  Future<void> _extractZip() async {
    final zipBytes = _lastZipBytes;
    final manifest = _lastManifest;
    if (zipBytes == null || manifest == null) {
      return;
    }
    setState(() {
      _extracting = true;
      _extractStatus = 'Extracting...';
    });

    try {
      final destination = await getDirectoryPath();
      String destPath;
      if (destination == null) {
        final dir = await getApplicationDocumentsDirectory();
        destPath = p.join(dir.path, _defaultPackageTitle());
      } else {
        destPath = destination;
      }
      final result = await extractZipBytes(
        bytes: zipBytes,
        destinationDir: destPath,
        onProgress: (progress) {
          setState(() {
            _extractProgress = progress;
          });
        },
      );
      setState(() {
        _extractStatus = 'Extracted ${result.filesExtracted} files.';
      });
    } catch (err) {
      setState(() {
        if (err is ZipLimitException) {
          _extractStatus = err.message;
        } else {
          _extractStatus = 'Extraction failed.';
        }
      });
    } finally {
      setState(() {
        _extracting = false;
      });
    }
  }

  String _defaultPackageTitle() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return 'Package_${now.year}$month$day_$hour$minute';
  }

  String _suggestFileName(TransferManifest manifest) {
    if (manifest.packagingMode == packagingModeZip &&
        manifest.outputFilename != null &&
        manifest.outputFilename!.isNotEmpty) {
      return manifest.outputFilename!;
    }
    if (manifest.payloadKind == payloadKindText) {
      final title = manifest.textTitle?.trim();
      if (title != null && title.isNotEmpty) {
        return '$title.txt';
      }
      return 'text.txt';
    }
    if (manifest.files.isNotEmpty) {
      return manifest.files.first.relativePath;
    }
    return 'transfer.bin';
  }

  String _suggestMime(TransferManifest manifest) {
    if (manifest.payloadKind == payloadKindText) {
      return manifest.textMime ?? textMimePlain;
    }
    if (manifest.packagingMode == packagingModeZip) {
      return 'application/zip';
    }
    if (manifest.files.isNotEmpty) {
      return manifest.files.first.mime ?? 'application/octet-stream';
    }
    return 'application/octet-stream';
  }

  String _suggestedExportName() {
    if (_lastSavedPath == null) {
      return 'export.bin';
    }
    return _lastSavedPath!.split(Platform.pathSeparator).last;
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
      final transferToken = payload['transfer_token']?.toString();
      final p2pToken = payload['p2p_token']?.toString();
      final receiverPubKey = payload['receiver_pubkey_b64']?.toString();
      final scanRequired = payload['scan_required'] == true;
      final scanStatus = payload['scan_status']?.toString() ?? '';
      final sasState = payload['sas_state']?.toString() ?? 'pending';
      setState(() {
        _claimStatus = status;
        _sendStatus = 'Status: $status';
        if (receiverPubKey != null && receiverPubKey.isNotEmpty) {
          _senderReceiverPubKeyB64 = receiverPubKey;
        }
        if (transferToken != null && transferToken.isNotEmpty) {
          _senderTransferToken = transferToken;
        }
        if (p2pToken != null && p2pToken.isNotEmpty) {
          _senderP2PToken = p2pToken;
        }
        _scanRequired = scanRequired;
        _scanStatus = scanStatus;
        _senderSasState = sasState;
        if (sasState == 'sender_confirmed' || sasState == 'verified') {
          _senderSasConfirmed = true;
        }
      });
      await _updateSenderSasCode();

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
            const Text(
              'P2P settings',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Prefer direct'),
              subtitle: const Text('Use WebRTC when available'),
              value: _preferDirect,
              onChanged: (value) => _setPreferDirect(value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Always relay'),
              subtitle: const Text('Force TURN relay (no direct IP exposure)'),
              value: _alwaysRelay,
              onChanged: _preferDirect ? (value) => _setAlwaysRelay(value) : null,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _loading ? null : _pingBackend,
                  child: Text(_loading ? 'Pinging...' : 'Ping Backend'),
                ),
                OutlinedButton(
                  onPressed: _openDiagnostics,
                  child: const Text('Diagnostics'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Status: $_status'),
            const SizedBox(height: 24),
            const Text(
              'Download settings',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Prefer background downloads'),
              subtitle:
                  const Text('Use background downloads for large transfers'),
              value: _preferBackgroundDownloads,
              onChanged: (value) => _setPreferBackgroundDownloads(value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show more details in notifications'),
              subtitle: const Text('May include transfer details'),
              value: _showNotificationDetails,
              onChanged: (value) => _setNotificationDetails(value),
            ),
            const SizedBox(height: 16),
            ..._buildTrustedDevicesSection(),
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
                child:
                    Text(_refreshingClaims ? 'Refreshing...' : 'Refresh Claims'),
              ),
              const SizedBox(height: 8),
              Text(_claimsStatus),
              const SizedBox(height: 8),
              ..._pendingClaims.map((claim) {
                final sasCode = _receiverSasByClaim[claim.claimId] ?? '';
                final sasState = claim.sasState;
                final receiverConfirmed =
                    sasState == 'receiver_confirmed' || sasState == 'verified';
                final sasVerified = sasState == 'verified';
                final sasConfirming =
                    _receiverSasConfirming.contains(claim.claimId);
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
                        if (claim.transferId.isNotEmpty)
                          Text('Transfer ID: ${claim.transferId}'),
                        if (claim.scanRequired)
                          Text(
                            'Scan status: ${claim.scanStatus.isEmpty ? 'pending' : claim.scanStatus}',
                          ),
                        if (sasCode.isNotEmpty) Text('SAS: $sasCode'),
                        Text(
                          'SAS state: ${sasState.isEmpty ? 'pending' : sasState}',
                        ),
                        const SizedBox(height: 4),
                        ElevatedButton(
                          onPressed: sasCode.isEmpty ||
                                  receiverConfirmed ||
                                  sasConfirming
                              ? null
                              : () => _confirmReceiverSas(claim),
                          child: Text(
                            sasConfirming
                                ? 'Confirming...'
                                : receiverConfirmed
                                    ? 'SAS confirmed'
                                    : 'Confirm SAS',
                          ),
                        ),
                        TrustedDeviceBadge.forFingerprint(
                          fingerprint: claim.shortFingerprint,
                          trustedFingerprints: _trustedFingerprints,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            ElevatedButton(
                              onPressed: sasVerified
                                  ? () => _respondToClaim(claim, true)
                                  : null,
                              child: const Text('Approve'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: () => _respondToClaim(claim, false),
                              child: const Text('Reject'),
                            ),
                            if (claim.transferId.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: () => _downloadManifest(claim),
                                child: const Text('Fetch Manifest'),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
              if (_pendingClaims.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(_manifestStatus),
              ],
            ],
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              'Send Session',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('Send Files'),
                  selected: !_sendTextMode,
                  onSelected: (value) {
                    setState(() {
                      _sendTextMode = !value;
                    });
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Send Text'),
                  selected: _sendTextMode,
                  onSelected: (value) {
                    setState(() {
                      _sendTextMode = value;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_sendTextMode) ...[
              TextField(
                controller: _textTitleController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Title (optional)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _textContentController,
                maxLines: 4,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Text to send',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton(
                    onPressed: _pasteFromClipboard,
                    child: const Text('Paste from Clipboard'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed:
                        _senderTransferToken == null || !_senderSasConfirmed
                            ? null
                            : _sendText,
                    child: const Text('Send Text'),
                  ),
                ],
              ),
            ],
            if (!_sendTextMode) ...[
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
            if (_scanRequired)
              Text(
                  'Scan required (${_scanStatus.isEmpty ? 'pending' : _scanStatus})'),
            if (_claimId != null) ...[
              Text('SAS: ${_senderSasCode ?? 'waiting for keys'}'),
              Text('SAS state: $_senderSasState'),
              const SizedBox(height: 4),
              ElevatedButton(
                onPressed: _senderSasCode == null ||
                        _senderSasConfirmed ||
                        _senderSasConfirming
                    ? null
                    : _confirmSenderSas,
                child: Text(
                  _senderSasConfirming
                      ? 'Confirming...'
                      : _senderSasConfirmed
                          ? 'SAS confirmed'
                          : 'Confirm SAS',
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                DropdownButton<String>(
                  value: _packagingMode,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _packagingMode = value;
                      if (_packagingMode != packagingModeOriginals &&
                          _packageTitleController.text.trim().isEmpty) {
                        _packageTitleController.text = _defaultPackageTitle();
                      }
                    });
                  },
                  items: const [
                    DropdownMenuItem(
                      value: packagingModeOriginals,
                      child: Text('Originals'),
                    ),
                    DropdownMenuItem(
                      value: packagingModeZip,
                      child: Text('ZIP'),
                    ),
                    DropdownMenuItem(
                      value: packagingModeAlbum,
                      child: Text('Album'),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _pickFiles,
                  child: const Text('Select Files'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _pickMedia,
                  child: const Text('Select Photos'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _senderTransferToken == null || !_senderSasConfirmed
                      ? null
                      : _startQueue,
                  child: const Text('Start Queue'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _coordinator?.isRunning == true ? _pauseQueue : null,
                  child: const Text('Pause'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed:
                      _coordinator?.isPaused == true ? _resumeQueue : null,
                  child: const Text('Resume'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_selectedFiles.isNotEmpty) ...[
              if (_packagingMode != packagingModeOriginals) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _packageTitleController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Package title',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const Text('Queue'),
              const SizedBox(height: 8),
              ..._selectedFiles.map((file) {
                final state = _transferStates[file.id];
                final status = state?.status ?? statusQueued;
                final progress = state == null || state.totalBytes == 0
                    ? 0.0
                    : _progressForState(state);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(file.name)),
                      Text(status),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 120,
                        child: LinearProgressIndicator(value: progress),
                      ),
                    ],
                  ),
                );
              }),
            ],
            ],
            if (_receivedText.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Received text'),
              const SizedBox(height: 8),
              SelectableText(_receivedText),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => copyToClipboard(
                  widget.clipboardService,
                  _receivedText,
                ),
                child: const Text('Copy to Clipboard'),
              ),
            ],
            if (_saveStatus.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_saveStatus),
              if (_lastSavedPath != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () => _saveService.openIn(_lastSavedPath!),
                      child: const Text('Open in…'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => _saveService.saveAs(
                        _lastSavedPath!,
                        _suggestedExportName(),
                      ),
                      child: const Text('Save As…'),
                    ),
                    if (_lastSaveIsMedia) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () async {
                          final path = _lastSavedPath!;
                          final bytes = await File(path).readAsBytes();
                          final outcome = await _saveService.saveBytes(
                            bytes: bytes,
                            name: _suggestedExportName(),
                            mime: _lastSavedMime ?? 'application/octet-stream',
                            isMedia: true,
                            destination: SaveDestination.photos,
                          );
                          setState(() {
                            _saveStatus = outcome.success
                                ? 'Saved to Photos.'
                                : 'Save to Photos failed.';
                          });
                        },
                        child: const Text('Save to Photos'),
                      ),
                    ],
                  ],
                ),
              ],
              if (_lastManifest?.packagingMode == packagingModeZip &&
                  _lastZipBytes != null) ...[
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _extracting ? null : _extractZip,
                  child:
                      Text(_extracting ? 'Extracting...' : 'Extract ZIP'),
                ),
                if (_extractProgress != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Extracted ${_extractProgress!.filesExtracted}/${_extractProgress!.totalFiles} files',
                  ),
                ],
                if (_extractStatus.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_extractStatus),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

double _progressForState(TransferState state) {
  if (state.chunkSize <= 0) {
    return 0.0;
  }
  final chunks =
      (state.totalBytes + state.chunkSize - 1) ~/ state.chunkSize;
  final totalEncrypted = state.totalBytes + (chunks * 28);
  if (totalEncrypted == 0) {
    return 0.0;
  }
  return (state.nextOffset / totalEncrypted).clamp(0.0, 1.0);
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
    required this.senderPubKeyB64,
    required this.transferId,
    required this.scanRequired,
    required this.scanStatus,
    required this.sasState,
  });

  final String claimId;
  final String senderLabel;
  final String shortFingerprint;
  final String senderPubKeyB64;
  final String transferId;
  final bool scanRequired;
  final String scanStatus;
  final String sasState;

  factory PendingClaim.fromJson(Map<String, dynamic> json) {
    return PendingClaim(
      claimId: json['claim_id']?.toString() ?? '',
      senderLabel: json['sender_label']?.toString() ?? '',
      shortFingerprint: json['short_fingerprint']?.toString() ?? '',
      senderPubKeyB64: json['sender_pubkey_b64']?.toString() ?? '',
      transferId: json['transfer_id']?.toString() ?? '',
      scanRequired: json['scan_required'] == true,
      scanStatus: json['scan_status']?.toString() ?? '',
      sasState: json['sas_state']?.toString() ?? 'pending',
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

String _randomId() {
  final bytes = Uint8List(18);
  final random = Random.secure();
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return base64UrlEncode(bytes).replaceAll('=', '');
}
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:universaldrop_app/clipboard_service.dart';
import 'package:universaldrop_app/crypto.dart';
import 'package:universaldrop_app/diagnostics_screen.dart';
import 'package:universaldrop_app/destination_preferences.dart';
import 'package:universaldrop_app/destination_rules.dart';
import 'package:universaldrop_app/destination_selector.dart';
import 'package:universaldrop_app/key_store.dart';
import 'package:universaldrop_app/packaging_builder.dart';
import 'package:universaldrop_app/save_service.dart';
import 'package:universaldrop_app/transfer/background_transfer.dart';
import 'package:universaldrop_app/transfer_coordinator.dart';
import 'package:universaldrop_app/transfer_manifest.dart';
import 'package:universaldrop_app/transfer_state_store.dart';
import 'package:universaldrop_app/transport.dart';
import 'package:universaldrop_app/trust_store.dart';
import 'package:universaldrop_app/trusted_device_badge.dart';
import 'package:universaldrop_app/zip_extract.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    ClipboardService? clipboardService,
    this.saveService,
    this.destinationStore,
    this.onTransportSelected,
    this.runStartupTasks = true,
  }) : clipboardService = clipboardService ?? const SystemClipboardService();

  final ClipboardService clipboardService;
  final SaveService? saveService;
  final DestinationPreferenceStore? destinationStore;
  final void Function(Transport transport)? onTransportSelected;
  final bool runStartupTasks;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _baseUrlController =
      TextEditingController(text: 'http://localhost:8080');
  String _status = 'Idle';
  bool _loading = false;
  bool _creatingSession = false;
  String _sessionStatus = 'No session created yet.';
  SessionCreateResponse? _sessionResponse;
  KeyPair? _receiverKeyPair;
  final Map<String, String> _senderPubKeysByClaim = {};
  final Map<String, String> _transferTokensByClaim = {};
  String _manifestStatus = 'No manifest downloaded.';
  final Map<String, TransferState> _transferStates = {};
  final List<TransferFile> _selectedFiles = [];
  TransferCoordinator? _coordinator;
  late final SecureTransferStateStore _transferStore =
      SecureTransferStateStore();
  final SecureKeyPairStore _keyStore = SecureKeyPairStore();
  final BackgroundTransferApi _backgroundTransfer = BackgroundTransferApiImpl();
  final DownloadTokenStore _downloadTokenStore = DownloadTokenStore();
  late final DestinationPreferenceStore _destinationStore;
  late final SaveService _saveService;
  late final DestinationSelector _destinationSelector;
  final TrustStore _trustStore = const TrustStore();
  final TextEditingController _textTitleController = TextEditingController();
  final TextEditingController _textContentController = TextEditingController();
  bool _sendTextMode = false;
  String _receivedText = '';
  String _saveStatus = '';
  String? _lastSavedPath;
  bool _lastSaveIsMedia = false;
  String? _lastSavedMime;
  String _packagingMode = packagingModeOriginals;
  final TextEditingController _packageTitleController = TextEditingController();
  Uint8List? _lastZipBytes;
  TransferManifest? _lastManifest;
  bool _extracting = false;
  ExtractProgress? _extractProgress;
  String _extractStatus = '';
  final TextEditingController _qrPayloadController = TextEditingController();
  final TextEditingController _sessionIdController = TextEditingController();
  final TextEditingController _claimTokenController = TextEditingController();
  final TextEditingController _senderLabelController =
      TextEditingController(text: 'Sender');
  bool _sending = false;
  String _sendStatus = 'Idle';
  String? _claimId;
  String? _claimStatus;
  String? _senderTransferToken;
  String? _senderReceiverPubKeyB64;
  String? _senderPubKeyB64;
  String? _senderSasCode;
  String _senderSasState = 'pending';
  bool _senderSasConfirmed = false;
  bool _senderSasConfirming = false;
  KeyPair? _senderKeyPair;
  String? _senderSessionId;
  String? _senderP2PToken;
  bool _scanRequired = false;
  String _scanStatus = '';
  Timer? _pollTimer;
  bool _refreshingClaims = false;
  String _claimsStatus = 'No pending claims.';
  List<PendingClaim> _pendingClaims = [];
  final Map<String, String> _p2pTokensByClaim = {};
  bool _preferDirect = true;
  bool _alwaysRelay = false;
  bool _p2pDisclosureShown = false;
  bool _experimentalDisclosureShown = false;
  bool _preferBackgroundDownloads = false;
  bool _showNotificationDetails = false;
  bool _isForeground = true;
  final Set<String> _trustedFingerprints = {};
  final Map<String, String> _receiverSasByClaim = {};
  final Set<String> _receiverSasConfirming = {};

  static const _p2pPreferDirectKey = 'p2pPreferDirect';
  static const _p2pAlwaysRelayKey = 'p2pAlwaysRelay';
  static const _p2pDisclosureKey = 'p2pDirectDisclosureShown';
  static const _experimentalDisclosureKey = 'experimentalDisclosureShown';
  static const _preferBackgroundDownloadsKey = 'preferBackgroundDownloads';
  static const _notificationDetailsKey =
      'showNotificationDetailsInNotifications';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _destinationStore =
        widget.destinationStore ?? SharedPreferencesDestinationStore();
    _saveService = widget.saveService ?? DefaultSaveService();
    _destinationSelector = DestinationSelector(_destinationStore);
    if (widget.runStartupTasks) {
      _loadSettings();
      _resumePendingTransfers();
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _qrPayloadController.dispose();
    _sessionIdController.dispose();
    _claimTokenController.dispose();
    _senderLabelController.dispose();
    _textTitleController.dispose();
    _textContentController.dispose();
    _packageTitleController.dispose();
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    if (isForeground == _isForeground) {
      return;
    }
    if (!mounted) {
      _isForeground = isForeground;
      return;
    }
    setState(() {
      _isForeground = isForeground;
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final preferDirect = prefs.getBool(_p2pPreferDirectKey) ?? true;
    final alwaysRelay = prefs.getBool(_p2pAlwaysRelayKey) ?? false;
    final disclosureShown = prefs.getBool(_p2pDisclosureKey) ?? false;
    final experimentalDisclosureShown =
        prefs.getBool(_experimentalDisclosureKey) ?? false;
    final preferBackgroundDownloads =
        prefs.getBool(_preferBackgroundDownloadsKey) ?? false;
    final showNotificationDetails =
        prefs.getBool(_notificationDetailsKey) ?? false;
    final trustedFingerprints = await _trustStore.loadFingerprints();
    if (!mounted) {
      return;
    }
    setState(() {
      _preferDirect = preferDirect;
      _alwaysRelay = alwaysRelay;
      _p2pDisclosureShown = disclosureShown;
      _experimentalDisclosureShown = experimentalDisclosureShown;
      _preferBackgroundDownloads = preferBackgroundDownloads;
      _showNotificationDetails = showNotificationDetails;
      _trustedFingerprints
        ..clear()
        ..addAll(trustedFingerprints);
    });
  }

  Future<void> _persistP2PSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_p2pPreferDirectKey, _preferDirect);
    await prefs.setBool(_p2pAlwaysRelayKey, _alwaysRelay);
  }

  Future<void> _setPreferDirect(bool value) async {
    if (value) {
      await _maybeShowDirectDisclosure();
    }
    setState(() {
      _preferDirect = value;
      if (!value) {
        _alwaysRelay = false;
      }
    });
    await _persistP2PSettings();
  }

  Future<void> _setAlwaysRelay(bool value) async {
    if (!_preferDirect) {
      return;
    }
    setState(() {
      _alwaysRelay = value;
    });
    await _persistP2PSettings();
  }

  Future<void> _setPreferBackgroundDownloads(bool value) async {
    if (value) {
      await _maybeShowExperimentalDisclosure();
    }
    setState(() {
      _preferBackgroundDownloads = value;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_preferBackgroundDownloadsKey, value);
  }

  Future<void> _setNotificationDetails(bool value) async {
    setState(() {
      _showNotificationDetails = value;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationDetailsKey, value);
  }

  Future<void> _maybeShowDirectDisclosure() async {
    if (_p2pDisclosureShown || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Direct transfer disclosure'),
          content: const Text(
            'Direct transfer may reveal IP address to the other device. '
            'Use "Always relay" to avoid direct exposure.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_p2pDisclosureKey, true);
    if (!mounted) {
      return;
    }
    setState(() {
      _p2pDisclosureShown = true;
    });
  }

  Future<void> _maybeShowExperimentalDisclosure() async {
    if (_experimentalDisclosureShown || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Experimental features'),
          content: const Text(
            'May not be available on all devices. If unavailable, '
            'CipherLink uses standard mode.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_experimentalDisclosureKey, true);
    if (!mounted) {
      return;
    }
    setState(() {
      _experimentalDisclosureShown = true;
    });
  }

  Future<void> _addTrustedFingerprint(String fingerprint) async {
    final updated = await _trustStore.addFingerprint(fingerprint);
    if (!mounted) {
      return;
    }
    setState(() {
      _trustedFingerprints
        ..clear()
        ..addAll(updated);
    });
  }

  Future<void> _removeTrustedFingerprint(String fingerprint) async {
    final updated = await _trustStore.removeFingerprint(fingerprint);
    if (!mounted) {
      return;
    }
    setState(() {
      _trustedFingerprints
        ..clear()
        ..addAll(updated);
    });
  }

  String _formatFingerprint(String fingerprint) {
    final trimmed = fingerprint.trim();
    if (trimmed.length <= 12) {
      return trimmed;
    }
    return '${trimmed.substring(0, 6)}...${trimmed.substring(trimmed.length - 4)}';
  }

  List<Widget> _buildTrustedDevicesSection() {
    final entries = _trustedFingerprints.toList()..sort();
    if (entries.isEmpty) {
      return const [
        Text(
          'Trusted devices',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 8),
        Text('No trusted devices yet.'),
      ];
    }
    return [
      const Text(
        'Trusted devices',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      ...entries.map((fingerprint) {
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_formatFingerprint(fingerprint)),
          trailing: IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              _removeTrustedFingerprint(fingerprint);
            },
          ),
        );
      }),
    ];
  }

  void _openDiagnostics() {
    final baseUrl = _baseUrlController.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DiagnosticsScreen(baseUrl: baseUrl),
      ),
    );
  }

  void _ensureCoordinator() {
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      return;
    }
    final baseUri = Uri.parse(baseUrl);
    final transport = HttpTransport(baseUri);
    widget.onTransportSelected?.call(transport);
    _coordinator = TransferCoordinator(
      transport: transport,
      baseUri: baseUri,
      p2pTransportFactory: (context) => P2PTransport(
        baseUri: baseUri,
        context: context,
        fallbackTransport: transport,
      ),
      store: _transferStore,
      onState: (state) {
        setState(() {
          _transferStates[state.transferId] = state;
        });
      },
      onScanStatus: (transferId, status) {
        setState(() {
          _scanStatus = status;
        });
      },
      backgroundTransfer: _backgroundTransfer,
      downloadTokenStore: _downloadTokenStore,
      saveHandler: _handleTransferSave,
      downloadResolver: _resolveDownloadResumeContext,
    );
  }

  TransferDownloadPolicy _downloadPolicy() {
    return TransferDownloadPolicy(
      preferBackground: _preferBackgroundDownloads,
      showNotificationDetails: _showNotificationDetails,
      destinationResolver: _resolveBackgroundDestination,
      isAppInForeground: () => _isForeground,
    );
  }

  Future<SaveDestination?> _resolveBackgroundDestination(
    TransferManifest manifest,
    bool allowPrompt,
  ) async {
    if (allowPrompt && mounted) {
      final defaultDestination =
          await _destinationSelector.defaultDestination(manifest);
      final choice = await _showDestinationSelector(
        defaultDestination,
        isMediaManifest(manifest),
      );
      if (choice == null) {
        return null;
      }
      await _destinationSelector.rememberChoice(manifest, choice);
      return choice.destination;
    }
    final prefs = await _destinationStore.load();
    if (isMediaManifest(manifest)) {
      return prefs.defaultMediaDestination ?? SaveDestination.files;
    }
    return prefs.defaultFileDestination ?? SaveDestination.files;
  }

  SaveDestination? _destinationFromState(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    for (final destination in SaveDestination.values) {
      if (destination.name == value) {
        return destination;
      }
    }
    return null;
  }

  Future<TransferSaveResult> _handleTransferSave(
    TransferManifest manifest,
    Uint8List bytes,
    TransferState state,
  ) async {
    final destination = _destinationFromState(state.destination) ??
        await _resolveBackgroundDestination(manifest, false) ??
        SaveDestination.files;

    if (manifest.payloadKind == payloadKindText) {
      final text = utf8.decode(bytes);
      if (mounted) {
        setState(() {
          _receivedText = text;
          _manifestStatus = 'Text received.';
          _saveStatus = 'Ready to copy.';
        });
      } else {
        _receivedText = text;
      }
      return const TransferSaveResult(shouldSendReceipt: true);
    }

    if (manifest.packagingMode == packagingModeAlbum) {
      final outcome = await _saveAlbumPayload(
        bytes: bytes,
        manifest: manifest,
        destination: destination,
        allowUserInteraction: false,
      );
      if (mounted) {
        setState(() {
          _manifestStatus =
              'Album: ${manifest.albumItemCount ?? manifest.files.length} items';
          _saveStatus =
              outcome.success ? 'Album saved.' : 'Album saved with fallback.';
        });
      }
      return TransferSaveResult(
        shouldSendReceipt: outcome.success || outcome.localPath != null,
        localPath: outcome.localPath,
      );
    }

    _lastManifest = manifest;
    _extractStatus = '';
    _extractProgress = null;
    if (manifest.packagingMode == packagingModeZip) {
      _lastZipBytes = bytes;
    } else {
      _lastZipBytes = null;
    }
    final fileName = _suggestFileName(manifest);
    final mime = _suggestMime(manifest);
    final isMedia = isMediaManifest(manifest);
    final outcome = await _saveService.saveBytes(
      bytes: bytes,
      name: fileName,
      mime: mime,
      isMedia: isMedia,
      destination: destination,
      allowUserInteraction: false,
    );
    _lastSavedPath = outcome.localPath;
    _lastSaveIsMedia = isMedia;
    _lastSavedMime = mime;
    if (mounted) {
      setState(() {
        if (manifest.packagingMode == packagingModeZip) {
          _manifestStatus = 'ZIP: ${manifest.outputFilename ?? fileName}';
        } else if (manifest.files.isNotEmpty) {
          _manifestStatus = 'File: ${manifest.files.first.relativePath}';
        } else {
          _manifestStatus = 'Downloaded ${bytes.length} bytes.';
        }
        _saveStatus = outcome.success ? 'Saved.' : 'Saved locally with fallback.';
      });
    }
    return TransferSaveResult(
      shouldSendReceipt: outcome.success || outcome.localPath != null,
      localPath: outcome.localPath,
    );
  }

  Future<void> _resumePendingTransfers() async {
    _ensureCoordinator();
    final coordinator = _coordinator;
    if (coordinator == null) {
      return;
    }
    await coordinator.resumePendingDownloads(
      resolve: _resolveDownloadResumeContext,
      downloadPolicy: _downloadPolicy(),
    );
    await coordinator.resumePendingUploads(
      resolve: _resolveUploadResumeContext,
    );
  }

  Future<DownloadResumeContext?> _resolveDownloadResumeContext(
    TransferState state,
  ) async {
    if (state.sessionId.isEmpty ||
        state.transferToken.isEmpty ||
        state.transferId.isEmpty) {
      return null;
    }
    final senderPubKeyB64 = state.peerPublicKeyB64 ?? '';
    if (senderPubKeyB64.isEmpty) {
      return null;
    }
    final receiverKeyPair = await _keyStore.loadKeyPair(
      sessionId: state.sessionId,
      role: KeyRole.receiver,
    );
    if (receiverKeyPair == null) {
      return null;
    }
    return DownloadResumeContext(
      sessionId: state.sessionId,
      transferToken: state.transferToken,
      transferId: state.transferId,
      senderPublicKey: publicKeyFromBase64(senderPubKeyB64),
      receiverKeyPair: receiverKeyPair,
    );
  }

  Future<UploadResumeContext?> _resolveUploadResumeContext(
    TransferState state,
  ) async {
    if (state.sessionId.isEmpty ||
        state.transferToken.isEmpty ||
        state.transferId.isEmpty) {
      return null;
    }
    final payloadPath = state.payloadPath ?? '';
    if (payloadPath.isEmpty) {
      return null;
    }
    final payloadFile = File(payloadPath);
    if (!await payloadFile.exists()) {
      return null;
    }
    final senderKeyPair = await _keyStore.loadKeyPair(
      sessionId: state.sessionId,
      role: KeyRole.sender,
    );
    if (senderKeyPair == null) {
      return null;
    }
    final receiverPubKeyB64 = state.peerPublicKeyB64 ?? '';
    if (receiverPubKeyB64.isEmpty) {
      return null;
    }
    final bytes = await payloadFile.readAsBytes();
    final transferFile = TransferFile(
      id: state.transferId,
      name: p.basename(payloadPath),
      bytes: bytes,
      payloadKind: payloadKindFile,
      mimeType: 'application/octet-stream',
      packagingMode: packagingModeOriginals,
      localPath: payloadPath,
    );
    return UploadResumeContext(
      file: transferFile,
      sessionId: state.sessionId,
      transferToken: state.transferToken,
      receiverPublicKey: publicKeyFromBase64(receiverPubKeyB64),
      senderKeyPair: senderKeyPair,
      chunkSize: state.chunkSize,
      scanRequired: state.scanRequired ?? false,
      transferId: state.transferId,
    );
  }

  P2PContext? _buildP2PContext({
    required String sessionId,
    required String claimId,
    required String token,
    required bool isInitiator,
  }) {
    if (!_preferDirect) {
      return null;
    }
    if (sessionId.isEmpty || claimId.isEmpty || token.isEmpty) {
      return null;
    }
    return P2PContext(
      sessionId: sessionId,
      claimId: claimId,
      token: token,
      isInitiator: isInitiator,
      iceMode: _alwaysRelay ? P2PIceMode.relay : P2PIceMode.direct,
    );
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
      final keyPair = await X25519().newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final receiverPubKeyB64 = publicKeyToBase64(publicKey);

      final baseUri = Uri.parse(baseUrl);
      final response = await http
          .post(
            baseUri.resolve('/v1/session/create'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'receiver_pubkey_b64': receiverPubKeyB64}),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        setState(() {
          _sessionStatus = 'Error: ${response.statusCode}';
        });
        return;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final sessionResponse = SessionCreateResponse.fromJson(payload);
      final stored = await _keyStore.trySaveKeyPair(
        sessionId: sessionResponse.sessionId,
        role: KeyRole.receiver,
        keyPair: keyPair,
      );
      if (!stored) {
        setState(() {
          _sessionStatus =
              'Secure storage unavailable. Cannot persist session keys.';
        });
        return;
      }
      setState(() {
        _sessionResponse = sessionResponse;
        _sessionStatus = 'Session created.';
        _claimsStatus = 'Session created. Refresh to load claims.';
        _pendingClaims = [];
        _receiverSasByClaim.clear();
        _receiverSasConfirming.clear();
        _receiverKeyPair = keyPair;
        _receivedText = '';
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
        _claimsStatus =
            claims.isEmpty ? 'No pending claims.' : 'Pending claims loaded.';
      });
      await _updateReceiverSasCodes(claims);
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

  Future<void> _updateReceiverSasCodes(List<PendingClaim> claims) async {
    final receiverPubKeyB64 = _sessionResponse?.receiverPubKeyB64 ?? '';
    final sessionId = _sessionResponse?.sessionId ?? '';
    if (receiverPubKeyB64.isEmpty || sessionId.isEmpty) {
      return;
    }
    final updates = <String, String>{};
    for (final claim in claims) {
      if (claim.senderPubKeyB64.isEmpty) {
        continue;
      }
      if (_receiverSasByClaim.containsKey(claim.claimId)) {
        continue;
      }
      final sas = await deriveSasDigits(
        sessionId: sessionId,
        claimId: claim.claimId,
        receiverPubKeyB64: receiverPubKeyB64,
        senderPubKeyB64: claim.senderPubKeyB64,
      );
      updates[claim.claimId] = sas;
    }
    if (updates.isEmpty || !mounted) {
      return;
    }
    setState(() {
      _receiverSasByClaim.addAll(updates);
    });
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

    var scanRequired = false;
    if (approve) {
      final choice = await _promptScanChoice();
      if (choice == null) {
        return;
      }
      scanRequired = choice;
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
              if (approve) 'scan_required': scanRequired,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        final payload = jsonDecode(response.body) as Map<String, dynamic>?;
        final error = payload?['error']?.toString();
        setState(() {
          _claimsStatus = error == 'sas_required'
              ? 'SAS must be verified by both devices.'
              : 'Error: ${response.statusCode}';
        });
        return;
      }

      if (approve) {
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        final transferToken = payload['transfer_token']?.toString() ?? '';
        final p2pToken = payload['p2p_token']?.toString() ?? '';
        final senderPubKey = payload['sender_pubkey_b64']?.toString() ?? '';
        if (transferToken.isNotEmpty) {
          _transferTokensByClaim[claim.claimId] = transferToken;
        }
        if (p2pToken.isNotEmpty) {
          _p2pTokensByClaim[claim.claimId] = p2pToken;
        }
        if (senderPubKey.isNotEmpty) {
          _senderPubKeysByClaim[claim.claimId] = senderPubKey;
        }
        await _addTrustedFingerprint(claim.shortFingerprint);
      }
      await _refreshClaims();
    } catch (err) {
      setState(() {
        _claimsStatus = 'Failed: $err';
      });
    }
  }

  Future<bool> _commitSas({
    required String sessionId,
    required String claimId,
    required String role,
  }) async {
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      return false;
    }
    final response = await http
        .post(
          Uri.parse(baseUrl).resolve('/v1/session/sas/commit'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'session_id': sessionId,
            'claim_id': claimId,
            'role': role,
            'sas_confirmed': true,
          }),
        )
        .timeout(const Duration(seconds: 8));
    return response.statusCode == 200;
  }

  Future<void> _confirmReceiverSas(PendingClaim claim) async {
    final sessionId = _sessionResponse?.sessionId ?? '';
    if (sessionId.isEmpty) {
      setState(() {
        _claimsStatus = 'Create a session first.';
      });
      return;
    }
    if (_receiverSasConfirming.contains(claim.claimId)) {
      return;
    }
    setState(() {
      _receiverSasConfirming.add(claim.claimId);
      _claimsStatus = 'Confirming SAS...';
    });
    try {
      final ok = await _commitSas(
        sessionId: sessionId,
        claimId: claim.claimId,
        role: 'receiver',
      );
      if (!ok) {
        setState(() {
          _claimsStatus = 'Failed to confirm SAS.';
        });
        return;
      }
      await _refreshClaims();
      setState(() {
        _claimsStatus = 'SAS confirmed.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _receiverSasConfirming.remove(claim.claimId);
        });
      }
    }
  }

  Future<void> _confirmSenderSas() async {
    final sessionId = _senderSessionId ?? '';
    final claimId = _claimId ?? '';
    if (sessionId.isEmpty || claimId.isEmpty) {
      setState(() {
        _sendStatus = 'Claim a session first.';
      });
      return;
    }
    if (_senderSasConfirming) {
      return;
    }
    setState(() {
      _senderSasConfirming = true;
      _sendStatus = 'Confirming SAS...';
    });
    try {
      final ok = await _commitSas(
        sessionId: sessionId,
        claimId: claimId,
        role: 'sender',
      );
      if (!ok) {
        setState(() {
          _sendStatus = 'Failed to confirm SAS.';
        });
        return;
      }
      setState(() {
        _senderSasConfirmed = true;
        _sendStatus = 'SAS confirmed. Awaiting approval...';
      });
    } finally {
      if (mounted) {
        setState(() {
          _senderSasConfirming = false;
        });
      }
    }
  }

  Future<void> _updateSenderSasCode() async {
    if (_senderSasCode != null) {
      return;
    }
    final sessionId = _senderSessionId ?? '';
    final claimId = _claimId ?? '';
    final receiverPubKeyB64 = _senderReceiverPubKeyB64 ?? '';
    final senderPubKeyB64 = _senderPubKeyB64 ?? '';
    if (sessionId.isEmpty ||
        claimId.isEmpty ||
        receiverPubKeyB64.isEmpty ||
        senderPubKeyB64.isEmpty) {
      return;
    }
    final sas = await deriveSasDigits(
      sessionId: sessionId,
      claimId: claimId,
      receiverPubKeyB64: receiverPubKeyB64,
      senderPubKeyB64: senderPubKeyB64,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _senderSasCode = sas;
    });
  }

  Future<bool?> _promptScanChoice() {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        bool scanRequired = false;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Trust decision'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<bool>(
                    value: false,
                    groupValue: scanRequired,
                    onChanged: (value) {
                      setState(() {
                        scanRequired = value ?? false;
                      });
                    },
                    title: const Text('Trust (no scan)'),
                  ),
                  RadioListTile<bool>(
                    value: true,
                    groupValue: scanRequired,
                    onChanged: (value) {
                      setState(() {
                        scanRequired = value ?? false;
                      });
                    },
                    title: const Text('Don’t trust but accept w/ scan'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(scanRequired),
                  child: const Text('Continue'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _downloadManifest(PendingClaim claim) async {
    final baseUrl = _baseUrlController.text.trim();
    final sessionId = _sessionResponse?.sessionId ?? '';
    final transferToken = _transferTokensByClaim[claim.claimId] ?? '';
    final senderPubKeyB64 = _senderPubKeysByClaim[claim.claimId] ?? '';
    if (baseUrl.isEmpty || sessionId.isEmpty) {
      setState(() {
        _manifestStatus = 'Create a session first.';
      });
      return;
    }
    if (claim.transferId.isEmpty) {
      setState(() {
        _manifestStatus = 'No transfer ID yet.';
      });
      return;
    }
    if (transferToken.isEmpty ||
        senderPubKeyB64.isEmpty ||
        _receiverKeyPair == null) {
      setState(() {
        _manifestStatus = 'Missing auth context or keys.';
      });
      return;
    }

    if (_preferDirect) {
      await _maybeShowDirectDisclosure();
    }
    final p2pToken = _p2pTokensByClaim[claim.claimId] ?? transferToken;
    final p2pContext = _buildP2PContext(
      sessionId: sessionId,
      claimId: claim.claimId,
      token: p2pToken,
      isInitiator: false,
    );

    setState(() {
      _manifestStatus = 'Downloading manifest...';
    });

    try {
      _ensureCoordinator();
      final coordinator = _coordinator;
      if (coordinator == null) {
        setState(() {
          _manifestStatus = 'Invalid base URL.';
        });
        return;
      }
      final senderPublicKey = publicKeyFromBase64(senderPubKeyB64);
      final result = await coordinator.downloadTransfer(
        sessionId: sessionId,
        transferToken: transferToken,
        transferId: claim.transferId,
        senderPublicKey: senderPublicKey,
        receiverKeyPair: _receiverKeyPair!,
        sendReceipt: false,
        p2pContext: p2pContext,
        downloadPolicy: _downloadPolicy(),
      );
      if (result == null) {
        final pending = await _transferStore.load(claim.transferId);
        if (!mounted) {
          return;
        }
        setState(() {
          if (pending?.backgroundTaskId?.isNotEmpty == true) {
            _manifestStatus = 'Download running in background.';
          } else if (pending?.requiresForegroundResume == true) {
            _manifestStatus = 'Download paused. Resume in foreground.';
          } else {
            _manifestStatus = 'Download paused or failed.';
          }
        });
        return;
      }
      final manifest = result.manifest;
      _lastManifest = manifest;
      _extractStatus = '';
      _extractProgress = null;
      if (manifest.packagingMode != packagingModeZip) {
        _lastZipBytes = null;
      }
      if (manifest.payloadKind == payloadKindText) {
        final text = utf8.decode(result.bytes);
        setState(() {
          _receivedText = text;
          _manifestStatus = 'Text received.';
          _saveStatus = 'Ready to copy.';
        });
        await coordinator.sendReceipt(
          sessionId: sessionId,
          transferId: result.transferId,
          transferToken: transferToken,
        );
        return;
      }

      final defaultDestination =
          await _destinationSelector.defaultDestination(manifest);
      final choice = await _showDestinationSelector(
        defaultDestination,
        isMediaManifest(manifest),
      );
      if (choice == null) {
        setState(() {
          _manifestStatus = 'Save cancelled.';
        });
        return;
      }
      await _destinationSelector.rememberChoice(manifest, choice);

      if (manifest.packagingMode == packagingModeAlbum) {
        final outcome = await _saveAlbumPayload(
          bytes: result.bytes,
          manifest: manifest,
          destination: choice.destination,
        );
        setState(() {
          _manifestStatus =
              'Album: ${manifest.albumItemCount ?? manifest.files.length} items';
          _saveStatus =
              outcome.success ? 'Album saved.' : 'Album saved with fallback.';
        });
        if (outcome.success || outcome.localPath != null) {
          await coordinator.sendReceipt(
            sessionId: sessionId,
            transferId: result.transferId,
            transferToken: transferToken,
          );
        }
        return;
      }

      if (manifest.packagingMode == packagingModeZip) {
        _lastZipBytes = result.bytes;
      }
      final fileName = _suggestFileName(manifest);
      final mime = _suggestMime(manifest);
      final isMedia = isMediaManifest(manifest);
      final outcome = await _saveService.saveBytes(
        bytes: result.bytes,
        name: fileName,
        mime: mime,
        isMedia: isMedia,
        destination: choice.destination,
      );
      _lastSavedPath = outcome.localPath;
      _lastSaveIsMedia = isMedia;
      _lastSavedMime = mime;
      setState(() {
        if (manifest.packagingMode == packagingModeZip) {
          _manifestStatus = 'ZIP: ${manifest.outputFilename ?? fileName}';
        } else if (manifest.files.isNotEmpty) {
          _manifestStatus = 'File: ${manifest.files.first.relativePath}';
        } else {
          _manifestStatus = 'Downloaded ${result.bytes.length} bytes.';
        }
        _saveStatus = outcome.success ? 'Saved.' : 'Saved locally with fallback.';
      });

      if (outcome.success || outcome.localPath != null) {
        await coordinator.sendReceipt(
          sessionId: sessionId,
          transferId: result.transferId,
          transferToken: transferToken,
        );
      }
    } catch (err) {
      setState(() {
        _manifestStatus = 'Manifest error: $err';
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

      final stored = await _keyStore.trySaveKeyPair(
        sessionId: sessionId,
        role: KeyRole.sender,
        keyPair: keyPair,
      );
      if (!stored) {
        setState(() {
          _sendStatus = 'Secure storage unavailable. Cannot continue.';
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
        _senderKeyPair = keyPair;
        _senderPubKeyB64 = pubKeyB64;
        _senderSessionId = sessionId;
        _senderReceiverPubKeyB64 = null;
        _senderTransferToken = null;
        _senderP2PToken = null;
        _senderSasCode = null;
        _senderSasState = 'pending';
        _senderSasConfirmed = false;
        _senderSasConfirming = false;
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

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) {
      return;
    }
    final files = <TransferFile>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) {
        continue;
      }
      final id = _randomId();
      final localPath = await _cacheUploadPayload(id, bytes);
      final mimeType = lookupMimeType(file.name, headerBytes: bytes) ??
          'application/octet-stream';
      files.add(
        TransferFile(
          id: id,
          name: file.name,
          bytes: bytes,
          payloadKind: payloadKindFile,
          mimeType: mimeType,
          packagingMode: packagingModeOriginals,
          localPath: localPath,
        ),
      );
    }
    if (files.isEmpty) {
      setState(() {
        _sendStatus = 'No files loaded.';
      });
      return;
    }
    setState(() {
      _selectedFiles
        ..clear()
        ..addAll(files);
    });
  }

  Future<void> _pickMedia() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.media,
    );
    if (result == null) {
      return;
    }
    final files = <TransferFile>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) {
        continue;
      }
      final id = _randomId();
      final localPath = await _cacheUploadPayload(id, bytes);
      final name = file.name.isNotEmpty ? file.name : 'media';
      final mimeType = lookupMimeType(name, headerBytes: bytes) ??
          'application/octet-stream';
      files.add(
        TransferFile(
          id: id,
          name: name,
          bytes: bytes,
          payloadKind: payloadKindFile,
          mimeType: mimeType,
          packagingMode: packagingModeOriginals,
          localPath: localPath,
        ),
      );
    }
    if (files.isEmpty) {
      setState(() {
        _sendStatus = 'No media loaded.';
      });
      return;
    }
    setState(() {
      _selectedFiles
        ..clear()
        ..addAll(files);
    });
  }

  Future<String?> _cacheUploadPayload(String id, Uint8List bytes) async {
    final dir = await getApplicationSupportDirectory();
    final uploadDir = Directory(p.join(dir.path, 'upload_cache'));
    await uploadDir.create(recursive: true);
    final path = p.join(uploadDir.path, id);
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<void> _startQueue() async {
    if (_senderTransferToken == null ||
        _senderReceiverPubKeyB64 == null ||
        _senderKeyPair == null ||
        _senderSessionId == null) {
      setState(() {
        _sendStatus = 'Claim and wait for approval first.';
      });
      return;
    }
    if (_selectedFiles.isEmpty) {
      setState(() {
        _sendStatus = 'Select files first.';
      });
      return;
    }
    if (_preferDirect) {
      await _maybeShowDirectDisclosure();
    }
    _ensureCoordinator();
    final coordinator = _coordinator;
    if (coordinator == null) {
      setState(() {
        _sendStatus = 'Invalid base URL.';
      });
      return;
    }
    final p2pToken = _senderP2PToken ?? _senderTransferToken ?? '';
    final p2pContext = _buildP2PContext(
      sessionId: _senderSessionId!,
      claimId: _claimId ?? '',
      token: p2pToken,
      isInitiator: true,
    );
    if (_packagingMode == packagingModeOriginals) {
      coordinator.enqueueUploads(
        files: _selectedFiles,
        sessionId: _senderSessionId!,
        transferToken: _senderTransferToken!,
        receiverPublicKey: publicKeyFromBase64(_senderReceiverPubKeyB64!),
        senderKeyPair: _senderKeyPair!,
        chunkSize: 64 * 1024,
        scanRequired: _scanRequired,
        p2pContext: p2pContext,
      );
      setState(() {
        _sendStatus = 'Queue started.';
      });
      await coordinator.runQueue();
      return;
    }

    final packageTitle = _packageTitleController.text.trim().isEmpty
        ? _defaultPackageTitle()
        : _packageTitleController.text.trim();
    try {
      final package = buildZipPackage(
        files: _selectedFiles,
        packageTitle: packageTitle,
        albumMode: _packagingMode == packagingModeAlbum,
      );
      final payloadKind = _packagingMode == packagingModeAlbum
          ? payloadKindAlbum
          : payloadKindZip;
      final id = _randomId();
      final localPath = await _cacheUploadPayload(id, package.bytes);
      final transferFile = TransferFile(
        id: id,
        name: package.outputName,
        bytes: package.bytes,
        payloadKind: payloadKind,
        mimeType: 'application/zip',
        packagingMode: _packagingMode,
        packageTitle: packageTitle,
        entries: package.entries,
        localPath: localPath,
      );
      coordinator.enqueueUploads(
        files: [transferFile],
        sessionId: _senderSessionId!,
        transferToken: _senderTransferToken!,
        receiverPublicKey: publicKeyFromBase64(_senderReceiverPubKeyB64!),
        senderKeyPair: _senderKeyPair!,
        chunkSize: 64 * 1024,
        scanRequired: _scanRequired,
        p2pContext: p2pContext,
      );
      setState(() {
        _sendStatus = 'Package queued.';
        _selectedFiles.clear();
      });
      await coordinator.runQueue();
    } catch (err) {
      setState(() {
        _sendStatus = 'Packaging failed: $err';
      });
    }
  }

  void _pauseQueue() {
    _coordinator?.pause();
    setState(() {
      _sendStatus = 'Paused.';
    });
  }

  Future<void> _resumeQueue() async {
    await _coordinator?.resume();
    setState(() {
      _sendStatus = 'Resumed.';
    });
  }

  Future<void> _sendText() async {
    final text = _textContentController.text;
    if (text.trim().isEmpty) {
      setState(() {
        _sendStatus = 'Enter text first.';
      });
      return;
    }
    if (_senderTransferToken == null ||
        _senderReceiverPubKeyB64 == null ||
        _senderKeyPair == null ||
        _senderSessionId == null) {
      setState(() {
        _sendStatus = 'Claim and wait for approval first.';
      });
      return;
    }
    if (_preferDirect) {
      await _maybeShowDirectDisclosure();
    }

    _ensureCoordinator();
    final coordinator = _coordinator;
    if (coordinator == null) {
      setState(() {
        _sendStatus = 'Invalid base URL.';
      });
      return;
    }

    final textBytes = Uint8List.fromList(utf8.encode(text));
    final id = _randomId();
    final localPath = await _cacheUploadPayload(id, textBytes);
    final payload = TransferFile(
      id: id,
      name: _textTitleController.text.trim().isEmpty
          ? 'Text'
          : _textTitleController.text.trim(),
      bytes: textBytes,
      payloadKind: payloadKindText,
      mimeType: textMimePlain,
      packagingMode: packagingModeOriginals,
      textTitle: _textTitleController.text.trim().isEmpty
          ? null
          : _textTitleController.text.trim(),
      localPath: localPath,
    );
    final p2pToken = _senderP2PToken ?? _senderTransferToken ?? '';
    final p2pContext = _buildP2PContext(
      sessionId: _senderSessionId!,
      claimId: _claimId ?? '',
      token: p2pToken,
      isInitiator: true,
    );

    coordinator.enqueueUploads(
      files: [payload],
      sessionId: _senderSessionId!,
      transferToken: _senderTransferToken!,
      receiverPublicKey: publicKeyFromBase64(_senderReceiverPubKeyB64!),
      senderKeyPair: _senderKeyPair!,
      chunkSize: 16 * 1024,
      scanRequired: _scanRequired,
      p2pContext: p2pContext,
    );
    setState(() {
      _sendStatus = 'Sending text...';
      _selectedFiles.clear();
    });
    await coordinator.runQueue();
  }

  Future<void> _pasteFromClipboard() async {
    final text = await widget.clipboardService.readText();
    if (text == null || text.isEmpty) {
      setState(() {
        _sendStatus = 'Clipboard empty.';
      });
      return;
    }
    setState(() {
      _textContentController.text = text;
    });
  }

  Future<DestinationChoice?> _showDestinationSelector(
    SaveDestination defaultDestination,
    bool isMedia,
  ) async {
    SaveDestination selected =
        isMedia ? defaultDestination : SaveDestination.files;
    bool remember = false;
    return showDialog<DestinationChoice>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Choose destination'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<SaveDestination>(
                    value: SaveDestination.photos,
                    groupValue: selected,
                    onChanged: isMedia
                        ? (value) {
                            if (value == null) return;
                            setState(() {
                              selected = value;
                            });
                          }
                        : null,
                    title: const Text('Save to Photos/Gallery'),
                  ),
                  RadioListTile<SaveDestination>(
                    value: SaveDestination.files,
                    groupValue: selected,
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        selected = value;
                      });
                    },
                    title: const Text('Save to Files'),
                  ),
                  Row(
                    children: [
                      Checkbox(
                        value: remember,
                        onChanged: (value) {
                          setState(() {
                            remember = value ?? false;
                          });
                        },
                      ),
                      const Text('Remember my choice'),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop(
                      DestinationChoice(
                        destination: selected,
                        remember: remember,
                      ),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<SaveOutcome> _saveAlbumPayload({
    required Uint8List bytes,
    required TransferManifest manifest,
    required SaveDestination destination,
    bool allowUserInteraction = true,
  }) async {
    final entries = decodeZipEntries(bytes);
    final fileMap = <String, TransferManifestFile>{};
    for (final entry in manifest.files) {
      fileMap[entry.relativePath] = entry;
    }

    SaveOutcome lastOutcome = SaveOutcome(
      success: false,
      usedFallback: false,
      savedToGallery: false,
    );
    for (final entry in entries) {
      if (!entry.isFile) {
        continue;
      }
      final name = entry.name;
      if (!name.startsWith('media/')) {
        continue;
      }
      final relativePath = name.substring('media/'.length);
      final metadata = fileMap[relativePath];
      final mime =
          metadata?.mime ?? lookupMimeType(relativePath) ?? 'application/octet-stream';
      final outcome = await _saveService.saveBytes(
        bytes: entry.bytes,
        name: relativePath,
        mime: mime,
        isMedia: true,
        destination: destination,
        allowUserInteraction: allowUserInteraction,
      );
      if (_lastSavedPath == null && outcome.localPath != null) {
        _lastSavedPath = outcome.localPath;
        _lastSaveIsMedia = true;
        _lastSavedMime = mime;
      }
      lastOutcome = outcome;
      if (!outcome.success && outcome.localPath == null) {
        return outcome;
      }
    }
    return lastOutcome;
  }

  Future<void> _extractZip() async {
    final zipBytes = _lastZipBytes;
    final manifest = _lastManifest;
    if (zipBytes == null || manifest == null) {
      return;
    }
    setState(() {
      _extracting = true;
      _extractStatus = 'Extracting...';
    });

    try {
      final destination = await getDirectoryPath();
      String destPath;
      if (destination == null) {
        final dir = await getApplicationDocumentsDirectory();
        destPath = p.join(dir.path, _defaultPackageTitle());
      } else {
        destPath = destination;
      }
      final result = await extractZipBytes(
        bytes: zipBytes,
        destinationDir: destPath,
        onProgress: (progress) {
          setState(() {
            _extractProgress = progress;
          });
        },
      );
      setState(() {
        _extractStatus = 'Extracted ${result.filesExtracted} files.';
      });
    } catch (err) {
      setState(() {
        if (err is ZipLimitException) {
          _extractStatus = err.message;
        } else {
          _extractStatus = 'Extraction failed.';
        }
      });
    } finally {
      setState(() {
        _extracting = false;
      });
    }
  }

  String _defaultPackageTitle() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return 'Package_${now.year}$month$day_$hour$minute';
  }

  String _suggestFileName(TransferManifest manifest) {
    if (manifest.packagingMode == packagingModeZip &&
        manifest.outputFilename != null &&
        manifest.outputFilename!.isNotEmpty) {
      return manifest.outputFilename!;
    }
    if (manifest.payloadKind == payloadKindText) {
      final title = manifest.textTitle?.trim();
      if (title != null && title.isNotEmpty) {
        return '$title.txt';
      }
      return 'text.txt';
    }
    if (manifest.files.isNotEmpty) {
      return manifest.files.first.relativePath;
    }
    return 'transfer.bin';
  }

  String _suggestMime(TransferManifest manifest) {
    if (manifest.payloadKind == payloadKindText) {
      return manifest.textMime ?? textMimePlain;
    }
    if (manifest.packagingMode == packagingModeZip) {
      return 'application/zip';
    }
    if (manifest.files.isNotEmpty) {
      return manifest.files.first.mime ?? 'application/octet-stream';
    }
    return 'application/octet-stream';
  }

  String _suggestedExportName() {
    if (_lastSavedPath == null) {
      return 'export.bin';
    }
    return _lastSavedPath!.split(Platform.pathSeparator).last;
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
      final transferToken = payload['transfer_token']?.toString();
      final p2pToken = payload['p2p_token']?.toString();
      final receiverPubKey = payload['receiver_pubkey_b64']?.toString();
      final scanRequired = payload['scan_required'] == true;
      final scanStatus = payload['scan_status']?.toString() ?? '';
      final sasState = payload['sas_state']?.toString() ?? 'pending';
      setState(() {
        _claimStatus = status;
        _sendStatus = 'Status: $status';
        if (receiverPubKey != null && receiverPubKey.isNotEmpty) {
          _senderReceiverPubKeyB64 = receiverPubKey;
        }
        if (transferToken != null && transferToken.isNotEmpty) {
          _senderTransferToken = transferToken;
        }
        if (p2pToken != null && p2pToken.isNotEmpty) {
          _senderP2PToken = p2pToken;
        }
        _scanRequired = scanRequired;
        _scanStatus = scanStatus;
        _senderSasState = sasState;
        if (sasState == 'sender_confirmed' || sasState == 'verified') {
          _senderSasConfirmed = true;
        }
      });
      await _updateSenderSasCode();

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
            const Text(
              'P2P settings',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Prefer direct'),
              subtitle: const Text('Use WebRTC when available'),
              value: _preferDirect,
              onChanged: (value) => _setPreferDirect(value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Always relay'),
              subtitle: const Text('Force TURN relay (no direct IP exposure)'),
              value: _alwaysRelay,
              onChanged: _preferDirect ? (value) => _setAlwaysRelay(value) : null,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _loading ? null : _pingBackend,
                  child: Text(_loading ? 'Pinging...' : 'Ping Backend'),
                ),
                OutlinedButton(
                  onPressed: _openDiagnostics,
                  child: const Text('Diagnostics'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Status: $_status'),
            const SizedBox(height: 24),
            const Text(
              'Download settings',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Prefer background downloads'),
              subtitle:
                  const Text('Use background downloads for large transfers'),
              value: _preferBackgroundDownloads,
              onChanged: (value) => _setPreferBackgroundDownloads(value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show more details in notifications'),
              subtitle: const Text('May include transfer details'),
              value: _showNotificationDetails,
              onChanged: (value) => _setNotificationDetails(value),
            ),
            const SizedBox(height: 16),
            ..._buildTrustedDevicesSection(),
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
                final sasCode = _receiverSasByClaim[claim.claimId] ?? '';
                final sasState = claim.sasState;
                final receiverConfirmed =
                    sasState == 'receiver_confirmed' || sasState == 'verified';
                final sasVerified = sasState == 'verified';
                final sasConfirming = _receiverSasConfirming.contains(claim.claimId);
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
                        if (claim.transferId.isNotEmpty)
                          Text('Transfer ID: ${claim.transferId}'),
                        if (claim.scanRequired)
                          Text('Scan status: ${claim.scanStatus.isEmpty ? 'pending' : claim.scanStatus}'),
                        if (sasCode.isNotEmpty) Text('SAS: $sasCode'),
                        Text('SAS state: ${sasState.isEmpty ? 'pending' : sasState}'),
                        const SizedBox(height: 4),
                        ElevatedButton(
                          onPressed: sasCode.isEmpty || receiverConfirmed || sasConfirming
                              ? null
                              : () => _confirmReceiverSas(claim),
                          child: Text(
                            sasConfirming
                                ? 'Confirming...'
                                : receiverConfirmed
                                    ? 'SAS confirmed'
                                    : 'Confirm SAS',
                          ),
                        ),
                        TrustedDeviceBadge.forFingerprint(
                          fingerprint: claim.shortFingerprint,
                          trustedFingerprints: _trustedFingerprints,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            ElevatedButton(
                              onPressed:
                                  sasVerified ? () => _respondToClaim(claim, true) : null,
                              child: const Text('Approve'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: () => _respondToClaim(claim, false),
                              child: const Text('Reject'),
                            ),
                            if (claim.transferId.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: () => _downloadManifest(claim),
                                child: const Text('Fetch Manifest'),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
              if (_pendingClaims.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(_manifestStatus),
              ],
            ],
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              'Send Session',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('Send Files'),
                  selected: !_sendTextMode,
                  onSelected: (value) {
                    setState(() {
                      _sendTextMode = !value;
                    });
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Send Text'),
                  selected: _sendTextMode,
                  onSelected: (value) {
                    setState(() {
                      _sendTextMode = value;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_sendTextMode) ...[
              TextField(
                controller: _textTitleController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Title (optional)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _textContentController,
                maxLines: 4,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Text to send',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton(
                    onPressed: _pasteFromClipboard,
                    child: const Text('Paste from Clipboard'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _senderTransferToken == null || !_senderSasConfirmed
                        ? null
                        : _sendText,
                    child: const Text('Send Text'),
                  ),
                ],
              ),
            ],
            if (!_sendTextMode) ...[
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
            if (_scanRequired) Text('Scan required (${_scanStatus.isEmpty ? 'pending' : _scanStatus})'),
            if (_claimId != null) ...[
              Text('SAS: ${_senderSasCode ?? 'waiting for keys'}'),
              Text('SAS state: $_senderSasState'),
              const SizedBox(height: 4),
              ElevatedButton(
                onPressed: _senderSasCode == null ||
                        _senderSasConfirmed ||
                        _senderSasConfirming
                    ? null
                    : _confirmSenderSas,
                child: Text(
                  _senderSasConfirming
                      ? 'Confirming...'
                      : _senderSasConfirmed
                          ? 'SAS confirmed'
                          : 'Confirm SAS',
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                DropdownButton<String>(
                  value: _packagingMode,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _packagingMode = value;
                      if (_packagingMode != packagingModeOriginals &&
                          _packageTitleController.text.trim().isEmpty) {
                        _packageTitleController.text = _defaultPackageTitle();
                      }
                    });
                  },
                  items: const [
                    DropdownMenuItem(
                      value: packagingModeOriginals,
                      child: Text('Originals'),
                    ),
                    DropdownMenuItem(
                      value: packagingModeZip,
                      child: Text('ZIP'),
                    ),
                    DropdownMenuItem(
                      value: packagingModeAlbum,
                      child: Text('Album'),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _pickFiles,
                  child: const Text('Select Files'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _pickMedia,
                  child: const Text('Select Photos'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _senderTransferToken == null || !_senderSasConfirmed
                      ? null
                      : _startQueue,
                  child: const Text('Start Queue'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _coordinator?.isRunning == true ? _pauseQueue : null,
                  child: const Text('Pause'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _coordinator?.isPaused == true ? _resumeQueue : null,
                  child: const Text('Resume'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_selectedFiles.isNotEmpty) ...[
              if (_packagingMode != packagingModeOriginals) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _packageTitleController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Package title',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const Text('Queue'),
              const SizedBox(height: 8),
              ..._selectedFiles.map((file) {
                final state = _transferStates[file.id];
                final status = state?.status ?? statusQueued;
                final progress = state == null || state.totalBytes == 0
                    ? 0.0
                    : _progressForState(state);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(file.name)),
                      Text(status),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 120,
                        child: LinearProgressIndicator(value: progress),
                      ),
                    ],
                  ),
                );
              }),
            ],
            ],
            if (_receivedText.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Received text'),
              const SizedBox(height: 8),
              SelectableText(_receivedText),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => copyToClipboard(
                  widget.clipboardService,
                  _receivedText,
                ),
                child: const Text('Copy to Clipboard'),
              ),
            ],
            if (_saveStatus.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_saveStatus),
              if (_lastSavedPath != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () => _saveService.openIn(_lastSavedPath!),
                      child: const Text('Open in…'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => _saveService.saveAs(
                        _lastSavedPath!,
                        _suggestedExportName(),
                      ),
                      child: const Text('Save As…'),
                    ),
                    if (_lastSaveIsMedia) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () async {
                          final path = _lastSavedPath!;
                          final bytes = await File(path).readAsBytes();
                          final outcome = await _saveService.saveBytes(
                            bytes: bytes,
                            name: _suggestedExportName(),
                            mime: _lastSavedMime ?? 'application/octet-stream',
                            isMedia: true,
                            destination: SaveDestination.photos,
                          );
                          setState(() {
                            _saveStatus = outcome.success
                                ? 'Saved to Photos.'
                                : 'Save to Photos failed.';
                          });
                        },
                        child: const Text('Save to Photos'),
                      ),
                    ],
                  ],
                ),
              ],
              if (_lastManifest?.packagingMode == packagingModeZip &&
                  _lastZipBytes != null) ...[
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _extracting ? null : _extractZip,
                  child:
                      Text(_extracting ? 'Extracting...' : 'Extract ZIP'),
                ),
                if (_extractProgress != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Extracted ${_extractProgress!.filesExtracted}/${_extractProgress!.totalFiles} files',
                  ),
                ],
                if (_extractStatus.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_extractStatus),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

double _progressForState(TransferState state) {
  if (state.chunkSize <= 0) {
    return 0.0;
  }
  final chunks =
      (state.totalBytes + state.chunkSize - 1) ~/ state.chunkSize;
  final totalEncrypted = state.totalBytes + (chunks * 28);
  if (totalEncrypted == 0) {
    return 0.0;
  }
  return (state.nextOffset / totalEncrypted).clamp(0.0, 1.0);
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
    required this.senderPubKeyB64,
    required this.transferId,
    required this.scanRequired,
    required this.scanStatus,
    required this.sasState,
  });

  final String claimId;
  final String senderLabel;
  final String shortFingerprint;
  final String senderPubKeyB64;
  final String transferId;
  final bool scanRequired;
  final String scanStatus;
  final String sasState;

  factory PendingClaim.fromJson(Map<String, dynamic> json) {
    return PendingClaim(
      claimId: json['claim_id']?.toString() ?? '',
      senderLabel: json['sender_label']?.toString() ?? '',
      shortFingerprint: json['short_fingerprint']?.toString() ?? '',
      senderPubKeyB64: json['sender_pubkey_b64']?.toString() ?? '',
      transferId: json['transfer_id']?.toString() ?? '',
      scanRequired: json['scan_required'] == true,
      scanStatus: json['scan_status']?.toString() ?? '',
      sasState: json['sas_state']?.toString() ?? 'pending',
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

String _randomId() {
  final bytes = Uint8List(18);
  final random = Random.secure();
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return base64UrlEncode(bytes).replaceAll('=', '');
}
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:universaldrop_app/models/destination_preferences.dart';
import 'package:universaldrop_app/models/destination_rules.dart';
import 'package:universaldrop_app/models/transfer_manifest.dart';
import 'package:universaldrop_app/services/clipboard_service.dart';
import 'package:universaldrop_app/services/destination_selector.dart';
import 'package:universaldrop_app/services/key_store.dart';
import 'package:universaldrop_app/services/save_service.dart';
import 'package:universaldrop_app/services/trust_store.dart';
import 'package:universaldrop_app/services/zip_extract.dart';
import 'package:universaldrop_app/transfer/crypto.dart';
import 'package:universaldrop_app/transfer/packaging_builder.dart';
import 'package:universaldrop_app/transfer/background_transfer.dart';
import 'package:universaldrop_app/transfer/transfer_coordinator.dart';
import 'package:universaldrop_app/transfer/transfer_state_store.dart';
import 'package:universaldrop_app/transfer/transport.dart';
import 'package:universaldrop_app/ui/diagnostics_screen.dart';
import 'package:universaldrop_app/ui/trusted_device_badge.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    ClipboardService? clipboardService,
    this.saveService,
    this.destinationStore,
    this.onTransportSelected,
    this.runStartupTasks = true,
  }) : clipboardService = clipboardService ?? const SystemClipboardService();

  final ClipboardService clipboardService;
  final SaveService? saveService;
  final DestinationPreferenceStore? destinationStore;
  final void Function(Transport transport)? onTransportSelected;
  final bool runStartupTasks;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _baseUrlController =
      TextEditingController(text: 'http://localhost:8080');
  String _status = 'Idle';
  bool _loading = false;
  bool _creatingSession = false;
  String _sessionStatus = 'No session created yet.';
  SessionCreateResponse? _sessionResponse;
  KeyPair? _receiverKeyPair;
  final Map<String, String> _senderPubKeysByClaim = {};
  final Map<String, String> _transferTokensByClaim = {};
  String _manifestStatus = 'No manifest downloaded.';
  final Map<String, TransferState> _transferStates = {};
  final List<TransferFile> _selectedFiles = [];
  TransferCoordinator? _coordinator;
  late final SecureTransferStateStore _transferStore =
      SecureTransferStateStore();
  final SecureKeyPairStore _keyStore = SecureKeyPairStore();
  final BackgroundTransferApi _backgroundTransfer = BackgroundTransferApiImpl();
  final DownloadTokenStore _downloadTokenStore = DownloadTokenStore();
  late final DestinationPreferenceStore _destinationStore;
  late final SaveService _saveService;
  late final DestinationSelector _destinationSelector;
  final TrustStore _trustStore = const TrustStore();
  final TextEditingController _textTitleController = TextEditingController();
  final TextEditingController _textContentController = TextEditingController();
  bool _sendTextMode = false;
  String _receivedText = '';
  String _saveStatus = '';
  String? _lastSavedPath;
  bool _lastSaveIsMedia = false;
  String? _lastSavedMime;
  String _packagingMode = packagingModeOriginals;
  final TextEditingController _packageTitleController = TextEditingController();
  Uint8List? _lastZipBytes;
  TransferManifest? _lastManifest;
  bool _extracting = false;
  ExtractProgress? _extractProgress;
  String _extractStatus = '';
  String? _claimId;
  String? _claimStatus;
  String? _senderSessionId;
  String? _senderReceiverPubKeyB64;
  String? _senderTransferToken;
  String? _senderP2PToken;
  String? _senderSasCode;
  String _senderSasState = '';
  bool _senderSasConfirmed = false;
  bool _senderSasConfirming = false;
  bool _scanRequired = false;
  String _scanStatus = '';
  Timer? _pollTimer;
  bool _refreshingClaims = false;
  String _claimsStatus = 'No pending claims.';
  List<PendingClaim> _pendingClaims = [];
  final Map<String, String> _p2pTokensByClaim = {};
  bool _preferDirect = true;
  bool _alwaysRelay = false;
  bool _p2pDisclosureShown = false;
  bool _experimentalDisclosureShown = false;
  bool _preferBackgroundDownloads = false;
  bool _showNotificationDetails = false;
  bool _isForeground = true;
  final Set<String> _trustedFingerprints = {};
  final Map<String, String> _receiverSasByClaim = {};
  final Set<String> _receiverSasConfirming = {};

  static const _p2pPreferDirectKey = 'p2pPreferDirect';
  static const _p2pAlwaysRelayKey = 'p2pAlwaysRelay';
  static const _p2pDisclosureKey = 'p2pDirectDisclosureShown';
  static const _experimentalDisclosureKey = 'experimentalDisclosureShown';
  static const _preferBackgroundDownloadsKey = 'preferBackgroundDownloads';
  static const _notificationDetailsKey =
      'showNotificationDetailsInNotifications';

  final TextEditingController _qrPayloadController = TextEditingController();
  final TextEditingController _sessionIdController = TextEditingController();
  final TextEditingController _claimTokenController = TextEditingController();
  final TextEditingController _senderLabelController = TextEditingController();
  bool _sending = false;
  String _sendStatus = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _destinationStore =
        widget.destinationStore ?? SharedPreferencesDestinationStore();
    _saveService = widget.saveService ?? DefaultSaveService();
    _destinationSelector = DestinationSelector(_destinationStore);
    if (widget.runStartupTasks) {
      _loadSettings();
      _resumePendingTransfers();
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _qrPayloadController.dispose();
    _sessionIdController.dispose();
    _claimTokenController.dispose();
    _senderLabelController.dispose();
    _textTitleController.dispose();
    _textContentController.dispose();
    _packageTitleController.dispose();
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    if (isForeground == _isForeground) {
      return;
    }
    if (!mounted) {
      _isForeground = isForeground;
      return;
    }
    setState(() {
      _isForeground = isForeground;
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final preferDirect = prefs.getBool(_p2pPreferDirectKey) ?? true;
    final alwaysRelay = prefs.getBool(_p2pAlwaysRelayKey) ?? false;
    final disclosureShown = prefs.getBool(_p2pDisclosureKey) ?? false;
    final experimentalDisclosureShown =
        prefs.getBool(_experimentalDisclosureKey) ?? false;
    final preferBackgroundDownloads =
        prefs.getBool(_preferBackgroundDownloadsKey) ?? false;
    final showNotificationDetails =
        prefs.getBool(_notificationDetailsKey) ?? false;
    final trustedFingerprints = await _trustStore.loadFingerprints();
    if (!mounted) {
      return;
    }
    setState(() {
      _preferDirect = preferDirect;
      _alwaysRelay = alwaysRelay;
      _p2pDisclosureShown = disclosureShown;
      _experimentalDisclosureShown = experimentalDisclosureShown;
      _preferBackgroundDownloads = preferBackgroundDownloads;
      _showNotificationDetails = showNotificationDetails;
      _trustedFingerprints
        ..clear()
        ..addAll(trustedFingerprints);
    });
  }

  Future<void> _persistP2PSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_p2pPreferDirectKey, _preferDirect);
    await prefs.setBool(_p2pAlwaysRelayKey, _alwaysRelay);
  }

  Future<void> _setPreferDirect(bool value) async {
    if (value) {
      await _maybeShowDirectDisclosure();
    }
    setState(() {
      _preferDirect = value;
      if (!value) {
        _alwaysRelay = false;
      }
    });
    await _persistP2PSettings();
  }

  Future<void> _setAlwaysRelay(bool value) async {
    if (!_preferDirect) {
      return;
    }
    setState(() {
      _alwaysRelay = value;
    });
    await _persistP2PSettings();
  }

  Future<void> _setPreferBackgroundDownloads(bool value) async {
    if (value) {
      await _maybeShowExperimentalDisclosure();
    }
    setState(() {
      _preferBackgroundDownloads = value;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_preferBackgroundDownloadsKey, value);
  }

  Future<void> _setNotificationDetails(bool value) async {
    setState(() {
      _showNotificationDetails = value;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationDetailsKey, value);
  }

  Future<void> _maybeShowDirectDisclosure() async {
    if (_p2pDisclosureShown || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Direct transfer disclosure'),
          content: const Text(
            'Direct transfer may reveal IP address to the other device. '
            'Use "Always relay" to avoid direct exposure.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_p2pDisclosureKey, true);
    if (!mounted) {
      return;
    }
    setState(() {
      _p2pDisclosureShown = true;
    });
  }

  Future<void> _maybeShowExperimentalDisclosure() async {
    if (_experimentalDisclosureShown || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Experimental features'),
          content: const Text(
            'May not be available on all devices. If unavailable, '
            'CipherLink uses standard mode.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_experimentalDisclosureKey, true);
    if (!mounted) {
      return;
    }
    setState(() {
      _experimentalDisclosureShown = true;
    });
  }

  Future<void> _addTrustedFingerprint(String fingerprint) async {
    final updated = await _trustStore.addFingerprint(fingerprint);
    if (!mounted) {
      return;
    }
    setState(() {
      _trustedFingerprints
        ..clear()
        ..addAll(updated);
    });
  }

  Future<void> _removeTrustedFingerprint(String fingerprint) async {
    final updated = await _trustStore.removeFingerprint(fingerprint);
    if (!mounted) {
      return;
    }
    setState(() {
      _trustedFingerprints
        ..clear()
        ..addAll(updated);
    });
  }

  String _formatFingerprint(String fingerprint) {
    final trimmed = fingerprint.trim();
    if (trimmed.length <= 12) {
      return trimmed;
    }
    return '${trimmed.substring(0, 6)}...${trimmed.substring(trimmed.length - 4)}';
  }

  List<Widget> _buildTrustedDevicesSection() {
    final entries = _trustedFingerprints.toList()..sort();
    if (entries.isEmpty) {
      return const [
        Text(
          'Trusted devices',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 8),
        Text('No trusted devices yet.'),
      ];
    }
    return [
      const Text(
        'Trusted devices',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      ...entries.map((fingerprint) {
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_formatFingerprint(fingerprint)),
          trailing: IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              _removeTrustedFingerprint(fingerprint);
            },
          ),
        );
      }),
    ];
  }

  void _openDiagnostics() {
    final baseUrl = _baseUrlController.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DiagnosticsScreen(baseUrl: baseUrl),
      ),
    );
  }

  void _ensureCoordinator() {
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      return;
    }
    final baseUri = Uri.parse(baseUrl);
    final transport = HttpTransport(baseUri);
    widget.onTransportSelected?.call(transport);
    _coordinator = TransferCoordinator(
      transport: transport,
      baseUri: baseUri,
      p2pTransportFactory: (context) => P2PTransport(
        baseUri: baseUri,
        context: context,
        fallbackTransport: transport,
      ),
      store: _transferStore,
      onState: (state) {
        setState(() {
          _transferStates[state.transferId] = state;
        });
      },
      onScanStatus: (transferId, status) {
        setState(() {
          _scanStatus = status;
        });
      },
      backgroundTransfer: _backgroundTransfer,
      downloadTokenStore: _downloadTokenStore,
      saveHandler: _handleTransferSave,
      downloadResolver: _resolveDownloadResumeContext,
    );
  }

  TransferDownloadPolicy _downloadPolicy() {
    return TransferDownloadPolicy(
      preferBackground: _preferBackgroundDownloads,
      showNotificationDetails: _showNotificationDetails,
      destinationResolver: _resolveBackgroundDestination,
      isAppInForeground: () => _isForeground,
    );
  }

  Future<SaveDestination?> _resolveBackgroundDestination(
    TransferManifest manifest,
    bool allowPrompt,
  ) async {
    if (allowPrompt && mounted) {
      final defaultDestination =
          await _destinationSelector.defaultDestination(manifest);
      final choice = await _showDestinationSelector(
        defaultDestination,
        isMediaManifest(manifest),
      );
      if (choice == null) {
        return null;
      }
      await _destinationSelector.rememberChoice(manifest, choice);
      return choice.destination;
    }
    final prefs = await _destinationStore.load();
    if (isMediaManifest(manifest)) {
      return prefs.defaultMediaDestination ?? SaveDestination.files;
    }
    return prefs.defaultFileDestination ?? SaveDestination.files;
  }

  SaveDestination? _destinationFromState(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    for (final destination in SaveDestination.values) {
      if (destination.name == value) {
        return destination;
      }
    }
    return null;
  }

  Future<TransferSaveResult> _handleTransferSave(
    TransferManifest manifest,
    Uint8List bytes,
    TransferState state,
  ) async {
    final destination = _destinationFromState(state.destination) ??
        await _resolveBackgroundDestination(manifest, false) ??
        SaveDestination.files;

    if (manifest.payloadKind == payloadKindText) {
      final text = utf8.decode(bytes);
      if (mounted) {
        setState(() {
          _receivedText = text;
          _manifestStatus = 'Text received.';
          _saveStatus = 'Ready to copy.';
        });
      } else {
        _receivedText = text;
      }
      return const TransferSaveResult(shouldSendReceipt: true);
    }

    if (manifest.packagingMode == packagingModeAlbum) {
      final outcome = await _saveAlbumPayload(
        bytes: bytes,
        manifest: manifest,
        destination: destination,
        allowUserInteraction: false,
      );
      if (mounted) {
        setState(() {
          _manifestStatus =
              'Album: ${manifest.albumItemCount ?? manifest.files.length} items';
          _saveStatus =
              outcome.success ? 'Album saved.' : 'Album saved with fallback.';
        });
      }
      return TransferSaveResult(
        shouldSendReceipt: outcome.success || outcome.localPath != null,
        localPath: outcome.localPath,
      );
    }

    _lastManifest = manifest;
    _extractStatus = '';
    _extractProgress = null;
    if (manifest.packagingMode == packagingModeZip) {
      _lastZipBytes = bytes;
    } else {
      _lastZipBytes = null;
    }
    final fileName = _suggestFileName(manifest);
    final mime = _suggestMime(manifest);
    final isMedia = isMediaManifest(manifest);
    final outcome = await _saveService.saveBytes(
      bytes: bytes,
      name: fileName,
      mime: mime,
      isMedia: isMedia,
      destination: destination,
      allowUserInteraction: false,
    );
    _lastSavedPath = outcome.localPath;
    _lastSaveIsMedia = isMedia;
    _lastSavedMime = mime;
    if (mounted) {
      setState(() {
        if (manifest.packagingMode == packagingModeZip) {
          _manifestStatus = 'ZIP: ${manifest.outputFilename ?? fileName}';
        } else if (manifest.files.isNotEmpty) {
          _manifestStatus = 'File: ${manifest.files.first.relativePath}';
        } else {
          _manifestStatus = 'Downloaded ${bytes.length} bytes.';
        }
        _saveStatus = outcome.success ? 'Saved.' : 'Saved locally with fallback.';
      });
    }
    return TransferSaveResult(
      shouldSendReceipt: outcome.success || outcome.localPath != null,
      localPath: outcome.localPath,
    );
  }

  Future<void> _resumePendingTransfers() async {
    _ensureCoordinator();
    final coordinator = _coordinator;
    if (coordinator == null) {
      return;
    }
    await coordinator.resumePendingDownloads(
      resolve: _resolveDownloadResumeContext,
      downloadPolicy: _downloadPolicy(),
    );
    await coordinator.resumePendingUploads(
      resolve: _resolveUploadResumeContext,
    );
  }

  Future<DownloadResumeContext?> _resolveDownloadResumeContext(
    TransferState state,
  ) async {
    if (state.sessionId.isEmpty ||
        state.transferToken.isEmpty ||
        state.transferId.isEmpty) {
      return null;
    }
    final senderPubKeyB64 = state.peerPublicKeyB64 ?? '';
    if (senderPubKeyB64.isEmpty) {
      return null;
    }
    final receiverKeyPair = await _keyStore.loadKeyPair(
      sessionId: state.sessionId,
      role: KeyRole.receiver,
    );
    if (receiverKeyPair == null) {
      return null;
    }
    return DownloadResumeContext(
      sessionId: state.sessionId,
      transferToken: state.transferToken,
      transferId: state.transferId,
      senderPublicKey: publicKeyFromBase64(senderPubKeyB64),
      receiverKeyPair: receiverKeyPair,
    );
  }

  Future<UploadResumeContext?> _resolveUploadResumeContext(
    TransferState state,
  ) async {
    if (state.sessionId.isEmpty ||
        state.transferToken.isEmpty ||
        state.transferId.isEmpty) {
      return null;
    }
    final payloadPath = state.payloadPath ?? '';
    if (payloadPath.isEmpty) {
      return null;
    }
    final payloadFile = File(payloadPath);
    if (!await payloadFile.exists()) {
      return null;
    }
    final senderKeyPair = await _keyStore.loadKeyPair(
      sessionId: state.sessionId,
      role: KeyRole.sender,
    );
    if (senderKeyPair == null) {
      return null;
    }
    final receiverPubKeyB64 = state.peerPublicKeyB64 ?? '';
    if (receiverPubKeyB64.isEmpty) {
      return null;
    }
    final bytes = await payloadFile.readAsBytes();
    final transferFile = TransferFile(
      id: state.transferId,
      name: p.basename(payloadPath),
      bytes: bytes,
      payloadKind: payloadKindFile,
      mimeType: 'application/octet-stream',
      packagingMode: packagingModeOriginals,
      localPath: payloadPath,
    );
    return UploadResumeContext(
      file: transferFile,
      sessionId: state.sessionId,
      transferToken: state.transferToken,
      receiverPublicKey: publicKeyFromBase64(receiverPubKeyB64),
      senderKeyPair: senderKeyPair,
      chunkSize: state.chunkSize,
      scanRequired: state.scanRequired ?? false,
      transferId: state.transferId,
    );
  }

  P2PContext? _buildP2PContext({
    required String sessionId,
    required String claimId,
    required String token,
    required bool isInitiator,
  }) {
    if (!_preferDirect) {
      return null;
    }
    if (sessionId.isEmpty || claimId.isEmpty || token.isEmpty) {
      return null;
    }
    return P2PContext(
      sessionId: sessionId,
      claimId: claimId,
      token: token,
      isInitiator: isInitiator,
      iceMode: _alwaysRelay ? P2PIceMode.relay : P2PIceMode.direct,
    );
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
      final response =
          await http.get(baseUri.resolve('/v1/ping')).timeout(
                const Duration(seconds: 5),
              );
      if (response.statusCode == 200) {
        setState(() {
          _status = 'Ping ok.';
        });
      } else {
        setState(() {
          _status = 'Ping failed: ${response.statusCode}.';
        });
      }
    } catch (err) {
      setState(() {
        _status = 'Ping error: $err';
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
        _status = 'Enter a base URL first.';
      });
      return;
    }
    setState(() {
      _creatingSession = true;
      _status = 'Creating session...';
    });
    try {
      final baseUri = Uri.parse(baseUrl);
      final keyPair = await X25519().newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final pubKeyB64 = base64UrlEncode(publicKey.bytes);
      final response = await http
          .post(
            baseUri.resolve('/v1/session/create'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'receiver_pubkey_b64': pubKeyB64}),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        setState(() {
          _status = 'Create session failed: ${response.statusCode}';
        });
        return;
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final sessionResponse = SessionCreateResponse.fromJson(payload);
      final sessionId = sessionResponse.sessionId;
      if (sessionId.isEmpty) {
        setState(() {
          _status = 'Create session failed: invalid response.';
        });
        return;
      }
      final saved = await _keyStore.trySaveKeyPair(
        sessionId: sessionId,
        role: KeyRole.receiver,
        keyPair: keyPair,
      );
      if (!saved) {
        setState(() {
          _status = 'Secure storage unavailable. Session not saved.';
        });
        return;
      }
      setState(() {
        _receiverKeyPair = keyPair;
        _sessionResponse = sessionResponse;
        _sessionStatus = 'Session created.';
        _claimsStatus = 'Session created. Refresh to load claims.';
        _pendingClaims = [];
        _receiverSasByClaim.clear();
      });
    } catch (err) {
      setState(() {
        _status = 'Create session failed: $err';
      });
    } finally {
      setState(() {
        _creatingSession = false;
      });
    }
  }

  Future<void> _refreshClaims() async {
    final response = _sessionResponse;
    final keyPair = _receiverKeyPair;
    if (response == null || keyPair == null) {
      return;
    }
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      return;
    }
    setState(() {
      _refreshingClaims = true;
      _claimsStatus = 'Refreshing...';
    });
    try {
      final baseUri = Uri.parse(baseUrl);
      final uri = baseUri.replace(
        path: '/v1/session/claims',
        queryParameters: {
          'session_id': response.sessionId,
          'claim_token': response.claimToken,
        },
      );
      final result = await http.get(uri).timeout(const Duration(seconds: 5));
      if (result.statusCode != 200) {
        setState(() {
          _claimsStatus = 'Refresh failed: ${result.statusCode}';
        });
        return;
      }
      final payload = jsonDecode(result.body) as Map<String, dynamic>;
      final claims = payload['claims'];
      if (claims is! List) {
        setState(() {
          _claimsStatus = 'No pending claims.';
          _pendingClaims = [];
        });
        return;
      }
      final parsed = claims
          .map((item) => PendingClaim.fromJson(item as Map<String, dynamic>))
          .toList();
      await _updateReceiverSasCodes(parsed);
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingClaims = parsed;
        _claimsStatus = parsed.isEmpty ? 'No pending claims.' : '';
      });
    } catch (err) {
      setState(() {
        _claimsStatus = 'Refresh failed: $err';
      });
    } finally {
      setState(() {
        _refreshingClaims = false;
      });
    }
  }

  Future<void> _updateReceiverSasCodes(List<PendingClaim> claims) async {
    final receiverKeyPair = _receiverKeyPair;
    if (receiverKeyPair == null) {
      return;
    }
    final updates = <String, String>{};
    for (final claim in claims) {
      if (_receiverSasByClaim.containsKey(claim.claimId)) {
        continue;
      }
      if (claim.senderPubKeyB64.isEmpty ||
          claim.senderPubKeyB64.length < 4) {
        continue;
      }
      try {
        final senderPubKey = publicKeyFromBase64(claim.senderPubKeyB64);
        final sas = await deriveSASCode(
          localKeyPair: receiverKeyPair,
          peerPublicKey: senderPubKey,
          sessionId: _sessionResponse?.sessionId ?? '',
          role: 'receiver',
        );
        updates[claim.claimId] = sas;
      } catch (_) {}
    }
    if (updates.isEmpty || !mounted) {
      return;
    }
    setState(() {
      _receiverSasByClaim.addAll(updates);
    });
  }

  Future<void> _respondToClaim(PendingClaim claim, bool approve) async {
    final response = _sessionResponse;
    if (response == null) {
      return;
    }
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      return;
    }
    final baseUri = Uri.parse(baseUrl);
    final uri = baseUri.resolve('/v1/session/approve');
    try {
      final result = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'session_id': response.sessionId,
          'claim_id': claim.claimId,
          'approve': approve,
        }),
      );
      if (result.statusCode != 200) {
        setState(() {
          _status = 'Approve failed: ${result.statusCode}';
        });
        return;
      }
      final payload = jsonDecode(result.body) as Map<String, dynamic>;
      if (approve) {
        final transferToken = payload['transfer_token']?.toString() ?? '';
        final p2pToken = payload['p2p_token']?.toString() ?? '';
        final senderPubKey = payload['sender_pubkey_b64']?.toString() ?? '';
        if (transferToken.isNotEmpty) {
          _transferTokensByClaim[claim.claimId] = transferToken;
        }
        if (p2pToken.isNotEmpty) {
          _p2pTokensByClaim[claim.claimId] = p2pToken;
        }
        if (senderPubKey.isNotEmpty) {
          _senderPubKeysByClaim[claim.claimId] = senderPubKey;
        }
      }
      await _refreshClaims();
    } catch (err) {
      setState(() {
        _status = 'Approve failed: $err';
      });
    }
  }

  Future<bool> _commitSas({
    required String sessionId,
    required String claimId,
    required String role,
  }) async {
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      return false;
    }
    final baseUri = Uri.parse(baseUrl);
    final uri = baseUri.resolve('/v1/session/sas/commit');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'session_id': sessionId,
        'claim_id': claimId,
        'role': role,
        'sas_confirmed': true,
      }),
    );
    return response.statusCode == 200;
  }

  Future<void> _confirmReceiverSas(PendingClaim claim) async {
    final response = _sessionResponse;
    if (response == null) {
      return;
    }
    final code = _receiverSasByClaim[claim.claimId];
    if (code == null || code.isEmpty) {
      return;
    }
    setState(() {
      _receiverSasConfirming.add(claim.claimId);
    });
    try {
      final ok = await _commitSas(
        sessionId: response.sessionId,
        claimId: claim.claimId,
        role: 'receiver',
      );
      if (!ok) {
        setState(() {
          _status = 'SAS commit failed.';
        });
        return;
      }
      await _refreshClaims();
    } catch (err) {
      setState(() {
        _status = 'SAS commit failed: $err';
      });
    } finally {
      if (mounted) {
        setState(() {
          _receiverSasConfirming.remove(claim.claimId);
        });
      }
    }
  }

  Future<void> _confirmSenderSas() async {
    if (_senderSasConfirmed || _senderSasConfirming) {
      return;
    }
    final sessionId = _senderSessionId ?? '';
    final claimId = _claimId ?? '';
    if (sessionId.isEmpty || claimId.isEmpty) {
      setState(() {
        _sendStatus = 'Claim a session first.';
      });
      return;
    }
    setState(() {
      _senderSasConfirming = true;
    });
    try {
      final ok = await _commitSas(
        sessionId: sessionId,
        claimId: claimId,
        role: 'sender',
      );
      if (!ok) {
        setState(() {
          _sendStatus = 'SAS commit failed.';
        });
        return;
      }
      setState(() {
        _senderSasConfirmed = true;
        _senderSasState = 'sender_confirmed';
      });
    } catch (err) {
      setState(() {
        _sendStatus = 'SAS commit failed: $err';
      });
    } finally {
      setState(() {
        _senderSasConfirming = false;
      });
    }
  }

  Future<void> _updateSenderSasCode() async {
    if (_senderSasConfirmed || _senderSasConfirming) {
      return;
    }
    if (_senderSessionId == null ||
        _senderTransferToken == null ||
        _senderKeyPair == null ||
        _senderReceiverPubKeyB64 == null ||
        _senderReceiverPubKeyB64!.isEmpty) {
      return;
    }
    try {
      _senderSasConfirming = true;
      final receiverPubKey = publicKeyFromBase64(_senderReceiverPubKeyB64!);
      final sas = await deriveSASCode(
        localKeyPair: _senderKeyPair!,
        peerPublicKey: receiverPubKey,
        sessionId: _senderSessionId!,
        role: 'sender',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _senderSasCode = sas;
      });
    } catch (_) {} finally {
      _senderSasConfirming = false;
    }
  }

  Future<bool?> _promptScanChoice() {
    if (!mounted) {
      return Future.value(null);
    }
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Scan required'),
          content: const Text(
            'This transfer requires a malware scan before delivery. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _downloadManifest(PendingClaim claim) async {
    final baseUrl = _baseUrlController.text.trim();
    final sessionId = _sessionResponse?.sessionId ?? '';
    final transferToken = _transferTokensByClaim[claim.claimId] ?? '';
    final senderPubKeyB64 = _senderPubKeysByClaim[claim.claimId] ?? '';
    if (baseUrl.isEmpty || sessionId.isEmpty) {
      setState(() {
        _manifestStatus = 'Create a session first.';
      });
      return;
    }
    if (claim.transferId.isEmpty) {
      setState(() {
        _manifestStatus = 'No transfer ID yet.';
      });
      return;
    }
    if (transferToken.isEmpty ||
        senderPubKeyB64.isEmpty ||
        _receiverKeyPair == null) {
      setState(() {
        _manifestStatus = 'Missing auth context or keys.';
      });
      return;
    }
    if (_preferDirect) {
      await _maybeShowDirectDisclosure();
    }
    final p2pToken = _p2pTokensByClaim[claim.claimId] ?? transferToken;
    final p2pContext = _buildP2PContext(
      sessionId: sessionId,
      claimId: claim.claimId,
      token: p2pToken,
      isInitiator: false,
    );
    setState(() {
      _manifestStatus = 'Downloading manifest...';
    });
    try {
      _ensureCoordinator();
      final coordinator = _coordinator;
      if (coordinator == null) {
        setState(() {
          _manifestStatus = 'Invalid base URL.';
        });
        return;
      }
      final senderPublicKey = publicKeyFromBase64(senderPubKeyB64);
      final result = await coordinator.downloadTransfer(
        sessionId: sessionId,
        transferToken: transferToken,
        transferId: claim.transferId,
        senderPublicKey: senderPublicKey,
        receiverKeyPair: _receiverKeyPair!,
        sendReceipt: false,
        p2pContext: p2pContext,
        downloadPolicy: _downloadPolicy(),
      );
      if (result == null) {
        final pending = await _transferStore.load(claim.transferId);
        if (!mounted) {
          return;
        }
        setState(() {
          if (pending?.backgroundTaskId?.isNotEmpty == true) {
            _manifestStatus = 'Download running in background.';
          } else if (pending?.requiresForegroundResume == true) {
            _manifestStatus = 'Download paused. Resume in foreground.';
          } else {
            _manifestStatus = 'Download paused or failed.';
          }
        });
        return;
      }
      final manifest = result.manifest;
      _lastManifest = manifest;
      _extractStatus = '';
      _extractProgress = null;
      if (manifest.packagingMode != packagingModeZip) {
        _lastZipBytes = null;
      }
      if (manifest.payloadKind == payloadKindText) {
        final text = utf8.decode(result.bytes);
        setState(() {
          _receivedText = text;
          _manifestStatus = 'Text received.';
          _saveStatus = 'Ready to copy.';
        });
        await coordinator.sendReceipt(
          sessionId: sessionId,
          transferId: result.transferId,
          transferToken: transferToken,
        );
        return;
      }

      final defaultDestination =
          await _destinationSelector.defaultDestination(manifest);
      final choice = await _showDestinationSelector(
        defaultDestination,
        isMediaManifest(manifest),
      );
      if (choice == null) {
        setState(() {
          _manifestStatus = 'Save cancelled.';
        });
        return;
      }
      await _destinationSelector.rememberChoice(manifest, choice);

      if (manifest.packagingMode == packagingModeAlbum) {
        final outcome = await _saveAlbumPayload(
          bytes: result.bytes,
          manifest: manifest,
          destination: choice.destination,
        );
        setState(() {
          _manifestStatus =
              'Album: ${manifest.albumItemCount ?? manifest.files.length} items';
          _saveStatus =
              outcome.success ? 'Album saved.' : 'Album saved with fallback.';
        });
        if (outcome.success || outcome.localPath != null) {
          await coordinator.sendReceipt(
            sessionId: sessionId,
            transferId: result.transferId,
            transferToken: transferToken,
          );
        }
        return;
      }

      if (manifest.packagingMode == packagingModeZip) {
        _lastZipBytes = result.bytes;
      }
      final fileName = _suggestFileName(manifest);
      final mime = _suggestMime(manifest);
      final isMedia = isMediaManifest(manifest);
      final outcome = await _saveService.saveBytes(
        bytes: result.bytes,
        name: fileName,
        mime: mime,
        isMedia: isMedia,
        destination: choice.destination,
      );
      _lastSavedPath = outcome.localPath;
      _lastSaveIsMedia = isMedia;
      _lastSavedMime = mime;
      setState(() {
        if (manifest.packagingMode == packagingModeZip) {
          _manifestStatus = 'ZIP: ${manifest.outputFilename ?? fileName}';
        } else if (manifest.files.isNotEmpty) {
          _manifestStatus = 'File: ${manifest.files.first.relativePath}';
        } else {
          _manifestStatus = 'Downloaded ${result.bytes.length} bytes.';
        }
        _saveStatus = outcome.success ? 'Saved.' : 'Saved locally with fallback.';
      });

      if (outcome.success || outcome.localPath != null) {
        await coordinator.sendReceipt(
          sessionId: sessionId,
          transferId: result.transferId,
          transferToken: transferToken,
        );
      }
    } catch (err) {
      setState(() {
        _manifestStatus = 'Manifest error: $err';
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
    });

    try {
      final keyPair = await X25519().newKeyPair();
      final pubKey = await keyPair.extractPublicKey();
      final pubKeyB64 = base64UrlEncode(pubKey.bytes);
      final baseUri = Uri.parse(baseUrl);
      final uri = baseUri.replace(path: '/v1/session/claim');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'session_id': sessionId,
              'claim_token': claimToken,
              'sender_label': senderLabel,
              'sender_pubkey_b64': pubKeyB64,
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        setState(() {
          _sendStatus = 'Claim failed: ${response.statusCode}';
        });
        return;
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final claimId = payload['claim_id']?.toString();
      if (claimId == null || claimId.isEmpty) {
        setState(() {
          _sendStatus = 'Claim failed: missing claim_id';
        });
        return;
      }
      setState(() {
        _claimId = claimId;
        _claimStatus = 'pending';
        _sendStatus = 'Claimed. Polling for approval...';
        _senderKeyPair = keyPair;
        _senderPubKeyB64 = pubKeyB64;
        _senderSessionId = sessionId;
        _senderReceiverPubKeyB64 = null;
        _senderTransferToken = null;
        _senderP2PToken = null;
        _senderSasCode = null;
        _senderSasState = 'pending';
        _senderSasConfirmed = false;
        _senderSasConfirming = false;
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

  Future<void> _sendText() async {
    if (_senderSessionId == null ||
        _senderTransferToken == null ||
        _senderReceiverPubKeyB64 == null ||
        _senderKeyPair == null) {
      setState(() {
        _sendStatus = 'Claim and wait for approval first.';
      });
      return;
    }
    if (_textContentController.text.trim().isEmpty) {
      setState(() {
        _sendStatus = 'Enter text first.';
      });
      return;
    }
    if (_preferDirect) {
      await _maybeShowDirectDisclosure();
    }

    _ensureCoordinator();
    final coordinator = _coordinator;
    if (coordinator == null) {
      setState(() {
        _sendStatus = 'Invalid base URL.';
      });
      return;
    }

    final text = _textContentController.text;
    final textBytes = Uint8List.fromList(utf8.encode(text));
    final id = _randomId();
    final localPath = await _cacheUploadPayload(id, textBytes);
    final payload = TransferFile(
      id: id,
      name: _textTitleController.text.trim().isEmpty
          ? 'Text'
          : _textTitleController.text.trim(),
      bytes: textBytes,
      payloadKind: payloadKindText,
      mimeType: textMimePlain,
      packagingMode: packagingModeOriginals,
      textTitle: _textTitleController.text.trim().isEmpty
          ? null
          : _textTitleController.text.trim(),
      localPath: localPath,
    );
    final p2pToken = _senderP2PToken ?? _senderTransferToken ?? '';
    final p2pContext = _buildP2PContext(
      sessionId: _senderSessionId!,
      claimId: _claimId ?? '',
      token: p2pToken,
      isInitiator: true,
    );

    coordinator.enqueueUploads(
      files: [payload],
      sessionId: _senderSessionId!,
      transferToken: _senderTransferToken!,
      receiverPublicKey: publicKeyFromBase64(_senderReceiverPubKeyB64!),
      senderKeyPair: _senderKeyPair!,
      chunkSize: 16 * 1024,
      scanRequired: _scanRequired,
      p2pContext: p2pContext,
    );
    setState(() {
      _sendStatus = 'Sending text...';
      _selectedFiles.clear();
    });
    await coordinator.runQueue();
  }

  Future<void> _pasteFromClipboard() async {
    final text = await widget.clipboardService.readText();
    if (text == null || text.isEmpty) {
      setState(() {
        _sendStatus = 'Clipboard empty.';
      });
      return;
    }
    setState(() {
      _textContentController.text = text;
    });
  }

  Future<DestinationChoice?> _showDestinationSelector(
    SaveDestination defaultDestination,
    bool isMedia,
  ) async {
    SaveDestination selected =
        isMedia ? defaultDestination : SaveDestination.files;
    bool remember = false;
    return showDialog<DestinationChoice>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Choose destination'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<SaveDestination>(
                    value: SaveDestination.photos,
                    groupValue: selected,
                    onChanged: isMedia
                        ? (value) {
                            if (value == null) return;
                            setState(() {
                              selected = value;
                            });
                          }
                        : null,
                    title: const Text('Save to Photos/Gallery'),
                  ),
                  RadioListTile<SaveDestination>(
                    value: SaveDestination.files,
                    groupValue: selected,
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        selected = value;
                      });
                    },
                    title: const Text('Save to Files'),
                  ),
                  Row(
                    children: [
                      Checkbox(
                        value: remember,
                        onChanged: (value) {
                          setState(() {
                            remember = value ?? false;
                          });
                        },
                      ),
                      const Text('Remember my choice'),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop(
                      DestinationChoice(
                        destination: selected,
                        remember: remember,
                      ),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<SaveOutcome> _saveAlbumPayload({
    required Uint8List bytes,
    required TransferManifest manifest,
    required SaveDestination destination,
    bool allowUserInteraction = true,
  }) async {
    final entries = decodeZipEntries(bytes);
    final fileMap = <String, TransferManifestFile>{};
    for (final entry in manifest.files) {
      fileMap[entry.relativePath] = entry;
    }

    SaveOutcome lastOutcome = SaveOutcome(
      success: false,
      usedFallback: false,
      savedToGallery: false,
    );
    for (final entry in entries) {
      if (!entry.isFile) {
        continue;
      }
      final name = entry.name;
      if (!name.startsWith('media/')) {
        continue;
      }
      final relativePath = name.substring('media/'.length);
      final metadata = fileMap[relativePath];
      final mime =
          metadata?.mime ?? lookupMimeType(relativePath) ?? 'application/octet-stream';
      final outcome = await _saveService.saveBytes(
        bytes: entry.bytes,
        name: relativePath,
        mime: mime,
        isMedia: true,
        destination: destination,
        allowUserInteraction: allowUserInteraction,
      );
      if (_lastSavedPath == null && outcome.localPath != null) {
        _lastSavedPath = outcome.localPath;
        _lastSaveIsMedia = true;
        _lastSavedMime = mime;
      }
      lastOutcome = outcome;
      if (!outcome.success && outcome.localPath == null) {
        return outcome;
      }
    }
    return lastOutcome;
  }

  Future<void> _extractZip() async {
    final zipBytes = _lastZipBytes;
    final manifest = _lastManifest;
    if (zipBytes == null || manifest == null) {
      return;
    }
    setState(() {
      _extracting = true;
      _extractStatus = 'Extracting...';
    });

    try {
      final destination = await getDirectoryPath();
      String destPath;
      if (destination == null) {
        final dir = await getApplicationDocumentsDirectory();
        destPath = p.join(dir.path, _defaultPackageTitle());
      } else {
        destPath = destination;
      }
      final result = await extractZipBytes(
        bytes: zipBytes,
        destinationDir: destPath,
        onProgress: (progress) {
          setState(() {
            _extractProgress = progress;
          });
        },
      );
      setState(() {
        _extractStatus = 'Extracted ${result.filesExtracted} files.';
      });
    } catch (err) {
      setState(() {
        if (err is ZipLimitException) {
          _extractStatus = err.message;
        } else {
          _extractStatus = 'Extraction failed.';
        }
      });
    } finally {
      setState(() {
        _extracting = false;
      });
    }
  }

  String _defaultPackageTitle() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return 'Package_${now.year}$month$day_$hour$minute';
  }

  String _suggestFileName(TransferManifest manifest) {
    if (manifest.packagingMode == packagingModeZip &&
        manifest.outputFilename != null &&
        manifest.outputFilename!.isNotEmpty) {
      return manifest.outputFilename!;
    }
    if (manifest.payloadKind == payloadKindText) {
      final title = manifest.textTitle?.trim();
      if (title != null && title.isNotEmpty) {
        return '$title.txt';
      }
      return 'text.txt';
    }
    if (manifest.files.isNotEmpty) {
      return manifest.files.first.relativePath;
    }
    return 'transfer.bin';
  }

  String _suggestMime(TransferManifest manifest) {
    if (manifest.payloadKind == payloadKindText) {
      return manifest.textMime ?? textMimePlain;
    }
    if (manifest.packagingMode == packagingModeZip) {
      return 'application/zip';
    }
    if (manifest.files.isNotEmpty) {
      return manifest.files.first.mime ?? 'application/octet-stream';
    }
    return 'application/octet-stream';
  }

  String _suggestedExportName() {
    if (_lastSavedPath == null) {
      return 'export.bin';
    }
    return _lastSavedPath!.split(Platform.pathSeparator).last;
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
      final transferToken = payload['transfer_token']?.toString();
      final p2pToken = payload['p2p_token']?.toString();
      final receiverPubKey = payload['receiver_pubkey_b64']?.toString();
      final scanRequired = payload['scan_required'] == true;
      final scanStatus = payload['scan_status']?.toString() ?? '';
      final sasState = payload['sas_state']?.toString() ?? 'pending';
      setState(() {
        _claimStatus = status;
        _sendStatus = 'Status: $status';
        if (receiverPubKey != null && receiverPubKey.isNotEmpty) {
          _senderReceiverPubKeyB64 = receiverPubKey;
        }
        if (transferToken != null && transferToken.isNotEmpty) {
          _senderTransferToken = transferToken;
        }
        if (p2pToken != null && p2pToken.isNotEmpty) {
          _senderP2PToken = p2pToken;
        }
        _scanRequired = scanRequired;
        _scanStatus = scanStatus;
        _senderSasState = sasState;
        if (sasState == 'sender_confirmed' || sasState == 'verified') {
          _senderSasConfirmed = true;
        }
      });
      await _updateSenderSasCode();

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

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) {
      return;
    }
    final files = <TransferFile>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) {
        continue;
      }
      final id = _randomId();
      final localPath = await _cacheUploadPayload(id, bytes);
      final mimeType = lookupMimeType(file.name, headerBytes: bytes) ??
          'application/octet-stream';
      files.add(
        TransferFile(
          id: id,
          name: file.name,
          bytes: bytes,
          payloadKind: payloadKindFile,
          mimeType: mimeType,
          packagingMode: packagingModeOriginals,
          localPath: localPath,
        ),
      );
    }
    if (files.isEmpty) {
      setState(() {
        _sendStatus = 'No files loaded.';
      });
      return;
    }
    setState(() {
      _selectedFiles
        ..clear()
        ..addAll(files);
    });
  }

  Future<void> _pickMedia() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.media,
    );
    if (result == null) {
      return;
    }
    final files = <TransferFile>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) {
        continue;
      }
      final id = _randomId();
      final localPath = await _cacheUploadPayload(id, bytes);
      final name = file.name.isNotEmpty ? file.name : 'media';
      final mimeType = lookupMimeType(name, headerBytes: bytes) ??
          'application/octet-stream';
      files.add(
        TransferFile(
          id: id,
          name: name,
          bytes: bytes,
          payloadKind: payloadKindFile,
          mimeType: mimeType,
          packagingMode: packagingModeOriginals,
          localPath: localPath,
        ),
      );
    }
    if (files.isEmpty) {
      setState(() {
        _sendStatus = 'No media loaded.';
      });
      return;
    }
    setState(() {
      _selectedFiles
        ..clear()
        ..addAll(files);
    });
  }

  Future<String?> _cacheUploadPayload(String id, Uint8List bytes) async {
    final dir = await getApplicationSupportDirectory();
    final uploadDir = Directory(p.join(dir.path, 'upload_cache'));
    await uploadDir.create(recursive: true);
    final path = p.join(uploadDir.path, id);
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<void> _startQueue() async {
    if (_senderTransferToken == null ||
        _senderReceiverPubKeyB64 == null ||
        _senderKeyPair == null ||
        _senderSessionId == null) {
      setState(() {
        _sendStatus = 'Claim and wait for approval first.';
      });
      return;
    }
    if (_selectedFiles.isEmpty) {
      setState(() {
        _sendStatus = 'Select files first.';
      });
      return;
    }
    if (_preferDirect) {
      await _maybeShowDirectDisclosure();
    }

    _ensureCoordinator();
    final coordinator = _coordinator;
    if (coordinator == null) {
      setState(() {
        _sendStatus = 'Invalid base URL.';
      });
      return;
    }
    final p2pToken = _senderP2PToken ?? _senderTransferToken ?? '';
    final p2pContext = _buildP2PContext(
      sessionId: _senderSessionId!,
      claimId: _claimId ?? '',
      token: p2pToken,
      isInitiator: true,
    );

    if (_packagingMode == packagingModeOriginals) {
      coordinator.enqueueUploads(
        files: _selectedFiles,
        sessionId: _senderSessionId!,
        transferToken: _senderTransferToken!,
        receiverPublicKey: publicKeyFromBase64(_senderReceiverPubKeyB64!),
        senderKeyPair: _senderKeyPair!,
        chunkSize: 16 * 1024,
        scanRequired: _scanRequired,
        p2pContext: p2pContext,
      );
      setState(() {
        _sendStatus = 'Uploading...';
        _selectedFiles.clear();
      });
      await coordinator.runQueue();
      return;
    }

    try {
      final packageTitle = _packageTitleController.text.trim();
      if (packageTitle.isEmpty) {
        setState(() {
          _sendStatus = 'Package title required.';
        });
        return;
      }
      final package = buildZipPackage(
        files: _selectedFiles,
        packageTitle: packageTitle,
        albumMode: _packagingMode == packagingModeAlbum,
      );
      final payloadKind = _packagingMode == packagingModeAlbum
          ? payloadKindAlbum
          : payloadKindZip;
      final id = _randomId();
      final localPath = await _cacheUploadPayload(id, package.bytes);
      final transferFile = TransferFile(
        id: id,
        name: package.outputName,
        bytes: package.bytes,
        payloadKind: payloadKind,
        mimeType: 'application/zip',
        packagingMode: _packagingMode,
        packageTitle: packageTitle,
        entries: package.entries,
        localPath: localPath,
      );
      coordinator.enqueueUploads(
        files: [transferFile],
        sessionId: _senderSessionId!,
        transferToken: _senderTransferToken!,
        receiverPublicKey: publicKeyFromBase64(_senderReceiverPubKeyB64!),
        senderKeyPair: _senderKeyPair!,
        chunkSize: 64 * 1024,
        scanRequired: _scanRequired,
        p2pContext: p2pContext,
      );
      setState(() {
        _sendStatus = 'Package queued.';
        _selectedFiles.clear();
      });
      await coordinator.runQueue();
    } catch (err) {
      setState(() {
        _sendStatus = 'Packaging failed: $err';
      });
    }
  }

  void _pauseQueue() {
    _coordinator?.pause();
    setState(() {
      _sendStatus = 'Paused.';
    });
  }

  Future<void> _resumeQueue() async {
    await _coordinator?.resume();
    setState(() {
      _sendStatus = 'Resumed.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UniversalDrop')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: ListView(
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
            const Text(
              'P2P settings',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Prefer direct'),
              subtitle: const Text('Use WebRTC when available'),
              value: _preferDirect,
              onChanged: (value) => _setPreferDirect(value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Always relay'),
              subtitle: const Text('Force TURN relay (no direct IP exposure)'),
              value: _alwaysRelay,
              onChanged: _preferDirect ? (value) => _setAlwaysRelay(value) : null,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _loading ? null : _pingBackend,
                  child: Text(_loading ? 'Pinging...' : 'Ping Backend'),
                ),
                OutlinedButton(
                  onPressed: _openDiagnostics,
                  child: const Text('Diagnostics'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Status: $_status'),
            const SizedBox(height: 24),
            const Text(
              'Download settings',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Prefer background downloads'),
              subtitle:
                  const Text('Use background downloads for large transfers'),
              value: _preferBackgroundDownloads,
              onChanged: (value) => _setPreferBackgroundDownloads(value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show more details in notifications'),
              subtitle: const Text('May include transfer details'),
              value: _showNotificationDetails,
              onChanged: (value) => _setNotificationDetails(value),
            ),
            const SizedBox(height: 16),
            ..._buildTrustedDevicesSection(),
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
                child:
                    Text(_refreshingClaims ? 'Refreshing...' : 'Refresh Claims'),
              ),
              const SizedBox(height: 8),
              Text(_claimsStatus),
              const SizedBox(height: 8),
              ..._pendingClaims.map((claim) {
                final sasCode = _receiverSasByClaim[claim.claimId] ?? '';
                final sasState = claim.sasState;
                final receiverConfirmed =
                    sasState == 'receiver_confirmed' || sasState == 'verified';
                final sasVerified = sasState == 'verified';
                final sasConfirming =
                    _receiverSasConfirming.contains(claim.claimId);
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
                        if (claim.transferId.isNotEmpty)
                          Text('Transfer ID: ${claim.transferId}'),
                        if (claim.scanRequired)
                          Text(
                            'Scan status: ${claim.scanStatus.isEmpty ? 'pending' : claim.scanStatus}',
                          ),
                        if (sasCode.isNotEmpty) Text('SAS: $sasCode'),
                        Text(
                          'SAS state: ${sasState.isEmpty ? 'pending' : sasState}',
                        ),
                        const SizedBox(height: 4),
                        ElevatedButton(
                          onPressed: sasCode.isEmpty ||
                                  receiverConfirmed ||
                                  sasConfirming
                              ? null
                              : () => _confirmReceiverSas(claim),
                          child: Text(
                            sasConfirming
                                ? 'Confirming...'
                                : receiverConfirmed
                                    ? 'SAS confirmed'
                                    : 'Confirm SAS',
                          ),
                        ),
                        TrustedDeviceBadge.forFingerprint(
                          fingerprint: claim.shortFingerprint,
                          trustedFingerprints: _trustedFingerprints,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            ElevatedButton(
                              onPressed:
                                  receiverConfirmed || sasConfirming || sasVerified
                                      ? null
                                      : () => _respondToClaim(claim, true),
                              child: const Text('Approve'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: sasConfirming
                                  ? null
                                  : () => _respondToClaim(claim, false),
                              child: const Text('Reject'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: receiverConfirmed
                                  ? () => _downloadManifest(claim)
                                  : null,
                              child: const Text('Download'),
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
                labelText: 'QR payload',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sessionIdController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Session ID',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _claimTokenController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Claim token',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
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
            const SizedBox(height: 8),
            if (_claimId != null) Text('Claim ID: $_claimId'),
            if (_claimStatus != null) Text('Claim status: $_claimStatus'),
            if (_senderSasCode != null && _senderSasCode!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('SAS: $_senderSasCode'),
              const SizedBox(height: 4),
              ElevatedButton(
                onPressed: _senderSasConfirmed || _senderSasConfirming
                    ? null
                    : _confirmSenderSas,
                child: Text(
                  _senderSasConfirming
                      ? 'Confirming...'
                      : _senderSasConfirmed
                          ? 'SAS confirmed'
                          : 'Confirm SAS',
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(_sendStatus),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Files'),
                  selected: !_sendTextMode,
                  onSelected: (value) {
                    if (!value) return;
                    setState(() {
                      _sendTextMode = !value;
                    });
                  },
                ),
                ChoiceChip(
                  label: const Text('Text'),
                  selected: _sendTextMode,
                  onSelected: (value) {
                    if (!value) return;
                    setState(() {
                      _sendTextMode = value;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_sendTextMode) ...[
              TextField(
                controller: _textTitleController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Text title (optional)',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _textContentController,
                maxLines: 4,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Text content',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  ElevatedButton(
                    onPressed: _pasteFromClipboard,
                    child: const Text('Paste'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _sendTextMode ? _sendText : null,
                    child: const Text('Send'),
                  ),
                ],
              ),
            ],
            if (!_sendTextMode) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  DropdownButton<String>(
                    value: _packagingMode,
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _packagingMode = value;
                        if (_packagingMode != packagingModeOriginals &&
                            _packageTitleController.text.trim().isEmpty) {
                          _packageTitleController.text = _defaultPackageTitle();
                        }
                      });
                    },
                    items: const [
                      DropdownMenuItem(
                        value: packagingModeOriginals,
                        child: Text('Originals'),
                      ),
                      DropdownMenuItem(
                        value: packagingModeZip,
                        child: Text('ZIP'),
                      ),
                      DropdownMenuItem(
                        value: packagingModeAlbum,
                        child: Text('Album'),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _pickFiles,
                    child: const Text('Select Files'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _pickMedia,
                    child: const Text('Select Photos'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _senderTransferToken == null || !_senderSasConfirmed
                        ? null
                        : _startQueue,
                    child: const Text('Start Queue'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _coordinator?.isRunning == true ? _pauseQueue : null,
                    child: const Text('Pause'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _coordinator?.isPaused == true ? _resumeQueue : null,
                    child: const Text('Resume'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_selectedFiles.isNotEmpty) ...[
                if (_packagingMode != packagingModeOriginals) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _packageTitleController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Package title',
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                const Text('Queue'),
                const SizedBox(height: 8),
                ..._selectedFiles.map((file) {
                  final state = _transferStates[file.id];
                  final status = state?.status ?? statusQueued;
                  final progress = state == null || state.totalBytes == 0
                      ? 0.0
                      : _progressForState(state);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(child: Text(file.name)),
                        Text(status),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 120,
                          child: LinearProgressIndicator(value: progress),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ],
            if (_receivedText.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Received text'),
              const SizedBox(height: 8),
              SelectableText(_receivedText),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => copyToClipboard(
                  widget.clipboardService,
                  _receivedText,
                ),
                child: const Text('Copy to Clipboard'),
              ),
            ],
            if (_saveStatus.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_saveStatus),
              if (_lastSavedPath != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () => _saveService.openIn(_lastSavedPath!),
                      child: const Text('Open in…'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => _saveService.saveAs(
                        _lastSavedPath!,
                        _suggestedExportName(),
                      ),
                      child: const Text('Save As…'),
                    ),
                    if (_lastSaveIsMedia) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () async {
                          final path = _lastSavedPath!;
                          final bytes = await File(path).readAsBytes();
                          final outcome = await _saveService.saveBytes(
                            bytes: bytes,
                            name: _suggestedExportName(),
                            mime: _lastSavedMime ?? 'application/octet-stream',
                            isMedia: true,
                            destination: SaveDestination.photos,
                          );
                          setState(() {
                            _saveStatus = outcome.success
                                ? 'Saved to Photos.'
                                : 'Save to Photos failed.';
                          });
                        },
                        child: const Text('Save to Photos'),
                      ),
                    ],
                  ],
                ),
              ],
              if (_lastManifest?.packagingMode == packagingModeZip &&
                  _lastZipBytes != null) ...[
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _extracting ? null : _extractZip,
                  child:
                      Text(_extracting ? 'Extracting...' : 'Extract ZIP'),
                ),
                if (_extractProgress != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Extracted ${_extractProgress!.filesExtracted}/${_extractProgress!.totalFiles} files',
                  ),
                ],
                if (_extractStatus.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_extractStatus),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

double _progressForState(TransferState state) {
  if (state.chunkSize <= 0) {
    return 0.0;
  }
  final chunks =
      (state.totalBytes + state.chunkSize - 1) ~/ state.chunkSize;
  final totalEncrypted = state.totalBytes + (chunks * 28);
  if (totalEncrypted == 0) {
    return 0.0;
  }
  return (state.nextOffset / totalEncrypted).clamp(0.0, 1.0);
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
    required this.senderPubKeyB64,
    required this.transferId,
    required this.scanRequired,
    required this.scanStatus,
    required this.sasState,
  });

  final String claimId;
  final String senderLabel;
  final String shortFingerprint;
  final String senderPubKeyB64;
  final String transferId;
  final bool scanRequired;
  final String scanStatus;
  final String sasState;

  factory PendingClaim.fromJson(Map<String, dynamic> json) {
    return PendingClaim(
      claimId: json['claim_id']?.toString() ?? '',
      senderLabel: json['sender_label']?.toString() ?? '',
      shortFingerprint: json['short_fingerprint']?.toString() ?? '',
      senderPubKeyB64: json['sender_pubkey_b64']?.toString() ?? '',
      transferId: json['transfer_id']?.toString() ?? '',
      scanRequired: json['scan_required'] == true,
      scanStatus: json['scan_status']?.toString() ?? '',
      sasState: json['sas_state']?.toString() ?? 'pending',
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

String _randomId() {
  final bytes = Uint8List(18);
  final random = Random.secure();
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return base64UrlEncode(bytes).replaceAll('=', '');
}
