import 'package:universaldrop_app/destination_preferences.dart';
import 'package:universaldrop_app/transfer_manifest.dart';

bool isMediaManifest(TransferManifest manifest) {
  if (manifest.packagingMode == packagingModeZip) {
    return false;
  }
  if (manifest.packagingMode == packagingModeAlbum) {
    return true;
  }
  if (manifest.payloadKind == payloadKindText) {
    return false;
  }
  if (manifest.files.isEmpty) {
    return false;
  }
  return manifest.files.any((file) {
    if (file.mediaType == mediaTypeImage || file.mediaType == mediaTypeVideo) {
      return true;
    }
    final mime = file.mime;
    if (mime == null) {
      return false;
    }
    return mime.startsWith('image/') || mime.startsWith('video/');
  });
}

SaveDestination defaultDestinationForManifest(
  TransferManifest manifest,
  DestinationPreferences prefs,
) {
  if (manifest.packagingMode == packagingModeZip) {
    return SaveDestination.files;
  }
  if (manifest.packagingMode == packagingModeAlbum) {
    return SaveDestination.photos;
  }
  if (isMediaManifest(manifest)) {
    return prefs.defaultMediaDestination ?? SaveDestination.photos;
  }
  return prefs.defaultFileDestination ?? SaveDestination.files;
}
