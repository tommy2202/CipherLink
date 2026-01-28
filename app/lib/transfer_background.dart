import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'transfer_state_store.dart';

abstract class TransferBackgroundHooks {
  Future<void> onStateUpdated(TransferState state);
}

class NoopTransferBackgroundHooks implements TransferBackgroundHooks {
  @override
  Future<void> onStateUpdated(TransferState state) async {}
}

enum ConnectivityStatus {
  none,
  wifi,
  mobile,
  other,
}

abstract class ConnectivityMonitor {
  Stream<ConnectivityStatus> get onStatus;
}

class MethodChannelConnectivityMonitor implements ConnectivityMonitor {
  MethodChannelConnectivityMonitor({EventChannel? channel})
      : _channel = channel ?? const EventChannel('universaldrop/connectivity');

  final EventChannel _channel;

  @override
  Stream<ConnectivityStatus> get onStatus {
    return _channel.receiveBroadcastStream().map(_parseStatus);
  }

  ConnectivityStatus _parseStatus(dynamic value) {
    final raw = value?.toString().toLowerCase() ?? '';
    switch (raw) {
      case 'wifi':
        return ConnectivityStatus.wifi;
      case 'cellular':
      case 'mobile':
        return ConnectivityStatus.mobile;
      case 'none':
      case 'offline':
        return ConnectivityStatus.none;
      default:
        return ConnectivityStatus.other;
    }
  }
}

abstract class TransferResumeScheduler {
  Future<void> scheduleResume(TransferState state);
  Future<void> cancelResume(String transferId);
}

class MethodChannelResumeScheduler implements TransferResumeScheduler {
  MethodChannelResumeScheduler({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('universaldrop/work_manager');

  final MethodChannel _channel;

  @override
  Future<void> scheduleResume(TransferState state) async {
    await _channel.invokeMethod('schedule', {
      'transfer_id': state.transferId,
      'direction': state.direction,
    });
  }

  @override
  Future<void> cancelResume(String transferId) {
    return _channel.invokeMethod('cancel', {'transfer_id': transferId});
  }
}

abstract class TransferForegroundController {
  Future<void> startReceiving();
  Future<void> startSending();
  Future<void> stop();
}

class MethodChannelForegroundController implements TransferForegroundController {
  MethodChannelForegroundController({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('universaldrop/foreground_service');

  final MethodChannel _channel;

  @override
  Future<void> startReceiving() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod('startReceiving', {
      'title': 'Receiving file(s)',
      'body': 'Transfer in progress',
    });
  }

  @override
  Future<void> startSending() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod('startSending', {
      'title': 'Sending file(s)',
      'body': 'Transfer in progress',
    });
  }

  @override
  Future<void> stop() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod('stop');
  }
}

class TransferBackgroundManager implements TransferBackgroundHooks {
  TransferBackgroundManager({
    required TransferResumeScheduler scheduler,
    required TransferForegroundController foregroundController,
    ConnectivityMonitor? connectivityMonitor,
    Future<void> Function()? onConnectivityRestored,
  })  : _scheduler = scheduler,
        _foregroundController = foregroundController,
        _onConnectivityRestored = onConnectivityRestored {
    _subscription = connectivityMonitor?.onStatus.listen((status) {
      if (status != ConnectivityStatus.none) {
        _onConnectivityRestored?.call();
      }
    });
  }

  final TransferResumeScheduler _scheduler;
  final TransferForegroundController _foregroundController;
  final Future<void> Function()? _onConnectivityRestored;
  final Set<String> _activeDownloads = {};
  final Set<String> _activeUploads = {};
  StreamSubscription<ConnectivityStatus>? _subscription;

  @override
  Future<void> onStateUpdated(TransferState state) async {
    if (state.needsResume) {
      await _scheduler.scheduleResume(state);
    } else {
      await _scheduler.cancelResume(state.transferId);
    }

    if (state.isActive) {
      if (state.direction == 'download') {
        _activeDownloads.add(state.transferId);
        _activeUploads.remove(state.transferId);
      } else if (state.direction == 'upload') {
        _activeUploads.add(state.transferId);
        _activeDownloads.remove(state.transferId);
      }
    } else {
      _activeDownloads.remove(state.transferId);
      _activeUploads.remove(state.transferId);
    }

    await _updateForegroundService();
  }

  Future<void> _updateForegroundService() async {
    if (_activeDownloads.isNotEmpty) {
      await _foregroundController.startReceiving();
      return;
    }
    if (_activeUploads.isNotEmpty) {
      await _foregroundController.startSending();
      return;
    }
    await _foregroundController.stop();
  }

  void dispose() {
    _subscription?.cancel();
  }
}
