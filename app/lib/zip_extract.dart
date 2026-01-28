import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

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

class ZipSlipException implements Exception {
  ZipSlipException(this.message);

  final String message;

  @override
  String toString() => message;
}

List<ZipEntryData> decodeZipEntries(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final entries = <ZipEntryData>[];
  for (final file in archive.files) {
    final isFile = file.isFile;
    final content = isFile ? Uint8List.fromList(file.content as List<int>) : Uint8List(0);
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

Future<ExtractResult> extractZipBytes({
  required Uint8List bytes,
  required String destinationDir,
  void Function(ExtractProgress progress)? onProgress,
}) async {
  final dest = Directory(destinationDir);
  if (await dest.exists() == false) {
    if (await File(destinationDir).exists()) {
      throw ZipSlipException('destination_not_directory');
    }
    await dest.create(recursive: true);
  }
  if (!await dest.stat().then((stat) => stat.type == FileSystemEntityType.directory)) {
    throw ZipSlipException('destination_not_directory');
  }

  final entries = decodeZipEntries(bytes);
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
}) async {
  final bytes = await zipFile.readAsBytes();
  return extractZipBytes(
    bytes: bytes,
    destinationDir: destinationDir,
    onProgress: onProgress,
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
