import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:universaldrop_app/main.dart';
import 'package:universaldrop_app/save_service.dart';
import 'package:universaldrop_app/transfer_background.dart';

void main() {
  testWidgets('does not request photos permission on startup', (tester) async {
    var requested = false;
    final originalRequester = requestPhotoPermission;
    requestPhotoPermission = () async {
      requested = true;
      return PermissionState.denied;
    };
    addTearDown(() {
      requestPhotoPermission = originalRequester;
    });

    final backgroundManager = TransferBackgroundManager(
      scheduler: _NoopResumeScheduler(),
      foregroundController: _NoopForegroundController(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          backgroundManager: backgroundManager,
          runStartupTasks: false,
        ),
      ),
    );
    await tester.pump();

    expect(requested, isFalse);
  });
}

class _NoopResumeScheduler implements TransferResumeScheduler {
  @override
  Future<void> scheduleResume(TransferState state) async {}

  @override
  Future<void> cancelResume(String transferId) async {}
}

class _NoopForegroundController implements TransferForegroundController {
  @override
  Future<void> startReceiving() async {}

  @override
  Future<void> startSending() async {}

  @override
  Future<void> stop() async {}
}
