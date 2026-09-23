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
  var checkpoint = 'stage';
  Profile? profile;
  try {
    if (stage != 'create' && stage != 'reopen') throw StateError('stage');
    checkpoint = 'native-init';
    await ArveilRust.init();
    checkpoint = 'location';
    final location = await ProfileLocation.ensure();
    final directory = Directory('${location.parent.path}/upgrade-acceptance');
    await directory.create(recursive: true);
    await ProfileLocation.excludeFromBackup(directory);
    final exists = await hasProfile(dir: directory.path);
    checkpoint = 'profile-existence';
    if (exists != (stage == 'reopen')) throw StateError('profile existence');
    checkpoint = 'key-store';
    final key = await ProfileKeys(
      keyName: 'upgrade-acceptance-key-v1',
    ).forProfile(profileExists: exists);
    checkpoint = 'key-${key.state.name}';
    final expected = stage == 'create' ? KeyState.fresh : KeyState.present;
    if (key.state != expected) throw StateError('key state');
    checkpoint = 'open';
    profile = await openProfile(dir: directory.path, key: key.value!);
    final marker = File('${directory.path}/expected-identity');
    if (stage == 'create') {
      checkpoint = 'create-identity';
      await profile.createIdentity();
      final identity = (await profile.setup()).identityId;
      if (identity == null) throw StateError('identity');
      await marker.writeAsString(identity, flush: true);
    } else {
      checkpoint = 'compare-identity';
      final identity = (await profile.setup()).identityId;
      if (identity == null || identity != await marker.readAsString()) {
        throw StateError('identity changed');
      }
    }
    checkpoint = 'close';
    await profile.close();
    profile = null;
    result = 'ARVEIL_TEST_UPGRADE_OK:$stage';
  } catch (error) {
    // A failure signal must not include keys, platform paths or diagnostics.
    result = 'ARVEIL_TEST_UPGRADE_FAILED:$checkpoint:${error.runtimeType}';
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
