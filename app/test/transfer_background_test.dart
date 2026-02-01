import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universaldrop_app/transfer/background_transfer.dart';

void main() {
  test('notification details preference defaults to false', () async {
    SharedPreferences.setMockInitialValues({});

    final value = await loadNotificationDetailsPreference();
    expect(value, isFalse);
  });

  test('notification details preference persists', () async {
    SharedPreferences.setMockInitialValues({});

    await saveNotificationDetailsPreference(true);
    final value = await loadNotificationDetailsPreference();

    expect(value, isTrue);
  });
}
