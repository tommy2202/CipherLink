import 'transfer_manifest.dart';
import 'destination_preferences.dart';

bool isMediaManifest(TransferManifest manifest) {
  if (manifest.payloadKind == payloadKindText) {
    return false;
  }
  if (manifest.files.isEmpty) {
    return false;
  }
  final mime = manifest.files.first.mime;
  if (mime == null) {
    return false;
  }
  return mime.startsWith('image/') || mime.startsWith('video/');
}

SaveDestination defaultDestinationForManifest(
  TransferManifest manifest,
  DestinationPreferences prefs,
) {
  if (isMediaManifest(manifest)) {
    return prefs.defaultMediaDestination ?? SaveDestination.photos;
  }
  return prefs.defaultFileDestination ?? SaveDestination.files;
}
