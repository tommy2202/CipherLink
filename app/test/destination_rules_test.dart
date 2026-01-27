import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/destination_rules.dart';
import 'package:universaldrop_app/destination_preferences.dart';
import 'package:universaldrop_app/transfer_manifest.dart';

void main() {
  test('classifies media from manifest mime', () {
    final manifest = TransferManifest(
      transferId: 't1',
      payloadKind: payloadKindFile,
      packagingMode: packagingModeOriginals,
      totalBytes: 10,
      chunkSize: 5,
      files: [
        TransferManifestFile(
          relativePath: 'photo.jpg',
          mediaType: mediaTypeImage,
          sizeBytes: 10,
          mime: 'image/jpeg',
        ),
      ],
    );
    expect(isMediaManifest(manifest), isTrue);
  });

  test('classifies non-media for text payload', () {
    final manifest = TransferManifest(
      transferId: 't2',
      payloadKind: payloadKindText,
      packagingMode: packagingModeOriginals,
      totalBytes: 10,
      chunkSize: 5,
      files: const [],
      textTitle: 'Note',
      textMime: textMimePlain,
      textLength: 10,
    );
    expect(isMediaManifest(manifest), isFalse);
  });

  test('classifies non-media for application/pdf', () {
    final manifest = TransferManifest(
      transferId: 't3',
      payloadKind: payloadKindFile,
      packagingMode: packagingModeOriginals,
      totalBytes: 10,
      chunkSize: 5,
      files: [
        TransferManifestFile(
          relativePath: 'doc.pdf',
          mediaType: mediaTypeOther,
          sizeBytes: 10,
          mime: 'application/pdf',
        ),
      ],
    );
    expect(isMediaManifest(manifest), isFalse);
  });

  test('zip packaging forces files destination', () {
    final manifest = TransferManifest(
      transferId: 't4',
      payloadKind: payloadKindZip,
      packagingMode: packagingModeZip,
      totalBytes: 10,
      chunkSize: 5,
      files: const [],
      outputFilename: 'package.zip',
    );
    final prefs = const DestinationPreferences(
      defaultMediaDestination: SaveDestination.photos,
      defaultFileDestination: SaveDestination.files,
    );
    expect(
      defaultDestinationForManifest(manifest, prefs),
      SaveDestination.files,
    );
  });

  test('album packaging forces photos destination', () {
    final manifest = TransferManifest(
      transferId: 't5',
      payloadKind: payloadKindAlbum,
      packagingMode: packagingModeAlbum,
      totalBytes: 10,
      chunkSize: 5,
      files: const [],
      albumTitle: 'Album',
      albumItemCount: 0,
    );
    final prefs = const DestinationPreferences(
      defaultMediaDestination: SaveDestination.files,
      defaultFileDestination: SaveDestination.files,
    );
    expect(
      defaultDestinationForManifest(manifest, prefs),
      SaveDestination.photos,
    );
  });
}
