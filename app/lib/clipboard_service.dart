import 'package:flutter/services.dart';

abstract class ClipboardService {
  Future<void> copyText(String text);
  Future<String?> readText();
}

class SystemClipboardService implements ClipboardService {
  const SystemClipboardService();

  @override
  Future<void> copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  @override
  Future<String?> readText() async {
    final data = await Clipboard.getData('text/plain');
    return data?.text;
  }
}

Future<void> copyToClipboard(ClipboardService service, String text) {
  return service.copyText(text);
}
