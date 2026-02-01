import 'package:universaldrop_app/transfer_manifest.dart';

enum TransferSummaryType {
  text,
  file,
  zip,
  album,
}

class TransferSummary {
  const TransferSummary({
    required this.totalBytes,
    required this.itemCount,
    required this.type,
    required this.fileNames,
  });

  final int totalBytes;
  final int itemCount;
  final TransferSummaryType type;
  final List<String> fileNames;
}

TransferSummary buildTransferSummary(TransferManifest manifest) {
  final type = _summaryType(manifest);
  final itemCount = _summaryItemCount(manifest, type);
  final fileNames = manifest.files.map((file) => file.relativePath).toList();
  return TransferSummary(
    totalBytes: manifest.totalBytes,
    itemCount: itemCount,
    type: type,
    fileNames: fileNames,
  );
}

String summaryTypeLabel(TransferSummaryType type) {
  switch (type) {
    case TransferSummaryType.text:
      return 'Text';
    case TransferSummaryType.file:
      return 'File';
    case TransferSummaryType.zip:
      return 'ZIP';
    case TransferSummaryType.album:
      return 'Album';
  }
}

TransferSummaryType _summaryType(TransferManifest manifest) {
  if (manifest.payloadKind == payloadKindText) {
    return TransferSummaryType.text;
  }
  if (manifest.packagingMode == packagingModeAlbum) {
    return TransferSummaryType.album;
  }
  if (manifest.packagingMode == packagingModeZip) {
    return TransferSummaryType.zip;
  }
  return TransferSummaryType.file;
}

int _summaryItemCount(TransferManifest manifest, TransferSummaryType type) {
  if (type == TransferSummaryType.text) {
    return 1;
  }
  if (type == TransferSummaryType.album) {
    return manifest.albumItemCount ?? manifest.files.length;
  }
  if (manifest.files.isNotEmpty) {
    return manifest.files.length;
  }
  return 1;
}
