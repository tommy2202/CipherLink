import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/transfer_manifest.dart';

void main() {
  test('zip manifest serialization/deserialization', () {
    final manifest = TransferManifest(
      transferId: 't1',
      payloadKind: payloadKindZip,
      packagingMode: packagingModeZip,
      packageTitle: 'Package',
      totalBytes: 100,
      chunkSize: 64,
      files: [
        TransferManifestFile(
          relativePath: 'file.txt',
          mediaType: mediaTypeOther,
          sizeBytes: 100,
          originalFilename: 'file.txt',
          mime: 'text/plain',
        ),
      ],
      outputFilename: 'Package.zip',
    );

    final json = manifest.toJson();
    final decoded = TransferManifest.fromJson(json);
    expect(decoded.packagingMode, packagingModeZip);
    expect(decoded.outputFilename, 'Package.zip');
  });

  test('album manifest serialization/deserialization', () {
    final manifest = TransferManifest(
      transferId: 't2',
      payloadKind: payloadKindAlbum,
      packagingMode: packagingModeAlbum,
      packageTitle: 'Album',
      totalBytes: 200,
      chunkSize: 64,
      files: [
        TransferManifestFile(
          relativePath: 'media/1.jpg',
          mediaType: mediaTypeImage,
          sizeBytes: 200,
          originalFilename: '1.jpg',
          mime: 'image/jpeg',
        ),
      ],
      albumTitle: 'Album',
      albumItemCount: 1,
    );

    final json = manifest.toJson();
    final decoded = TransferManifest.fromJson(json);
    expect(decoded.packagingMode, packagingModeAlbum);
    expect(decoded.albumItemCount, 1);
  });
}
