import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universaldrop_app/trust_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('trust store saves, loads, and removes fingerprints', () async {
    final store = TrustStore();
    final empty = await store.loadFingerprints();
    expect(empty, isEmpty);

    final afterAdd = await store.addFingerprint('fingerprint-1');
    expect(afterAdd, contains('fingerprint-1'));

    final loaded = await store.loadFingerprints();
    expect(loaded, contains('fingerprint-1'));

    final afterRemove = await store.removeFingerprint('fingerprint-1');
    expect(afterRemove, isNot(contains('fingerprint-1')));
  });
}
