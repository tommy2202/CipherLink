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

  test('trust store persists nickname mapping', () async {
    final store = TrustStore();
    await store.addFingerprint('fingerprint-1');
    await store.setNickname('fingerprint-1', 'Laptop');

    final nicknames = await store.loadNicknames();
    expect(nicknames['fingerprint-1'], equals('Laptop'));

    final store2 = TrustStore();
    final nicknames2 = await store2.loadNicknames();
    expect(nicknames2['fingerprint-1'], equals('Laptop'));

    await store2.removeFingerprint('fingerprint-1');
    final nicknames3 = await store.loadNicknames();
    expect(nicknames3.containsKey('fingerprint-1'), isFalse);
  });
}
