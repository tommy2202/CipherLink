import 'package:flutter/material.dart';

import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UniversalDropApp());
}

export 'ui/app.dart';
export 'ui/home_screen.dart';
