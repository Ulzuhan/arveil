// Private emulator entry point, never a distribution build. The packaging
// audit rejects its ARVEIL_TEST_ marker. See docs/CLIENT_UPDATES.md.
//
// Runs the real app with the real update controller, transport, Rust
// signature check and Android installer. The only difference is one more
// trusted root: the disposable authority of the local test feed, which
// cannot hold a public certificate.
import 'dart:convert';
import 'dart:io';

import 'package:arveil/main.dart';
import 'package:arveil/src/profile_keys.dart';
import 'package:arveil/src/profile_location.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:arveil/src/rust/api/updates.dart';
import 'package:arveil/src/rust/frb_generated.dart';
import 'package:arveil/src/updates/controller.dart';
import 'package:arveil/src/updates/manifest.dart';
import 'package:arveil/src/updates/transport.dart';
import 'package:arveil/src/updates/trust.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

const _stage = String.fromEnvironment('ARVEIL_TEST_UPDATER');
const _authority = String.fromEnvironment('ARVEIL_TEST_UPDATE_CA');
const _probe = String.fromEnvironment('ARVEIL_TEST_TRUST_PROBE');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ArveilRust.init();
  debugPrint(await _profile());
  if (_probe.isNotEmpty) {
    for (final (name, context) in [
      ('system', SecurityContext(withTrustedRoots: true)),
      ('update', updateTrust()),
    ]) {
      debugPrint('ARVEIL_TEST_TRUST:$name:${await _reach(context)}');
    }
  }
  final cache = Directory('${(await getTemporaryDirectory()).path}/updates');
  final leftover = File('${cache.path}/update.apk').existsSync();
  final updates = UpdateController(
    config: UpdateConfig.fromEnvironment(),
    store: FileUpdateStore(await getApplicationSupportDirectory()),
    transport: HttpsUpdateTransport(
      () async => cache,
      client: () => HttpClient(
        context: updateTrust()
          ..setTrustedCertificatesBytes(base64Decode(_authority)),
      ),
    ),
    installer: AndroidUpdateInstaller(),
    verifier: (payload, signature, publicKey) => verifyUpdateSignature(
      payload: payload,
      signature: signature,
      publicKey: publicKey,
    ),
  );
  await updates.load();
  final state = File(
    '${(await getApplicationSupportDirectory()).path}/updates.json',
  );
  final sequences = state.existsSync()
      ? [
          for (final history
              in ((jsonDecode(await state.readAsString()) as Map)['feeds']
                      as Map)
                  .values)
            (history as Map)['sequence'],
        ]
      : [];
  debugPrint(
    'ARVEIL_TEST_UPDATER_STATE:$_stage:error=${updates.error}'
    ':sequences=${sequences.join(',')}'
    ':leftover=$leftover'
    ':removed=${!File('${cache.path}/update.apk').existsSync()}',
  );
  runApp(ArveilApp(updates: updates));
}

/// A real encrypted profile, created before the update and opened after it.
Future<String> _profile() async {
  Profile? profile;
  try {
    if (!['before', 'after'].contains(_stage)) throw StateError('stage');
    final location = await ProfileLocation.ensure();
    final directory = Directory('${location.parent.path}/flow-acceptance');
    await directory.create(recursive: true);
    final exists = await hasProfile(dir: directory.path);
    if (_stage == 'after' && !exists) throw StateError('profile lost');
    final key = await ProfileKeys(
      keyName: 'flow-acceptance-v1',
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
    return 'ARVEIL_TEST_UPDATER_OK:profile:$_stage';
  } catch (_) {
    // No profile keys, identity or paths in the acceptance signal.
    return 'ARVEIL_TEST_UPDATER_FAILED:profile:$_stage';
  } finally {
    await profile?.close();
  }
}

/// Whether a TLS connection to [_probe] succeeds with [context]'s roots.
Future<String> _reach(SecurityContext context) async {
  final client = HttpClient(context: context)
    ..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.headUrl(Uri.parse(_probe));
    final response = await request.close();
    await response.drain<void>();
    return 'reached';
  } on HandshakeException {
    return 'untrusted';
  } catch (_) {
    return 'unreachable';
  } finally {
    client.close(force: true);
  }
}
