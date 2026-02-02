import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TransferState {
  const TransferState({
    required this.transferId,
    required this.sessionId,
    required this.transferToken,
    required this.direction,
    required this.status,
    required this.totalBytes,
    required this.chunkSize,
    required this.nextOffset,
    required this.nextChunkIndex,
    this.peerPublicKeyB64,
    this.payloadPath,
    this.scanRequired,
    this.claimId,
    this.ciphertextPath,
    this.ciphertextComplete,
    this.backgroundTaskId,
    this.manifestHashB64,
    this.destination,
    this.requiresForegroundResume,
    this.downloadTokenRefreshFailures,
    this.notificationLabel,
  });

  final String transferId;
  final String sessionId;
  final String transferToken;
  final String direction;
  final String status;
  final int totalBytes;
  final int chunkSize;
  final int nextOffset;
  final int nextChunkIndex;
  final String? peerPublicKeyB64;
  final String? payloadPath;
  final bool? scanRequired;
  final String? claimId;
  final String? ciphertextPath;
  final bool? ciphertextComplete;
  final String? backgroundTaskId;
  final String? manifestHashB64;
  final String? destination;
  final bool? requiresForegroundResume;
  final int? downloadTokenRefreshFailures;
  final String? notificationLabel;

  bool get isTerminal => status == 'completed' || status == 'failed';
  bool get isActive =>
      status == 'uploading' ||
      status == 'downloading' ||
      status == 'decrypting';
  bool get needsResume => !isTerminal;

  TransferState copyWith({
    String? sessionId,
    String? transferToken,
    String? direction,
    String? status,
    int? totalBytes,
    int? chunkSize,
    int? nextOffset,
    int? nextChunkIndex,
    String? peerPublicKeyB64,
    String? payloadPath,
    bool? scanRequired,
    String? claimId,
    String? ciphertextPath,
    bool? ciphertextComplete,
    String? backgroundTaskId,
    String? manifestHashB64,
    String? destination,
    bool? requiresForegroundResume,
    int? downloadTokenRefreshFailures,
    String? notificationLabel,
  }) {
    return TransferState(
      transferId: transferId,
      sessionId: sessionId ?? this.sessionId,
      transferToken: transferToken ?? this.transferToken,
      direction: direction ?? this.direction,
      status: status ?? this.status,
      totalBytes: totalBytes ?? this.totalBytes,
      chunkSize: chunkSize ?? this.chunkSize,
      nextOffset: nextOffset ?? this.nextOffset,
      nextChunkIndex: nextChunkIndex ?? this.nextChunkIndex,
      peerPublicKeyB64: peerPublicKeyB64 ?? this.peerPublicKeyB64,
      payloadPath: payloadPath ?? this.payloadPath,
      scanRequired: scanRequired ?? this.scanRequired,
      claimId: claimId ?? this.claimId,
      ciphertextPath: ciphertextPath ?? this.ciphertextPath,
      ciphertextComplete: ciphertextComplete ?? this.ciphertextComplete,
      backgroundTaskId: backgroundTaskId ?? this.backgroundTaskId,
      manifestHashB64: manifestHashB64 ?? this.manifestHashB64,
      destination: destination ?? this.destination,
      requiresForegroundResume:
          requiresForegroundResume ?? this.requiresForegroundResume,
      downloadTokenRefreshFailures:
          downloadTokenRefreshFailures ?? this.downloadTokenRefreshFailures,
      notificationLabel: notificationLabel ?? this.notificationLabel,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'transfer_id': transferId,
      'session_id': sessionId,
      'transfer_token': transferToken,
      'direction': direction,
      'status': status,
      'total_bytes': totalBytes,
      'chunk_size': chunkSize,
      'next_offset': nextOffset,
      'next_chunk_index': nextChunkIndex,
      'peer_public_key_b64': peerPublicKeyB64,
      'payload_path': payloadPath,
      'scan_required': scanRequired,
      'claim_id': claimId,
      'ciphertext_path': ciphertextPath,
      'ciphertext_complete': ciphertextComplete,
      'background_task_id': backgroundTaskId,
      'manifest_hash_b64': manifestHashB64,
      'destination': destination,
      'requires_foreground_resume': requiresForegroundResume,
      'download_token_refresh_failures': downloadTokenRefreshFailures,
      'notification_label': notificationLabel,
    };
  }

  factory TransferState.fromJson(Map<String, dynamic> json) {
    return TransferState(
      transferId: json['transfer_id']?.toString() ?? '',
      sessionId: json['session_id']?.toString() ?? '',
      transferToken: json['transfer_token']?.toString() ?? '',
      direction: json['direction']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      totalBytes: _asInt(json['total_bytes']),
      chunkSize: _asInt(json['chunk_size']),
      nextOffset: _asInt(json['next_offset']),
      nextChunkIndex: _asInt(json['next_chunk_index']),
      peerPublicKeyB64: json['peer_public_key_b64']?.toString(),
      payloadPath: json['payload_path']?.toString(),
      scanRequired: _asBool(json['scan_required']),
      claimId: json['claim_id']?.toString(),
      ciphertextPath: json['ciphertext_path']?.toString(),
      ciphertextComplete: _asBool(json['ciphertext_complete']),
      backgroundTaskId: json['background_task_id']?.toString(),
      manifestHashB64: json['manifest_hash_b64']?.toString(),
      destination: json['destination']?.toString(),
      requiresForegroundResume: _asBool(json['requires_foreground_resume']),
      downloadTokenRefreshFailures:
          _asInt(json['download_token_refresh_failures']),
      notificationLabel: json['notification_label']?.toString(),
    );
  }

  static bool? _asBool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      if (value.toLowerCase() == 'true') {
        return true;
      }
      if (value.toLowerCase() == 'false') {
        return false;
      }
    }
    return null;
  }

  static int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

abstract class TransferStateStore {
  Future<void> save(TransferState state);
  Future<TransferState?> load(String transferId);
  Future<void> delete(String transferId);
  Future<List<TransferState>> listPending({String? direction});
}

class InMemoryTransferStateStore implements TransferStateStore {
  final Map<String, TransferState> _cache = {};

  @override
  Future<void> save(TransferState state) async {
    _cache[state.transferId] = state;
  }

  @override
  Future<TransferState?> load(String transferId) async {
    return _cache[transferId];
  }

  @override
  Future<void> delete(String transferId) async {
    _cache.remove(transferId);
  }

  @override
  Future<List<TransferState>> listPending({String? direction}) async {
    return _cache.values
        .where((state) => state.needsResume)
        .where((state) => direction == null || state.direction == direction)
        .toList();
  }
}

abstract class SecureStore {
  Future<void> write({required String key, required String value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
}

class SecureStoreUnavailableException implements Exception {
  SecureStoreUnavailableException([this.cause]);

  final Object? cause;

  @override
  String toString() => 'SecureStoreUnavailableException';
}

class FlutterSecureStore implements SecureStore {
  FlutterSecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> write({required String key, required String value}) async {
    try {
      await _storage.write(key: key, value: value);
    } on Exception catch (err) {
      throw SecureStoreUnavailableException(err);
    }
  }

  @override
  Future<String?> read({required String key}) async {
    try {
      return await _storage.read(key: key);
    } on Exception catch (err) {
      throw SecureStoreUnavailableException(err);
    }
  }

  @override
  Future<void> delete({required String key}) async {
    try {
      await _storage.delete(key: key);
    } on Exception catch (err) {
      throw SecureStoreUnavailableException(err);
    }
  }
}

class SecureTransferStateStore implements TransferStateStore {
  SecureTransferStateStore({SecureStore? secureStore})
      : _secureStore = secureStore ?? FlutterSecureStore();

  final SecureStore _secureStore;
  static const String _indexKey = 'transfer_state_index';

  @override
  Future<void> save(TransferState state) async {
    final payload = jsonEncode(state.toJson());
    await _secureStore.write(key: _stateKey(state.transferId), value: payload);
    final index = await _loadIndex();
    if (!index.contains(state.transferId)) {
      index.add(state.transferId);
      await _saveIndex(index);
    }
  }

  @override
  Future<TransferState?> load(String transferId) async {
    final payload = await _secureStore.read(key: _stateKey(transferId));
    if (payload == null || payload.isEmpty) {
      return null;
    }
    final data = jsonDecode(payload) as Map<String, dynamic>;
    return TransferState.fromJson(data);
  }

  @override
  Future<void> delete(String transferId) async {
    await _secureStore.delete(key: _stateKey(transferId));
    final index = await _loadIndex();
    if (index.remove(transferId)) {
      await _saveIndex(index);
    }
  }

  @override
  Future<List<TransferState>> listPending({String? direction}) async {
    final index = await _loadIndex();
    final List<TransferState> pending = [];
    for (final transferId in index) {
      final state = await load(transferId);
      if (state == null || !state.needsResume) {
        continue;
      }
      if (direction != null && state.direction != direction) {
        continue;
      }
      pending.add(state);
    }
    return pending;
  }

  Future<List<String>> _loadIndex() async {
    final payload = await _secureStore.read(key: _indexKey);
    if (payload == null || payload.isEmpty) {
      return <String>[];
    }
    final decoded = jsonDecode(payload);
    if (decoded is! List) {
      return <String>[];
    }
    return decoded.map((value) => value.toString()).toList();
  }

  Future<void> _saveIndex(List<String> index) async {
    await _secureStore.write(key: _indexKey, value: jsonEncode(index));
  }

  String _stateKey(String transferId) => 'transfer_state_$transferId';
}

class StoredDownloadToken {
  StoredDownloadToken({
    required this.token,
    this.expiresAt,
  });

  final String token;
  final DateTime? expiresAt;

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());
}

class DownloadTokenStore {
  DownloadTokenStore({SecureStore? secureStore})
      : _secureStore = secureStore ?? FlutterSecureStore();

  final SecureStore _secureStore;

  Future<void> saveToken({
    required String transferId,
    required String token,
    DateTime? expiresAt,
  }) async {
    await _secureStore.write(key: _tokenKey(transferId), value: token);
    if (expiresAt != null) {
      await _secureStore.write(
        key: _expiryKey(transferId),
        value: expiresAt.toIso8601String(),
      );
    }
  }

  Future<StoredDownloadToken?> loadToken(String transferId) async {
    final token = await _secureStore.read(key: _tokenKey(transferId));
    if (token == null || token.isEmpty) {
      return null;
    }
    final expiryRaw = await _secureStore.read(key: _expiryKey(transferId));
    final expiry =
        expiryRaw == null ? null : DateTime.tryParse(expiryRaw.toString());
    return StoredDownloadToken(token: token, expiresAt: expiry);
  }

  Future<void> deleteToken(String transferId) async {
    await _secureStore.delete(key: _tokenKey(transferId));
    await _secureStore.delete(key: _expiryKey(transferId));
  }

  String _tokenKey(String transferId) => 'download_token_$transferId';
  String _expiryKey(String transferId) => 'download_token_exp_$transferId';
}
