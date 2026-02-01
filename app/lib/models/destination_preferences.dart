import 'package:shared_preferences/shared_preferences.dart';

enum SaveDestination { photos, files }

class DestinationPreferences {
  const DestinationPreferences({
    this.defaultMediaDestination,
    this.defaultFileDestination,
  });

  final SaveDestination? defaultMediaDestination;
  final SaveDestination? defaultFileDestination;

  DestinationPreferences copyWith({
    SaveDestination? defaultMediaDestination,
    SaveDestination? defaultFileDestination,
  }) {
    return DestinationPreferences(
      defaultMediaDestination:
          defaultMediaDestination ?? this.defaultMediaDestination,
      defaultFileDestination: defaultFileDestination ?? this.defaultFileDestination,
    );
  }
}

abstract class DestinationPreferenceStore {
  Future<DestinationPreferences> load();
  Future<void> save(DestinationPreferences prefs);
}

class SharedPreferencesDestinationStore implements DestinationPreferenceStore {
  static const _mediaKey = 'defaultMediaDestination';
  static const _fileKey = 'defaultFileDestination';

  @override
  Future<DestinationPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    return DestinationPreferences(
      defaultMediaDestination: _fromString(prefs.getString(_mediaKey)),
      defaultFileDestination: _fromString(prefs.getString(_fileKey)),
    );
  }

  @override
  Future<void> save(DestinationPreferences prefs) async {
    final storage = await SharedPreferences.getInstance();
    if (prefs.defaultMediaDestination != null) {
      await storage.setString(
        _mediaKey,
        prefs.defaultMediaDestination!.name,
      );
    }
    if (prefs.defaultFileDestination != null) {
      await storage.setString(
        _fileKey,
        prefs.defaultFileDestination!.name,
      );
    }
  }

  SaveDestination? _fromString(String? value) {
    if (value == null) {
      return null;
    }
    for (final item in SaveDestination.values) {
      if (item.name == value) {
        return item;
      }
    }
    return null;
  }
}
