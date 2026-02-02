import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default notification strings are privacy-safe', () async {
    final source = await File(
      'lib/transfer/background_transfer.dart',
    ).readAsString();
    final matches = RegExp(
      r"const String (_[a-zA-Z0-9]+) = '([^']*)';",
    ).allMatches(source);
    final values = <String, String>{};
    for (final match in matches) {
      values[match.group(1)!] = match.group(2)!;
    }

    const requiredKeys = [
      '_runningTitle',
      '_runningBody',
      '_completeTitle',
      '_completeBody',
      '_errorTitle',
      '_errorBody',
    ];
    for (final key in requiredKeys) {
      expect(values.containsKey(key), isTrue, reason: 'missing $key');
    }

    final forbidden = RegExp(r'(filename|file name|sender|from)', caseSensitive: false);
    for (final key in requiredKeys) {
      final value = values[key] ?? '';
      expect(value, isNotEmpty, reason: '$key should not be empty');
      expect(
        forbidden.hasMatch(value),
        isFalse,
        reason: '$key contains forbidden terms',
      );
    }
  });
}
