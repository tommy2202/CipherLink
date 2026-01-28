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

  TransferState copyWith({
    String? sessionId,
    String? transferToken,
    String? direction,
    String? status,
    int? totalBytes,
    int? chunkSize,
    int? nextOffset,
    int? nextChunkIndex,
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
    );
  }
}

abstract class TransferStateStore {
  Future<void> save(TransferState state);
  Future<TransferState?> load(String transferId);
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
}
