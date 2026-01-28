import 'dart:convert';

import 'package:flutter/services.dart';

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

  bool get isTerminal => status == 'completed' || status == 'failed';
  bool get isActive => status == 'uploading' || status == 'downloading';
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

class MethodChannelSecureStore implements SecureStore {
  MethodChannelSecureStore({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('universaldrop/secure_storage');

  final MethodChannel _channel;

  @override
  Future<void> write({required String key, required String value}) {
    return _channel.invokeMethod('write', {'key': key, 'value': value});
  }

  @override
  Future<String?> read({required String key}) async {
    final result = await _channel.invokeMethod<String>('read', {'key': key});
    return result;
  }

  @override
  Future<void> delete({required String key}) {
    return _channel.invokeMethod('delete', {'key': key});
  }
}

class SecureTransferStateStore implements TransferStateStore {
  SecureTransferStateStore({SecureStore? secureStore})
      : _secureStore = secureStore ?? MethodChannelSecureStore();

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
