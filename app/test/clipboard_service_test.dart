import 'package:flutter_test/flutter_test.dart';
import 'package:universaldrop_app/clipboard_service.dart';

void main() {
  test('copy to clipboard uses service', () async {
    final fake = FakeClipboardService();
    await copyToClipboard(fake, 'hello');
    expect(fake.lastCopied, equals('hello'));
  });
}

class FakeClipboardService implements ClipboardService {
  String? lastCopied;
  String? clipboardText;

  @override
  Future<void> copyText(String text) async {
    lastCopied = text;
    clipboardText = text;
  }

  @override
  Future<String?> readText() async => clipboardText;
}
