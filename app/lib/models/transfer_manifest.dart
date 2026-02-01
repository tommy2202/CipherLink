class TransferManifestFile {
  TransferManifestFile({
    required this.relativePath,
    required this.mediaType,
    required this.sizeBytes,
    this.originalFilename,
    this.mime,
  });

  final String relativePath;
  final String mediaType;
  final int sizeBytes;
  final String? originalFilename;
  final String? mime;

  Map<String, dynamic> toJson() {
    return {
      'relative_path': relativePath,
      'media_type': mediaType,
      'size_bytes': sizeBytes,
      if (originalFilename != null) 'original_filename': originalFilename,
      if (mime != null) 'mime': mime,
    };
  }

  factory TransferManifestFile.fromJson(Map<String, dynamic> json) {
    final relative =
        json['relative_path']?.toString() ?? json['name']?.toString() ?? '';
    final size = json['size_bytes'];
    final legacyBytes = json['bytes'];
    final bytesValue =
        size is int ? size : (legacyBytes is int ? legacyBytes : 0);
    final mediaType = json['media_type']?.toString() ??
        mediaTypeFromMime(json['mime']?.toString());
    return TransferManifestFile(
      relativePath: relative,
      mediaType: mediaType,
      sizeBytes: bytesValue,
      originalFilename: json['original_filename']?.toString(),
      mime: json['mime']?.toString(),
    );
  }
}

const String payloadKindFile = 'file';
const String payloadKindZip = 'zip';
const String payloadKindAlbum = 'album';
const String payloadKindText = 'text';
const String packagingModeOriginals = 'originals';
const String packagingModeZip = 'zip';
const String packagingModeAlbum = 'album';
const String mediaTypeImage = 'image';
const String mediaTypeVideo = 'video';
const String mediaTypeOther = 'other';
const String textMimePlain = 'text/plain; charset=utf-8';

class TransferManifest {
  TransferManifest({
    required this.transferId,
    required this.payloadKind,
    required this.packagingMode,
    this.packageTitle,
    required this.totalBytes,
    required this.chunkSize,
    required this.files,
    this.outputFilename,
    this.albumTitle,
    this.albumItemCount,
    this.textTitle,
    this.textMime,
    this.textLength,
  });

  final String transferId;
  final String payloadKind;
  final String packagingMode;
  final String? packageTitle;
  final int totalBytes;
  final int chunkSize;
  final List<TransferManifestFile> files;
  final String? outputFilename;
  final String? albumTitle;
  final int? albumItemCount;
  final String? textTitle;
  final String? textMime;
  final int? textLength;

  Map<String, dynamic> toJson() {
    return {
      'transfer_id': transferId,
      'payload_kind': payloadKind,
      'packaging_mode': packagingMode,
      if (packageTitle != null) 'package_title': packageTitle,
      'total_bytes': totalBytes,
      'chunk_size': chunkSize,
      if (files.isNotEmpty)
        'files': files.map((file) => file.toJson()).toList(),
      if (payloadKind == payloadKindZip && outputFilename != null)
        'output_filename': outputFilename,
      if (payloadKind == payloadKindAlbum && albumTitle != null)
        'album_title': albumTitle,
      if (payloadKind == payloadKindAlbum && albumItemCount != null)
        'album_item_count': albumItemCount,
      if (payloadKind == payloadKindText) 'text_title': textTitle,
      if (payloadKind == payloadKindText) 'text_mime': textMime ?? textMimePlain,
      if (payloadKind == payloadKindText)
        'text_length': textLength ?? totalBytes,
    };
  }

  factory TransferManifest.fromJson(Map<String, dynamic> json) {
    final filesJson = json['files'];
    final files = <TransferManifestFile>[];
    if (filesJson is List) {
      for (final entry in filesJson) {
        if (entry is Map<String, dynamic>) {
          files.add(TransferManifestFile.fromJson(entry));
        }
      }
    }
    final payloadKind = json['payload_kind']?.toString() ?? payloadKindFile;
    final packagingMode =
        json['packaging_mode']?.toString() ?? packagingModeOriginals;
    return TransferManifest(
      transferId: json['transfer_id']?.toString() ?? '',
      payloadKind: payloadKind,
      packagingMode: packagingMode,
      packageTitle: json['package_title']?.toString(),
      totalBytes: json['total_bytes'] is int
          ? json['total_bytes'] as int
          : int.tryParse(json['total_bytes']?.toString() ?? '') ?? 0,
      chunkSize: json['chunk_size'] is int
          ? json['chunk_size'] as int
          : int.tryParse(json['chunk_size']?.toString() ?? '') ?? 0,
      files: files,
      outputFilename: json['output_filename']?.toString(),
      albumTitle: json['album_title']?.toString(),
      albumItemCount: json['album_item_count'] is int
          ? json['album_item_count'] as int
          : int.tryParse(json['album_item_count']?.toString() ?? ''),
      textTitle: json['text_title']?.toString(),
      textMime: json['text_mime']?.toString(),
      textLength: json['text_length'] is int
          ? json['text_length'] as int
          : int.tryParse(json['text_length']?.toString() ?? ''),
    );
  }
}

String mediaTypeFromMime(String? mime) {
  if (mime == null) {
    return mediaTypeOther;
  }
  if (mime.startsWith('image/')) {
    return mediaTypeImage;
  }
  if (mime.startsWith('video/')) {
    return mediaTypeVideo;
  }
  return mediaTypeOther;
}
