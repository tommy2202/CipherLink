class TransferManifestFile {
  TransferManifestFile({
    required this.name,
    required this.bytes,
    this.mime,
  });

  final String name;
  final int bytes;
  final String? mime;

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'bytes': bytes,
      if (mime != null) 'mime': mime,
    };
  }

  factory TransferManifestFile.fromJson(Map<String, dynamic> json) {
    return TransferManifestFile(
      name: json['name']?.toString() ?? '',
      bytes: json['bytes'] is int ? json['bytes'] as int : 0,
      mime: json['mime']?.toString(),
    );
  }
}

const String payloadKindFile = 'file';
const String payloadKindZip = 'zip';
const String payloadKindAlbum = 'album';
const String payloadKindText = 'text';
const String textMimePlain = 'text/plain; charset=utf-8';

class TransferManifest {
  TransferManifest({
    required this.transferId,
    required this.payloadKind,
    required this.totalBytes,
    required this.chunkSize,
    required this.files,
    this.textTitle,
    this.textMime,
    this.textLength,
  });

  final String transferId;
  final String payloadKind;
  final int totalBytes;
  final int chunkSize;
  final List<TransferManifestFile> files;
  final String? textTitle;
  final String? textMime;
  final int? textLength;

  Map<String, dynamic> toJson() {
    return {
      'transfer_id': transferId,
      'payload_kind': payloadKind,
      'total_bytes': totalBytes,
      'chunk_size': chunkSize,
      if (files.isNotEmpty)
        'files': files.map((file) => file.toJson()).toList(),
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
    return TransferManifest(
      transferId: json['transfer_id']?.toString() ?? '',
      payloadKind: payloadKind,
      totalBytes: json['total_bytes'] is int ? json['total_bytes'] as int : 0,
      chunkSize: json['chunk_size'] is int ? json['chunk_size'] as int : 0,
      files: files,
      textTitle: payloadKind == payloadKindText
          ? json['text_title']?.toString()
          : null,
      textMime: payloadKind == payloadKindText
          ? json['text_mime']?.toString()
          : null,
      textLength: payloadKind == payloadKindText
          ? (json['text_length'] is int ? json['text_length'] as int : 0)
          : null,
    );
  }
}
