// Private release-mode acceptance entry point. Never distribute this build.
// Run "create" on a disposable installation, then "reopen" in a higher-build
// APK signed by the same key. The expected value is a public identity ID;
// the database key is never written outside platform secure storage.
import 'dart:io';

import 'package:arveil/src/profile_keys.dart';
import 'package:arveil/src/profile_location.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:arveil/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const stage = String.fromEnvironment('ARVEIL_TEST_UPGRADE');
  var result = 'ARVEIL_TEST_UPGRADE_FAILED';
  Profile? profile;
  try {
    if (stage != 'create' && stage != 'reopen') throw StateError('stage');
    await ArveilRust.init();
    final directory = await ProfileLocation.ensure();
    final exists = await hasProfile(dir: directory.path);
    if (exists != (stage == 'reopen')) throw StateError('profile existence');
    final key = await ProfileKeys().forProfile(profileExists: exists);
    final expected = stage == 'create' ? KeyState.fresh : KeyState.present;
    if (key.state != expected) throw StateError('key state');
    profile = await openProfile(dir: directory.path, key: key.value!);
    final marker = File('${directory.parent.path}/upgrade-acceptance-identity');
    if (stage == 'create') {
      await profile.createIdentity();
      final identity = (await profile.setup()).identityId;
      if (identity == null) throw StateError('identity');
      await marker.writeAsString(identity, flush: true);
    } else {
      final identity = (await profile.setup()).identityId;
      if (identity == null || identity != await marker.readAsString()) {
        throw StateError('identity changed');
      }
    }
    await profile.close();
    profile = null;
    result = 'ARVEIL_TEST_UPGRADE_OK:$stage';
  } catch (_) {
    // A failure signal must not include keys, platform paths or diagnostics.
  } finally {
    await profile?.close();
  }
  debugPrint(result);
  runApp(
    MaterialApp(
      home: Scaffold(body: Center(child: Text(result))),
    ),
  );
}
