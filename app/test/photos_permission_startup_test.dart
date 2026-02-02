import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:universaldrop_app/main.dart';
import 'package:universaldrop_app/save_service.dart';

void main() {
  testWidgets('does not request photos permission on startup', (tester) async {
    var requested = false;
    final originalRequester = requestPhotoPermission;
    requestPhotoPermission = () async {
      requested = true;
      return PermissionState.denied;
    };
    addTearDown(() {
      requestPhotoPermission = originalRequester;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          runStartupTasks: false,
        ),
      ),
    );
    await tester.pump();

    expect(requested, isFalse);
  });
}
