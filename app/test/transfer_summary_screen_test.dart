import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/transfer/transfer_summary.dart';
import 'package:universaldrop_app/transfer_manifest.dart';
import 'package:universaldrop_app/ui/transfer_summary_screen.dart';

void main() {
  testWidgets('default OFF hides filenames', (tester) async {
    final manifest = TransferManifest(
      transferId: 'transfer-1',
      payloadKind: payloadKindFile,
      packagingMode: packagingModeOriginals,
      totalBytes: 100,
      chunkSize: 50,
      files: [
        TransferManifestFile(
          relativePath: 'secret.txt',
          mediaType: mediaTypeOther,
          sizeBytes: 100,
        ),
      ],
    );
    final summary = buildTransferSummary(manifest);

    await tester.pumpWidget(
      MaterialApp(
        home: TransferSummaryScreen(
          summary: summary,
          manifest: manifest,
          routeLabel: 'Relay',
          routeDisclosure: 'Relay keeps your IP address hidden from the sender.',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('secret.txt'), findsNothing);

    final toggleFinder = find.widgetWithText(
      SwitchListTile,
      'Show filenames and details',
    );
    final toggle = tester.widget<SwitchListTile>(toggleFinder);
    expect(toggle.value, isFalse);
  });
}
