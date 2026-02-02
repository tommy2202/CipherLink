import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'package:universaldrop_app/limits.dart';

class ZipEntryData {
  ZipEntryData({
    required this.name,
    required this.isFile,
    required this.bytes,
  });

  final String name;
  final bool isFile;
  final Uint8List bytes;
}

class ExtractProgress {
  ExtractProgress({
    required this.filesExtracted,
    required this.totalFiles,
    required this.bytesExtracted,
    required this.totalBytes,
  });

  final int filesExtracted;
  final int totalFiles;
  final int bytesExtracted;
  final int totalBytes;
}

class ExtractResult {
  ExtractResult({
    required this.filesExtracted,
    required this.bytesExtracted,
  });

  final int filesExtracted;
  final int bytesExtracted;
}

class ZipSafetyInfo {
  ZipSafetyInfo({
    required this.totalEntries,
    required this.totalBytes,
    required this.maxEntryBytes,
    required this.maxPathLength,
    required this.exceedsLimits,
    required this.nearLimits,
    this.refusalMessage,
  });

  final int totalEntries;
  final int totalBytes;
  final int maxEntryBytes;
  final int maxPathLength;
  final bool exceedsLimits;
  final bool nearLimits;
  final String? refusalMessage;
}

class ZipSlipException implements Exception {
  ZipSlipException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ZipLimitException implements Exception {
  ZipLimitException(this.message);

  final String message;

  @override
  String toString() => message;
}

const String zipArchiveTooLargeMessage =
    'Archive too large to extract safely.';
const String zipArchiveRefusedMessage =
    'Archive exceeds extraction limits and will not be extracted.';
const String zipArchiveInspectFailedMessage =
    'Archive could not be inspected for safety limits.';

const double zipNearLimitRatioDefault = 0.9;

List<ZipEntryData> decodeZipEntries(
  Uint8List bytes, {
  ZipExtractionLimits limits = const ZipExtractionLimits(),
}) {
  final archive = _decodeArchive(bytes, limits);
  final entries = <ZipEntryData>[];
  for (final file in archive.files) {
    final isFile = file.isFile;
    final content = isFile
        ? Uint8List.fromList(file.content as List<int>)
        : Uint8List(0);
    entries.add(
      ZipEntryData(
        name: file.name,
        isFile: isFile,
        bytes: content,
      ),
    );
  }
  return entries;
}

ZipSafetyInfo analyzeZipBytes(
  Uint8List bytes, {
  ZipExtractionLimits limits = const ZipExtractionLimits(),
  double nearLimitRatio = zipNearLimitRatioDefault,
}) {
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return ZipSafetyInfo(
      totalEntries: 0,
      totalBytes: 0,
      maxEntryBytes: 0,
      maxPathLength: 0,
      exceedsLimits: true,
      nearLimits: false,
      refusalMessage: zipArchiveInspectFailedMessage,
    );
  }
  final entries = archive.files;
  var totalBytes = 0;
  var maxEntryBytes = 0;
  var maxPathLength = 0;
  for (final entry in entries) {
    final normalizedName = entry.name.replaceAll('\\', '/');
    if (normalizedName.length > maxPathLength) {
      maxPathLength = normalizedName.length;
    }
    if (!entry.isFile) {
      continue;
    }
    final size = entry.size;
    if (size > maxEntryBytes) {
      maxEntryBytes = size;
    }
    totalBytes += size;
  }
  final totalEntries = entries.length;
  final exceedsLimits = totalEntries > limits.maxEntries ||
      totalBytes > limits.maxTotalUncompressedBytes ||
      maxEntryBytes > limits.maxSingleFileBytes ||
      maxPathLength > limits.maxPathLength;
  final nearLimits = !exceedsLimits &&
      (totalEntries >= limits.maxEntries * nearLimitRatio ||
          totalBytes >= limits.maxTotalUncompressedBytes * nearLimitRatio ||
          maxEntryBytes >= limits.maxSingleFileBytes * nearLimitRatio ||
          maxPathLength >= limits.maxPathLength * nearLimitRatio);
  return ZipSafetyInfo(
    totalEntries: totalEntries,
    totalBytes: totalBytes,
    maxEntryBytes: maxEntryBytes,
    maxPathLength: maxPathLength,
    exceedsLimits: exceedsLimits,
    nearLimits: nearLimits,
    refusalMessage: exceedsLimits ? zipArchiveRefusedMessage : null,
  );
}

Future<ExtractResult> extractZipBytes({
  required Uint8List bytes,
  required String destinationDir,
  void Function(ExtractProgress progress)? onProgress,
  ZipExtractionLimits limits = const ZipExtractionLimits(),
}) async {
  final dest = Directory(destinationDir);
  if (await dest.exists() == false) {
    if (await File(destinationDir).exists()) {
      throw ZipSlipException('destination_not_directory');
    }
    await dest.create(recursive: true);
  }
  if (!await dest
      .stat()
      .then((stat) => stat.type == FileSystemEntityType.directory)) {
    throw ZipSlipException('destination_not_directory');
  }

  final entries = decodeZipEntries(bytes, limits: limits);
  final totalFiles = entries.where((entry) => entry.isFile).length;
  final totalBytes = entries.fold<int>(
    0,
    (sum, entry) => sum + (entry.isFile ? entry.bytes.length : 0),
  );

  var filesExtracted = 0;
  var bytesExtracted = 0;
  for (final entry in entries) {
    final safePath = _safeJoin(destinationDir, entry.name);
    if (!entry.isFile) {
      await Directory(safePath).create(recursive: true);
      continue;
    }
    final parent = Directory(p.dirname(safePath));
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final file = File(safePath);
    await file.writeAsBytes(entry.bytes, flush: true);
    filesExtracted += 1;
    bytesExtracted += entry.bytes.length;
    onProgress?.call(
      ExtractProgress(
        filesExtracted: filesExtracted,
        totalFiles: totalFiles,
        bytesExtracted: bytesExtracted,
        totalBytes: totalBytes,
      ),
    );
  }

  return ExtractResult(
    filesExtracted: filesExtracted,
    bytesExtracted: bytesExtracted,
  );
}

Future<ExtractResult> extractZipFile({
  required File zipFile,
  required String destinationDir,
  void Function(ExtractProgress progress)? onProgress,
  ZipExtractionLimits limits = const ZipExtractionLimits(),
}) async {
  final bytes = await zipFile.readAsBytes();
  return extractZipBytes(
    bytes: bytes,
    destinationDir: destinationDir,
    onProgress: onProgress,
    limits: limits,
  );
}

String _safeJoin(String root, String entryName) {
  final normalized = entryName.replaceAll('\\', '/');
  if (p.isAbsolute(normalized)) {
    throw ZipSlipException('absolute_path');
  }
  final parts = p.split(normalized);
  if (parts.any((part) => part == '..')) {
    throw ZipSlipException('path_traversal');
  }
  final joined = p.normalize(p.join(root, normalized));
  if (!p.isWithin(root, joined) && joined != root) {
    throw ZipSlipException('path_escape');
  }
  return joined;
}

Archive _decodeArchive(Uint8List bytes, ZipExtractionLimits limits) {
  final archive = ZipDecoder().decodeBytes(bytes);
  _validateArchive(archive, limits);
  return archive;
}

void _validateArchive(Archive archive, ZipExtractionLimits limits) {
  final entries = archive.files;
  if (entries.length > limits.maxEntries) {
    throw ZipLimitException(zipArchiveTooLargeMessage);
  }
  var totalBytes = 0;
  for (final entry in entries) {
    final normalizedName = entry.name.replaceAll('\\', '/');
    if (normalizedName.length > limits.maxPathLength) {
      throw ZipLimitException(zipArchiveTooLargeMessage);
    }
    if (!entry.isFile) {
      continue;
    }
    final entrySize = entry.size;
    if (entrySize < 0 || entrySize > limits.maxSingleFileBytes) {
      throw ZipLimitException(zipArchiveTooLargeMessage);
    }
    if (entrySize > limits.maxTotalUncompressedBytes - totalBytes) {
      throw ZipLimitException(zipArchiveTooLargeMessage);
    }
    totalBytes += entrySize;
  }
}
