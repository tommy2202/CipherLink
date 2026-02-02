import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/limits.dart';
import 'package:universaldrop_app/ui/zip_extraction_info.dart';
import 'package:universaldrop_app/zip_extract.dart';

void main() {
  testWidgets('shows warning when archive is near limits', (tester) async {
    final limits = ZipExtractionLimits(
      maxEntries: 10,
      maxTotalUncompressedBytes: 1000,
      maxSingleFileBytes: 800,
      maxPathLength: 50,
    );
    final safety = ZipSafetyInfo(
      totalEntries: 9,
      totalBytes: 950,
      maxEntryBytes: 700,
      maxPathLength: 45,
      exceedsLimits: false,
      nearLimits: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ZipExtractionInfo(
            safety: safety,
            limits: limits,
          ),
        ),
      ),
    );

    expect(
      find.text('Warning: Archive is close to extraction limits.'),
      findsOneWidget,
    );
  });
}
