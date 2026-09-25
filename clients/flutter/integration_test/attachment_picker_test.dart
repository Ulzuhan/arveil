// Opt-in, interactive Android acceptance; see the Flutter README.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:arveil/src/attachment_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android native attachment selection and explicit save dialogs',
    (tester) async {
      const files = AttachmentFiles();
      final bytes = Uint8List.fromList(
        utf8.encode('Arveil attachment picker acceptance.\n'),
      );
      // Use a disposable emulator without prior file-picker activity.
      final cache = Directory('${Directory.systemTemp.path}/file_picker');
      expect(await cache.exists(), isFalse);
      Future<void> step(String label) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: Center(child: Text(label))),
          ),
        );
        await tester.pumpAndSettle();
        debugPrint('ARVEIL_PICKER_$label');
      }

      await step('SELECT');
      final picked = await files.open();
      expect(picked, isNotNull);
      expect(picked!.name, 'arveil-picker-fixture.txt');
      expect(picked.bytes, bytes);
      expect(await cache.exists(), isFalse);
      await step('CANCEL_OPEN');
      expect(await files.open(), isNull);
      expect(await cache.exists(), isFalse);
      await step('CANCEL_SAVE');
      expect(await files.save('arveil-picker-export.txt', bytes), isFalse);
      await step('SAVE');
      expect(await files.save('arveil-picker-export.txt', bytes), isTrue);
      expect(await cache.exists(), isFalse);
      await step('DONE');
    },
    skip:
        !Platform.isAndroid ||
        !const bool.fromEnvironment('ARVEIL_TEST_NATIVE_PICKER'),
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
