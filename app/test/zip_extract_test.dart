import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:universaldrop_app/zip_extract.dart';

void main() {
  test('zip slip entries are rejected', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('../evil.txt', 4, [1, 2, 3, 4]));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final dir = Directory.systemTemp.createTempSync();
    await expectLater(
      extractZipBytes(bytes: bytes, destinationDir: dir.path),
      throwsA(isA<ZipSlipException>()),
    );
  });

  test('normal zip extraction produces expected files', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('folder/hello.txt', 5, [104, 101, 108, 108, 111]))
      ..addFile(ArchiveFile('root.txt', 4, [116, 101, 115, 116]));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final dir = Directory.systemTemp.createTempSync();
    final result = await extractZipBytes(bytes: bytes, destinationDir: dir.path);
    expect(result.filesExtracted, 2);
    expect(File(p.join(dir.path, 'folder', 'hello.txt')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'root.txt')).existsSync(), isTrue);
  });

  test('extraction failure does not delete original zip', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('file.txt', 4, [116, 101, 115, 116]));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final zipFile = File(p.join(Directory.systemTemp.path, 'test.zip'));
    await zipFile.writeAsBytes(bytes, flush: true);
    final destFile = File(p.join(Directory.systemTemp.path, 'not_a_dir'));
    await destFile.writeAsString('x');

    await expectLater(
      extractZipFile(zipFile: zipFile, destinationDir: destFile.path),
      throwsA(isA<ZipSlipException>()),
    );
    expect(zipFile.existsSync(), isTrue);
  });
}
