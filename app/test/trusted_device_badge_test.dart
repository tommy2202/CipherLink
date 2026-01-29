import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universaldrop_app/trust_store.dart';
import 'package:universaldrop_app/trusted_device_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('claim display shows Seen before for trusted fingerprint',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = TrustStore();
    await store.addFingerprint('fingerprint-1');
    final trusted = await store.loadFingerprints();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrustedDeviceBadge.forFingerprint(
            fingerprint: 'fingerprint-1',
            trustedFingerprints: trusted,
          ),
        ),
      ),
    );

    expect(find.text('Seen before'), findsOneWidget);
  });
}
