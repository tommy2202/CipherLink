import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'transfer_manifest.dart';
import 'transfer_coordinator.dart';

class TransferPackage {
  TransferPackage({
    required this.bytes,
    required this.entries,
    required this.outputName,
  });

  final Uint8List bytes;
  final List<TransferManifestFile> entries;
  final String outputName;
}

TransferPackage buildZipPackage({
  required List<TransferFile> files,
  required String packageTitle,
  required bool albumMode,
}) {
  final archive = Archive();
  final entries = <TransferManifestFile>[];
  final usedNames = <String, int>{};
  for (final file in files) {
    final baseName = file.name.isEmpty ? 'file' : file.name;
    final relativePath = _uniqueName(baseName, usedNames);
    final archivePath = albumMode ? 'media/$relativePath' : relativePath;
    archive.addFile(
      ArchiveFile(archivePath, file.bytes.length, file.bytes),
    );
    entries.add(
      TransferManifestFile(
        relativePath: relativePath,
        mediaType: mediaTypeFromMime(file.mimeType),
        sizeBytes: file.bytes.length,
        originalFilename: file.name,
        mime: file.mimeType,
      ),
    );
  }

  if (albumMode) {
    final albumManifest = {
      'album_title': packageTitle,
      'album_item_count': entries.length,
      'items': entries
          .map((entry) => {
                'relative_path': entry.relativePath,
                'media_type': entry.mediaType,
                'size_bytes': entry.sizeBytes,
                'original_filename': entry.originalFilename,
                'mime': entry.mime,
              })
          .toList(),
    };
    final albumBytes = utf8.encode(jsonEncode(albumManifest));
    archive.addFile(
      ArchiveFile('ALBUM_MANIFEST.json', albumBytes.length, albumBytes),
    );
  }

  final encoder = ZipEncoder();
  final data = encoder.encode(archive, level: 0);
  if (data == null) {
    throw StateError('Failed to create zip package');
  }
  final outputName = '$packageTitle.zip';
  return TransferPackage(
    bytes: Uint8List.fromList(data),
    entries: entries,
    outputName: outputName,
  );
}

String _uniqueName(String base, Map<String, int> used) {
  final normalized = base.replaceAll('/', '_').replaceAll('\\', '_');
  final count = used[normalized];
  if (count == null) {
    used[normalized] = 1;
    return normalized;
  }
  used[normalized] = count + 1;
  return '${normalized}_$count';
}
