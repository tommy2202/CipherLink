import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universaldrop_app/destination_preferences.dart';

void main() {
  test('preference storage read/write', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPreferencesDestinationStore();

    await store.save(
      const DestinationPreferences(
        defaultMediaDestination: SaveDestination.photos,
        defaultFileDestination: SaveDestination.files,
      ),
    );

    final loaded = await store.load();
    expect(loaded.defaultMediaDestination, SaveDestination.photos);
    expect(loaded.defaultFileDestination, SaveDestination.files);
  });
}
