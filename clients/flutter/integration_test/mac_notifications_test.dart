// Interactive, disposable macOS OS-integration acceptance. Does not open a profile.
import 'dart:io';
import 'package:arveil/src/attachment_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Mac notification delivery, hidden window and temporary external files',
    (tester) async {
      const channel = MethodChannel('io.github.ulzuhan.arveil/notifications');
      final previous = await channel.invokeMapMethod<String, Object?>('status');
      addTearDown(() async {
        await channel.invokeMethod<void>('acceptanceOpenWindow');
        await channel.invokeMethod<void>('profile', {'open': false});
        await channel.invokeMethod<void>('configure', previous);
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Arveil · native acceptance')),
          ),
        ),
      );
      await channel.invokeMethod<void>('profile', {
        'open': true,
        'openLabel': 'Open Arveil',
        'quitLabel': 'Quit Arveil',
      });
      await channel.invokeMethod<void>('configure', {
        'enabled': false,
        'background': true,
      });
      await channel.invokeMethod<void>('acceptanceCloseWindow');
      final hidden = await channel.invokeMapMethod<String, Object?>(
        'acceptanceInspect',
      );
      expect(hidden?['visible'], false);
      expect(hidden?['background'], true);
      await channel.invokeMethod<void>('acceptanceOpenWindow');

      // Each harmless fixture gets a private copy and a real external app launch.
      final root = Directory('${Directory.systemTemp.path}/attachment-open');
      final before = await root.exists()
          ? await root.list().map((e) => e.path).toSet()
          : <String>{};
      final name =
          'arveil-native-viewer-${DateTime.now().microsecondsSinceEpoch}.txt';
      final bytes = Uint8List.fromList(
        'Arveil external viewer acceptance. No personal data.\n'.codeUnits,
      );
      expect(await const AttachmentFiles().openExternal(name, bytes), true);
      final created = (await root.list().toList())
          .where((e) => !before.contains(e.path))
          .single;
      final file = File('${created.path}/$name');
      expect(await file.readAsBytes(), bytes);
      expect((await file.stat()).mode & 0x1ff, 0x180); // 0600
      expect((await created.stat()).mode & 0x1ff, 0x1c0); // 0700
      // Expire only our fixture. The next opening runs the normal cleanup path.
      final expired = await Process.run('/usr/bin/touch', [
        '-t',
        '200001010000',
        created.path,
      ]);
      expect(expired.exitCode, 0);
      expect(await const AttachmentFiles().openExternal(name, bytes), true);
      expect(await Directory(created.path).exists(), false);
      addTearDown(() async {
        if (await root.exists()) {
          for (final entry in await root.list().toList()) {
            if (!before.contains(entry.path) &&
                await File('${entry.path}/$name').exists()) {
              await entry.delete(recursive: true);
            }
          }
        }
      });
      debugPrint('ARVEIL_NATIVE_FILES_WINDOW');
      if (!const bool.fromEnvironment('ARVEIL_TEST_MAC_NOTIFICATIONS')) return;
      debugPrint('ARVEIL_NATIVE_PERMISSION');
      final allowed = await channel.invokeMapMethod<String, Object?>(
        'configure',
        {'enabled': true, 'background': true},
      );
      expect(
        allowed?['enabled'],
        true,
        reason: 'Allow the OS notification permission for this acceptance run.',
      );
      await channel.invokeMethod<void>('acceptanceCloseWindow');
      expect(
        await channel.invokeMethod<bool>('show', {
          'token': 'a' * 64,
          'title': 'Arveil',
          'body': 'Native notification acceptance · generic activity only',
        }),
        true,
      );
      var delivered = false;
      for (var i = 0; i < 100; i++) {
        final state = await channel.invokeMapMethod<String, Object?>(
          'acceptanceInspect',
        );
        if (state?['delivered'] == 1) {
          delivered = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        delivered,
        true,
        reason: 'The macOS notification center did not retain the notice.',
      );
      debugPrint('ARVEIL_NATIVE_DELIVERED');
      // Closing a profile is a visible-window action. Reopen before removing the
      // final background keep-alive so macOS keeps the test engine available.
      await channel.invokeMethod<void>('acceptanceOpenWindow');
      await channel.invokeMethod<void>('profile', {'open': false});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final cleared = await channel.invokeMapMethod<String, Object?>(
        'acceptanceInspect',
      );
      expect(cleared?['delivered'], 0);
      expect(cleared?['background'], false);
    },
    skip:
        !Platform.isMacOS ||
        !(const bool.fromEnvironment('ARVEIL_TEST_MAC_NATIVE') ||
            const bool.fromEnvironment('ARVEIL_TEST_MAC_NOTIFICATIONS')),
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
