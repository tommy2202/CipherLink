import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import 'destination_preferences.dart';

typedef PhotoPermissionRequester = Future<PermissionState> Function();

PhotoPermissionRequester requestPhotoPermission =
    PhotoManager.requestPermissionExtend;

class SaveOutcome {
  SaveOutcome({
    required this.success,
    required this.usedFallback,
    required this.savedToGallery,
    this.localPath,
    this.message,
  });

  final bool success;
  final bool usedFallback;
  final bool savedToGallery;
  final String? localPath;
  final String? message;
}

abstract class SaveService {
  Future<SaveOutcome> saveBytes({
    required Uint8List bytes,
    required String name,
    required String mime,
    required bool isMedia,
    required SaveDestination destination,
  });

  Future<void> openIn(String path);
  Future<String?> saveAs(String path, String suggestedName);
}

class DefaultSaveService implements SaveService {
  @override
  Future<SaveOutcome> saveBytes({
    required Uint8List bytes,
    required String name,
    required String mime,
    required bool isMedia,
    required SaveDestination destination,
  }) async {
    if (isMedia && destination == SaveDestination.photos) {
      final outcome = await _saveToGallery(bytes, name, mime);
      if (outcome.success) {
        return outcome;
      }
      final fallbackPath = await _writeToAppStorage(bytes, name);
      return SaveOutcome(
        success: false,
        usedFallback: true,
        savedToGallery: false,
        localPath: fallbackPath,
        message: outcome.message,
      );
    }

    final localPath = await _writeToAppStorage(bytes, name);
    final savedPath = await saveAs(localPath, name);
    return SaveOutcome(
      success: savedPath != null,
      usedFallback: savedPath == null,
      savedToGallery: false,
      localPath: savedPath ?? localPath,
      message: savedPath == null ? 'save_as_cancelled' : null,
    );
  }

  @override
  Future<void> openIn(String path) async {
    await Share.shareXFiles([XFile(path)]);
  }

  @override
  Future<String?> saveAs(String path, String suggestedName) async {
    final savePath = await getSavePath(suggestedName: suggestedName);
    if (savePath == null) {
      return null;
    }
    final file = File(path);
    await file.copy(savePath);
    return savePath;
  }

  Future<SaveOutcome> _saveToGallery(
    Uint8List bytes,
    String name,
    String mime,
  ) async {
    final permission = await requestPhotoPermission();
    if (!permission.isAuth) {
      return SaveOutcome(
        success: false,
        usedFallback: true,
        savedToGallery: false,
        message: 'permission_denied',
      );
    }

    if (mime.startsWith('image/')) {
      final entity = await PhotoManager.editor.saveImage(
        bytes,
        title: name,
      );
      if (entity != null) {
        return SaveOutcome(
          success: true,
          usedFallback: false,
          savedToGallery: true,
        );
      }
    } else if (mime.startsWith('video/')) {
      final path = await _writeToTemp(bytes, name);
      final entity = await PhotoManager.editor.saveVideo(path);
      if (entity != null) {
        return SaveOutcome(
          success: true,
          usedFallback: false,
          savedToGallery: true,
        );
      }
    }

    return SaveOutcome(
      success: false,
      usedFallback: true,
      savedToGallery: false,
      message: 'gallery_save_failed',
    );
  }

  Future<String> _writeToAppStorage(Uint8List bytes, String name) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, name);
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<String> _writeToTemp(Uint8List bytes, String name) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, name);
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }
}
