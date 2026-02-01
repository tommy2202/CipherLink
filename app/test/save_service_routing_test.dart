import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/destination_preferences.dart';
import 'package:universaldrop_app/save_service.dart';

void main() {
  test('media + photos routes to gallery saver', () async {
    var galleryCalled = false;
    var appStorageCalled = false;
    var saveAsCalled = false;

    final service = DefaultSaveService(
      gallerySaver: (bytes, name, mime) async {
        galleryCalled = true;
        return SaveOutcome(
          success: true,
          usedFallback: false,
          savedToGallery: true,
        );
      },
      appStorageWriter: (bytes, name) async {
        appStorageCalled = true;
        return '/tmp/$name';
      },
      saveAsHandler: (path, suggestedName) async {
        saveAsCalled = true;
        return '/tmp/$suggestedName';
      },
    );

    final outcome = await service.saveBytes(
      bytes: Uint8List.fromList([1, 2, 3]),
      name: 'photo.jpg',
      mime: 'image/jpeg',
      isMedia: true,
      destination: SaveDestination.photos,
    );

    expect(galleryCalled, isTrue);
    expect(appStorageCalled, isFalse);
    expect(saveAsCalled, isFalse);
    expect(outcome.savedToGallery, isTrue);
  });

  test('non-media routes to files path', () async {
    var galleryCalled = false;
    var appStorageCalled = false;
    var saveAsCalled = false;

    final service = DefaultSaveService(
      gallerySaver: (bytes, name, mime) async {
        galleryCalled = true;
        return SaveOutcome(
          success: true,
          usedFallback: false,
          savedToGallery: true,
        );
      },
      appStorageWriter: (bytes, name) async {
        appStorageCalled = true;
        return '/tmp/$name';
      },
      saveAsHandler: (path, suggestedName) async {
        saveAsCalled = true;
        return '/tmp/$suggestedName';
      },
    );

    final outcome = await service.saveBytes(
      bytes: Uint8List.fromList([4, 5, 6]),
      name: 'note.txt',
      mime: 'text/plain',
      isMedia: false,
      destination: SaveDestination.files,
    );

    expect(galleryCalled, isFalse);
    expect(appStorageCalled, isTrue);
    expect(saveAsCalled, isTrue);
    expect(outcome.savedToGallery, isFalse);
    expect(outcome.success, isTrue);
  });
}
