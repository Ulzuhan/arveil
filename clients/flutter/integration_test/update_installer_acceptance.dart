// Private emulator entry point, never a distribution build. The packaging
// audit rejects its ARVEIL_TEST_ marker. See docs/CLIENT_UPDATES.md.
import 'dart:convert';
import 'dart:io';

import 'package:arveil/src/profile_keys.dart';
import 'package:arveil/src/profile_location.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:arveil/src/rust/frb_generated.dart';
import 'package:arveil/src/updates/controller.dart';
import 'package:arveil/src/updates/manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const stage = String.fromEnvironment('ARVEIL_TEST_UPDATER');
  var result = 'ARVEIL_TEST_UPDATER_FAILED:profile';
  Profile? profile;
  try {
    if (!['before', 'after'].contains(stage)) throw StateError('stage');
    await ArveilRust.init();
    final location = await ProfileLocation.ensure();
    final directory = Directory('${location.parent.path}/installer-acceptance');
    await directory.create(recursive: true);
    final exists = await hasProfile(dir: directory.path);
    if (stage == 'after' && !exists) throw StateError('profile lost');
    final key = await ProfileKeys(
      keyName: 'installer-acceptance-v1',
    ).forProfile(profileExists: exists);
    if (key.state != (exists ? KeyState.present : KeyState.fresh)) {
      throw StateError('key lost');
    }
    profile = await openProfile(dir: directory.path, key: key.value!);
    final marker = File('${directory.path}/expected-identity');
    if (!exists) {
      await profile.createIdentity();
      await marker.writeAsString(
        (await profile.setup()).identityId!,
        flush: true,
      );
    }
    if ((await profile.setup()).identityId != await marker.readAsString()) {
      throw StateError('identity changed');
    }
    result = 'ARVEIL_TEST_UPDATER_OK:profile:$stage';
  } catch (_) {
    // No profile keys, identity or paths in the acceptance signal.
  } finally {
    await profile?.close();
  }
  debugPrint(result);
  runApp(
    MaterialApp(
      home: _Acceptance(result: result, before: stage == 'before'),
    ),
  );
}

class _Acceptance extends StatefulWidget {
  const _Acceptance({required this.result, required this.before});
  final String result;
  final bool before;
  @override
  State<_Acceptance> createState() => _AcceptanceState();
}

class _AcceptanceState extends State<_Acceptance> {
  String status = '';
  bool busy = false;
  Future<void> install() async {
    setState(() => busy = true);
    try {
      final directory = '${(await getTemporaryDirectory()).path}/updates';
      final data =
          jsonDecode(await File('$directory/acceptance.json').readAsString())
              as Map;
      final installer = AndroidUpdateInstaller();
      final device = await installer.device();
      await installer.install(
        File('$directory/update.apk'),
        AndroidUpdate(
          build: data['build'] as int,
          version: '0.1.0',
          minimumSdk: 24,
          applicationId: device.applicationId,
          url: Uri.parse('https://example.org/unused'),
          size: data['size'] as int,
          sha256: data['sha256'] as String,
          notes: 'Emulator acceptance',
          notesUrl: Uri.parse('https://example.org/unused'),
        ),
      );
      status = 'ARVEIL_TEST_UPDATER_OK:installed';
    } on PlatformException catch (error) {
      status = 'ARVEIL_TEST_UPDATER_RESULT:${error.code}';
    } catch (_) {
      status = 'ARVEIL_TEST_UPDATER_FAILED:install';
    }
    debugPrint(status);
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.result),
          Text(status),
          if (widget.before)
            FilledButton(
              onPressed: busy ? null : install,
              child: const Text('Install test update'),
            ),
        ],
      ),
    ),
  );
}
