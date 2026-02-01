import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universaldrop_app/main.dart';
import 'package:universaldrop_app/trust_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('trusted devices shows nickname when present', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = TrustStore();
    await store.addFingerprint('fingerprint-1');
    await store.setNickname('fingerprint-1', 'Laptop');

    await tester.pumpWidget(
      const MaterialApp(
        home: HomeScreen(runStartupTasks: false),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Laptop'), findsOneWidget);
  });
}
