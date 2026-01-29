import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

import 'transfer_state_store.dart';

abstract class TransferBackgroundHooks {
  Future<void> onStateUpdated(TransferState state);
}

class NoopTransferBackgroundHooks implements TransferBackgroundHooks {
  @override
  Future<void> onStateUpdated(TransferState state) async {}
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
    Stream<ConnectivityResult>? connectivityStream,
    Future<void> Function()? onConnectivityRestored,
  })  : _scheduler = scheduler,
        _foregroundController = foregroundController,
        _onConnectivityRestored = onConnectivityRestored {
    if (_onConnectivityRestored != null) {
      final stream = connectivityStream ?? Connectivity().onConnectivityChanged;
      _subscription = stream.listen((status) {
        if (status != ConnectivityResult.none) {
          _onConnectivityRestored?.call();
        }
      });
    }
  }

  final TransferResumeScheduler _scheduler;
  final TransferForegroundController _foregroundController;
  final Future<void> Function()? _onConnectivityRestored;
  final Set<String> _activeDownloads = {};
  final Set<String> _activeUploads = {};
  StreamSubscription<ConnectivityResult>? _subscription;

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
