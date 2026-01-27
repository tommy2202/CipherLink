import 'package:flutter/material.dart';

void main() {
  runApp(const UniversalDropApp());
}

class UniversalDropApp extends StatelessWidget {
  const UniversalDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UniversalDrop',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: Center(
          child: Text('UniversalDrop client scaffold'),
        ),
      ),
    );
  }
}
