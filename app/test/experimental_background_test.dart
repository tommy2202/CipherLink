import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universaldrop_app/main.dart';
import 'package:universaldrop_app/transfer_background.dart';
import 'package:universaldrop_app/transport.dart';

void main() {
  testWidgets(
      'enabling experimental background transfers disables on missing plugin',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final backgroundManager = TransferBackgroundManager(
      scheduler: _NoopResumeScheduler(),
      foregroundController: _NoopForegroundController(),
    );
    Transport? selectedTransport;

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          backgroundManager: backgroundManager,
          runStartupTasks: false,
          onTransportSelected: (transport) {
            selectedTransport = transport;
          },
        ),
      ),
    );
    await tester.pump();

    final toggleFinder = find.widgetWithText(
      SwitchListTile,
      'Experimental: Background transfers',
    );
    expect(toggleFinder, findsOneWidget);

    await tester.tap(toggleFinder);
    await tester.pump();

    expect(
      find.text(
        'May not be available on all devices. If unavailable, CipherLink uses standard mode.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final toggle = tester.widget<SwitchListTile>(toggleFinder);
    expect(toggle.value, isFalse);
    expect(selectedTransport, isA<HttpTransport>());
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
