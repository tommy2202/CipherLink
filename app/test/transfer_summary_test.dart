import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/transfer/transfer_summary.dart';
import 'package:universaldrop_app/transfer_manifest.dart';

void main() {
  test('buildTransferSummary uses manifest metadata only', () {
    final manifest = TransferManifest(
      transferId: 'transfer-1',
      payloadKind: payloadKindFile,
      packagingMode: packagingModeZip,
      totalBytes: 1234,
      chunkSize: 256,
      files: [
        TransferManifestFile(
          relativePath: 'one.txt',
          mediaType: mediaTypeOther,
          sizeBytes: 100,
        ),
        TransferManifestFile(
          relativePath: 'two.txt',
          mediaType: mediaTypeOther,
          sizeBytes: 200,
        ),
      ],
    );

    final summary = buildTransferSummary(manifest);

    expect(summary.totalBytes, equals(1234));
    expect(summary.itemCount, equals(2));
    expect(summary.type, equals(TransferSummaryType.zip));
    expect(summary.fileNames, equals(['one.txt', 'two.txt']));
  });
}
