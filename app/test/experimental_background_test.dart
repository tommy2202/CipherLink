import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universaldrop_app/main.dart';

void main() {
  testWidgets('background toggles default to off', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const MaterialApp(
        home: HomeScreen(runStartupTasks: false),
      ),
    );
    await tester.pump();

    final preferFinder =
        find.widgetWithText(SwitchListTile, 'Prefer background downloads');
    final detailsFinder = find.widgetWithText(
      SwitchListTile,
      'Show more details in notifications',
    );

    final preferToggle = tester.widget<SwitchListTile>(preferFinder);
    final detailsToggle = tester.widget<SwitchListTile>(detailsFinder);

    expect(preferToggle.value, isFalse);
    expect(detailsToggle.value, isFalse);
  });

  testWidgets('prefer background downloads shows disclosure', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const MaterialApp(
        home: HomeScreen(runStartupTasks: false),
      ),
    );
    await tester.pump();

    final preferFinder =
        find.widgetWithText(SwitchListTile, 'Prefer background downloads');

    await tester.tap(preferFinder);
    await tester.pump();

    expect(
      find.text(
        'May not be available on all devices. If unavailable, CipherLink uses standard mode.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final preferToggle = tester.widget<SwitchListTile>(preferFinder);
    expect(preferToggle.value, isTrue);
  });
}
