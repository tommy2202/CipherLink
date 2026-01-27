import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/destination_preferences.dart';
import 'package:universaldrop_app/destination_selector.dart';
import 'package:universaldrop_app/transfer_manifest.dart';

void main() {
  test('destination selector remembers choice', () async {
    final store = FakeDestinationStore();
    final selector = DestinationSelector(store);

    final manifest = TransferManifest(
      transferId: 't1',
      payloadKind: payloadKindText,
      packagingMode: packagingModeOriginals,
      totalBytes: 5,
      chunkSize: 5,
      files: const [],
      textTitle: 'Note',
      textMime: textMimePlain,
      textLength: 5,
    );

    final defaultDest = await selector.defaultDestination(manifest);
    expect(defaultDest, SaveDestination.files);

    await selector.rememberChoice(
      manifest,
      DestinationChoice(
        destination: SaveDestination.files,
        remember: true,
      ),
    );

    final updated = await store.load();
    expect(updated.defaultFileDestination, SaveDestination.files);
  });

  test('destination selector defaults album to photos', () async {
    final store = FakeDestinationStore();
    final selector = DestinationSelector(store);
    final manifest = TransferManifest(
      transferId: 't2',
      payloadKind: payloadKindAlbum,
      packagingMode: packagingModeAlbum,
      totalBytes: 5,
      chunkSize: 5,
      files: const [],
      albumTitle: 'Album',
      albumItemCount: 0,
    );

    final dest = await selector.defaultDestination(manifest);
    expect(dest, SaveDestination.photos);
  });
}

class FakeDestinationStore implements DestinationPreferenceStore {
  DestinationPreferences _prefs = const DestinationPreferences();

  @override
  Future<DestinationPreferences> load() async => _prefs;

  @override
  Future<void> save(DestinationPreferences prefs) async {
    _prefs = prefs;
  }
}
