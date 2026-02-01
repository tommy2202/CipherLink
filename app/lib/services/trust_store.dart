import 'package:shared_preferences/shared_preferences.dart';

class TrustStore {
  const TrustStore();

  static const String _fingerprintsKey = 'trusted_fingerprints';

  Future<Set<String>> loadFingerprints() async {
    final prefs = await SharedPreferences.getInstance();
    final items = prefs.getStringList(_fingerprintsKey) ?? const [];
    return items.where((item) => item.trim().isNotEmpty).toSet();
  }

  Future<Set<String>> addFingerprint(String fingerprint) async {
    final normalized = fingerprint.trim();
    if (normalized.isEmpty) {
      return loadFingerprints();
    }
    final fingerprints = await loadFingerprints();
    if (fingerprints.add(normalized)) {
      await _save(fingerprints);
    }
    return fingerprints;
  }

  Future<Set<String>> removeFingerprint(String fingerprint) async {
    final normalized = fingerprint.trim();
    final fingerprints = await loadFingerprints();
    if (normalized.isNotEmpty && fingerprints.remove(normalized)) {
      await _save(fingerprints);
    }
    return fingerprints;
  }

  Future<bool> isTrusted(String fingerprint) async {
    final normalized = fingerprint.trim();
    if (normalized.isEmpty) {
      return false;
    }
    final fingerprints = await loadFingerprints();
    return fingerprints.contains(normalized);
  }

  Future<void> _save(Set<String> fingerprints) async {
    final prefs = await SharedPreferences.getInstance();
    final sorted = fingerprints.toList()..sort();
    await prefs.setStringList(_fingerprintsKey, sorted);
  }
}
