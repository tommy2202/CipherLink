import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class TrustStore {
  const TrustStore();

  static const String _fingerprintsKey = 'trusted_fingerprints';
  static const String _nicknamesKey = 'trusted_fingerprint_nicknames';

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
      await _removeNickname(normalized);
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

  Future<Map<String, String>> loadNicknames() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_nicknamesKey);
    if (raw == null || raw.isEmpty) {
      return <String, String>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return <String, String>{};
      }
      final entries = <String, String>{};
      decoded.forEach((key, value) {
        final fingerprint = key.toString().trim();
        final nickname = value?.toString().trim() ?? '';
        if (fingerprint.isEmpty || nickname.isEmpty) {
          return;
        }
        entries[fingerprint] = nickname;
      });
      return entries;
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<Map<String, String>> setNickname(
    String fingerprint,
    String nickname,
  ) async {
    final normalized = fingerprint.trim();
    if (normalized.isEmpty) {
      return loadNicknames();
    }
    final fingerprints = await loadFingerprints();
    if (!fingerprints.contains(normalized)) {
      return loadNicknames();
    }
    final trimmed = nickname.trim();
    final nicknames = await loadNicknames();
    if (trimmed.isEmpty) {
      nicknames.remove(normalized);
    } else {
      nicknames[normalized] = trimmed;
    }
    await _saveNicknames(nicknames);
    return nicknames;
  }

  Future<void> _removeNickname(String fingerprint) async {
    final nicknames = await loadNicknames();
    if (nicknames.remove(fingerprint)) {
      await _saveNicknames(nicknames);
    }
  }

  Future<void> _saveNicknames(Map<String, String> nicknames) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = <String, String>{};
    for (final entry in nicknames.entries) {
      final fingerprint = entry.key.trim();
      final nickname = entry.value.trim();
      if (fingerprint.isEmpty || nickname.isEmpty) {
        continue;
      }
      normalized[fingerprint] = nickname;
    }
    await prefs.setString(_nicknamesKey, jsonEncode(normalized));
  }
}
