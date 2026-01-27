import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/destination_rules.dart';
import 'package:universaldrop_app/transfer_manifest.dart';

void main() {
  test('classifies media from manifest mime', () {
    final manifest = TransferManifest(
      transferId: 't1',
      payloadKind: payloadKindFile,
      totalBytes: 10,
      chunkSize: 5,
      files: [
        TransferManifestFile(
          name: 'photo.jpg',
          bytes: 10,
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
      totalBytes: 10,
      chunkSize: 5,
      files: [
        TransferManifestFile(
          name: 'doc.pdf',
          bytes: 10,
          mime: 'application/pdf',
        ),
      ],
    );
    expect(isMediaManifest(manifest), isFalse);
  });
}
