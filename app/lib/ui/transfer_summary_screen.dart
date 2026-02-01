import 'package:flutter/material.dart';
import 'package:universaldrop_app/transfer/transfer_summary.dart';
import 'package:universaldrop_app/transfer_manifest.dart';

class TransferSummaryScreen extends StatefulWidget {
  const TransferSummaryScreen({
    super.key,
    required this.summary,
    required this.manifest,
    required this.routeLabel,
    required this.routeDisclosure,
  });

  final TransferSummary summary;
  final TransferManifest manifest;
  final String routeLabel;
  final String routeDisclosure;

  @override
  State<TransferSummaryScreen> createState() => _TransferSummaryScreenState();
}

class _TransferSummaryScreenState extends State<TransferSummaryScreen> {
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final typeLabel = summaryTypeLabel(summary.type);
    return Scaffold(
      appBar: AppBar(title: const Text('Transfer Summary')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _summaryTile('Total size', _formatBytes(summary.totalBytes)),
            _summaryTile('Type', typeLabel),
            _summaryTile('Items', summary.itemCount.toString()),
            _summaryTile('Route', widget.routeLabel),
            Text(
              widget.routeDisclosure,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show filenames and details'),
              subtitle: const Text('May reveal sensitive file names'),
              value: _showDetails,
              onChanged: (value) {
                setState(() {
                  _showDetails = value;
                });
              },
            ),
            if (_showDetails) ..._buildDetails(summary, widget.manifest),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildDetails(
    TransferSummary summary,
    TransferManifest manifest,
  ) {
    final details = <Widget>[];
    if (summary.type == TransferSummaryType.text) {
      final title = manifest.textTitle?.trim();
      if (title != null && title.isNotEmpty) {
        details.add(_summaryTile('Text title', title));
      }
      if (manifest.textLength != null) {
        details.add(
          _summaryTile('Text length', manifest.textLength.toString()),
        );
      }
      return details;
    }
    if (summary.fileNames.isEmpty) {
      details.add(const Text('No filenames available.'));
      return details;
    }
    details.add(const SizedBox(height: 8));
    details.add(const Text('Filenames:'));
    details.add(const SizedBox(height: 8));
    for (final name in summary.fileNames) {
      details.add(Text(name));
    }
    return details;
  }

  Widget _summaryTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(value),
          ),
        ],
      ),
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
