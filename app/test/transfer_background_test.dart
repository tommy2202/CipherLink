import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/transfer_background.dart';
import 'package:universaldrop_app/transfer_state_store.dart';

void main() {
  test('background manager schedules resume and manages foreground', () async {
    final scheduler = FakeResumeScheduler();
    final foreground = FakeForegroundController();
    final manager = TransferBackgroundManager(
      scheduler: scheduler,
      foregroundController: foreground,
    );

    final downloading = TransferState(
      transferId: 'transfer-1',
      sessionId: 'session-1',
      transferToken: 'token-1',
      direction: 'download',
      status: 'downloading',
      totalBytes: 8,
      chunkSize: 4,
      nextOffset: 4,
      nextChunkIndex: 1,
    );
    await manager.onStateUpdated(downloading);
    expect(scheduler.scheduled, contains('transfer-1'));
    expect(foreground.receivingStarted, isTrue);

    final completed = downloading.copyWith(status: 'completed');
    await manager.onStateUpdated(completed);
    expect(scheduler.cancelled, contains('transfer-1'));
    expect(foreground.stopped, isTrue);
  });

  test('connectivity callback triggers on restore', () async {
    final monitor = FakeConnectivityMonitor();
    var calls = 0;
    final manager = TransferBackgroundManager(
      scheduler: FakeResumeScheduler(),
      foregroundController: FakeForegroundController(),
      connectivityMonitor: monitor,
      onConnectivityRestored: () async {
        calls += 1;
      },
    );

    monitor.emit(ConnectivityStatus.wifi);
    await Future<void>.delayed(Duration.zero);
    expect(calls, equals(1));

    manager.dispose();
  });
}

class FakeResumeScheduler implements TransferResumeScheduler {
  final List<String> scheduled = [];
  final List<String> cancelled = [];

  @override
  Future<void> scheduleResume(TransferState state) async {
    scheduled.add(state.transferId);
  }

  @override
  Future<void> cancelResume(String transferId) async {
    cancelled.add(transferId);
  }
}

class FakeForegroundController implements TransferForegroundController {
  bool receivingStarted = false;
  bool sendingStarted = false;
  bool stopped = false;

  @override
  Future<void> startReceiving() async {
    receivingStarted = true;
  }

  @override
  Future<void> startSending() async {
    sendingStarted = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

class FakeConnectivityMonitor implements ConnectivityMonitor {
  final StreamController<ConnectivityStatus> _controller =
      StreamController<ConnectivityStatus>.broadcast();

  @override
  Stream<ConnectivityStatus> get onStatus => _controller.stream;

  void emit(ConnectivityStatus status) {
    _controller.add(status);
  }
}
