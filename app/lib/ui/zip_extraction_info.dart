import 'package:flutter/material.dart';
import 'package:universaldrop_app/limits.dart';
import 'package:universaldrop_app/zip_extract.dart';

class ZipExtractionInfo extends StatelessWidget {
  const ZipExtractionInfo({
    super.key,
    required this.safety,
    required this.limits,
  });

  final ZipSafetyInfo safety;
  final ZipExtractionLimits limits;

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Extraction limits',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text('Max files: ${limits.maxEntries}'),
        Text('Max total size: ${_formatBytes(limits.maxTotalUncompressedBytes)}'),
        Text('Max single file: ${_formatBytes(limits.maxSingleFileBytes)}'),
        Text('Max path length: ${limits.maxPathLength} chars'),
        const SizedBox(height: 8),
        Text(
          'Archive summary: ${safety.totalEntries} files, '
          '${_formatBytes(safety.totalBytes)} total.',
        ),
        if (safety.nearLimits && !safety.exceedsLimits) ...[
          const SizedBox(height: 8),
          const Text(
            'Warning: Archive is close to extraction limits.',
          ),
        ],
        if (safety.exceedsLimits) ...[
          const SizedBox(height: 8),
          Text(
            safety.refusalMessage ??
                'Archive exceeds extraction limits and will not be extracted.',
            style: TextStyle(color: errorColor),
          ),
        ],
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) {
      return '0 B';
    }
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex += 1;
    }
    final value = size >= 10 ? size.round().toString() : size.toStringAsFixed(1);
    return '$value ${units[unitIndex]}';
  }
}
