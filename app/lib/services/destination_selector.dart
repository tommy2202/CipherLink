import 'package:universaldrop_app/destination_preferences.dart';
import 'package:universaldrop_app/destination_rules.dart';
import 'package:universaldrop_app/transfer_manifest.dart';

class DestinationChoice {
  DestinationChoice({
    required this.destination,
    required this.remember,
  });

  final SaveDestination destination;
  final bool remember;
}

class DestinationSelector {
  DestinationSelector(this.store);

  final DestinationPreferenceStore store;

  Future<SaveDestination> defaultDestination(TransferManifest manifest) async {
    final prefs = await store.load();
    return defaultDestinationForManifest(manifest, prefs);
  }

  Future<void> rememberChoice(
    TransferManifest manifest,
    DestinationChoice choice,
  ) async {
    if (!choice.remember) {
      return;
    }
    final prefs = await store.load();
    if (isMediaManifest(manifest)) {
      await store.save(
        prefs.copyWith(defaultMediaDestination: choice.destination),
      );
    } else {
      await store.save(
        prefs.copyWith(defaultFileDestination: choice.destination),
      );
    }
  }
}
