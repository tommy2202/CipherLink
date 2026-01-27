class TransferState {
  const TransferState({
    required this.transferId,
    required this.status,
    required this.bytesReceived,
  });

  final String transferId;
  final String status;
  final int bytesReceived;

  TransferState copyWith({
    String? status,
    int? bytesReceived,
  }) {
    return TransferState(
      transferId: transferId,
      status: status ?? this.status,
      bytesReceived: bytesReceived ?? this.bytesReceived,
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
