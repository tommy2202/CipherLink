import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/packaging_builder.dart';
import 'package:universaldrop_app/transfer_coordinator.dart';
import 'package:universaldrop_app/transfer_manifest.dart';
import 'package:universaldrop_app/zip_extract.dart';

void main() {
  test('zip builder produces package and manifest fields', () {
    final files = [
      TransferFile(
        id: 'f1',
        name: 'a.txt',
        bytes: Uint8List.fromList([1, 2, 3]),
        payloadKind: payloadKindFile,
        mimeType: 'text/plain',
        packagingMode: packagingModeOriginals,
      ),
      TransferFile(
        id: 'f2',
        name: 'b.txt',
        bytes: Uint8List.fromList([4, 5, 6]),
        payloadKind: payloadKindFile,
        mimeType: 'text/plain',
        packagingMode: packagingModeOriginals,
      ),
    ];

    final package = buildZipPackage(
      files: files,
      packageTitle: 'MyZip',
      albumMode: false,
    );

    expect(package.outputName, equals('MyZip.zip'));
    expect(package.entries.length, equals(2));
    expect(package.entries.first.relativePath, isNotEmpty);
  });

  test('album builder includes album manifest', () {
    final files = [
      TransferFile(
        id: 'f1',
        name: 'photo.jpg',
        bytes: Uint8List.fromList([1, 2, 3]),
        payloadKind: payloadKindFile,
        mimeType: 'image/jpeg',
        packagingMode: packagingModeOriginals,
      ),
    ];

    final package = buildZipPackage(
      files: files,
      packageTitle: 'Trip',
      albumMode: true,
    );

    final entries = decodeZipEntries(package.bytes);
    final hasManifest =
        entries.any((entry) => entry.name == 'ALBUM_MANIFEST.json');
    expect(hasManifest, isTrue);
  });
}
