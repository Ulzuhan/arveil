import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arveil/l10n/l10n.dart';
import 'package:arveil/src/updates/controller.dart';
import 'package:arveil/src/updates/manifest.dart';
import 'package:arveil/src/updates/page.dart';
import 'package:arveil/src/updates/transport.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final clock = DateTime.utc(2030, 1, 1);

/// The Dart check the tests sign and verify with; the app uses the Rust core's.
Future<bool> ed25519(
  List<int> payload,
  List<int> signature,
  List<int> publicKey,
) => Ed25519().verify(
  [...utf8.encode(updateDomain), ...payload],
  signature: Signature(
    signature,
    publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
  ),
);
final apk = utf8.encode('a test package');

class MemoryStore implements UpdateStore {
  String? value;
  bool fail = false;
  int writes = 0;
  int? failAt;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String data) async {
    writes++;
    if (fail || writes == failAt) throw const FileSystemException();
    value = data;
  }
}

class FakeTransport implements UpdateTransport {
  List<int> wire = [];
  int requests = 0;
  int discards = 0;
  bool fail = false;
  Completer<void>? hold;
  Future<File> Function(void Function(int) progress)? fetch;
  @override
  Future<List<int>> manifest(Uri url) async {
    requests++;
    await hold?.future;
    if (fail) throw const UpdateFailure('network');
    return wire;
  }

  @override
  Future<File> download(
    AndroidUpdate update,
    void Function(int) progress,
  ) async => fetch == null ? throw UnimplementedError() : fetch!(progress);
  @override
  void cancel() {}
  @override
  Future<void> discard() async => discards++;
}

class FakeInstaller implements UpdateInstaller {
  int build = 17;
  int installs = 0;
  bool permissionAllowed = true;
  String? failure;
  final opened = <Uri>[];
  @override
  Future<UpdateDevice> device() async => UpdateDevice(
    build: build,
    sdk: 36,
    applicationId: 'io.github.ulzuhan.arveil',
    arm64: true,
  );
  @override
  Future<bool> allowed() async => permissionAllowed;
  @override
  Future<void> requestPermission() async {}
  @override
  Future<void> install(File apk, AndroidUpdate update) async {
    installs++;
    if (failure case final code?) throw PlatformException(code: code);
  }

  @override
  Future<void> open(Uri url) async => opened.add(url);
}

void main() {
  late SimpleKeyPair key;
  late UpdateConfig config;
  late MemoryStore store;
  late FakeTransport transport;
  late FakeInstaller installer;
  late UpdateController controller;
  late DateTime time;

  Map<String, Object> payload({
    int sequence = 1,
    int build = 18,
    String? expires,
    String notes = 'A new version.',
    String channel = 'beta',
  }) => {
    'schema': 1,
    'channel': channel,
    'sequence': sequence,
    'expires': expires ?? '2030-02-01T00:00:00Z',
    'platforms': {
      'android-arm64': {
        'version': '0.1.0',
        'build': build,
        'minimum_sdk': 24,
        'application_id': 'io.github.ulzuhan.arveil',
        'url':
            'https://github.com/example/arveil/releases/download/clients-v0.1.0/app.apk',
        'size': 14,
        'sha256':
            '41bf7e7830bb983ab8facedd2983ffec17fe9a9775b4b5d2c4ac3ba9a1d2cffe',
        'notes': notes,
        'notes_url': 'https://example.org/releases/18',
      },
    },
  };

  Future<List<int>> sign(Map<String, Object> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    final signature = await Ed25519().sign([
      ...utf8.encode(updateDomain),
      ...bytes,
    ], keyPair: key);
    return utf8.encode(
      jsonEncode({
        'schema': 1,
        'payload': base64Encode(bytes),
        'signature': base64Encode(signature.bytes),
      }),
    );
  }

  /// The accepted sequence of the only history in the state, 0 if none.
  int storedSequence() {
    final histories = (jsonDecode(store.value!) as Map)['feeds'] as Map;
    return histories.isEmpty
        ? 0
        : (histories.values.single as Map)['sequence'] as int;
  }

  UpdateController makeController([UpdateConfig? other]) => UpdateController(
    verifier: ed25519,
    config: other ?? config,
    store: store,
    transport: transport,
    installer: installer,
    now: () => time,
  );

  setUp(() async {
    key = await Ed25519().newKeyPairFromSeed(List.generate(32, (i) => i));
    config = UpdateConfig(
      feed: Uri.parse('https://updates.example.org/clients.json'),
      publicKey: (await key.extractPublicKey()).bytes,
      channel: 'beta',
    );
    store = MemoryStore();
    transport = FakeTransport();
    installer = FakeInstaller();
    time = clock;
    transport.wire = await sign(payload());
    controller = makeController();
  });
  tearDown(() => controller.dispose());

  test(
    'verifies an independently signed OpenSSL 3 interoperability fixture',
    () async {
      final fixture =
          jsonDecode(
                await File(
                  'test/fixtures/update-v1-openssl.json',
                ).readAsString(),
              )
              as Map;
      final pinned = UpdateConfig(
        feed: config.feed,
        publicKey: base64Decode(fixture['public_key'] as String),
        channel: 'beta',
      );
      final verified = await UpdateManifest.verify(
        utf8.encode(jsonEncode(fixture['envelope'])),
        pinned,
        verifier: ed25519,
      );
      expect(verified.sequence, 7);
      expect(verified.android.build, 18);
      expect(verified.android.notes, 'OpenSSL interoperability fixture.');
    },
  );

  test(
    'off by default and on every foreground event makes zero requests',
    () async {
      await controller.load();
      for (var i = 0; i < 5; i++) {
        time = time.add(const Duration(days: 2));
        await controller.checkAutomatically();
      }
      expect(transport.requests, 0);
      expect(controller.automatic, false);
      time = clock;
      await controller.check();
      expect(transport.requests, 1);
      expect(controller.phase, UpdatePhase.available);
      expect(controller.error, null);
    },
  );

  test(
    'automatic checks are at most daily, including failures and process restarts',
    () async {
      await controller.load();
      await controller.setAutomatic(true);
      transport.fail = true;
      await controller.checkAutomatically();
      expect(controller.error, 'network');
      final reopened = makeController();
      addTearDown(reopened.dispose);
      await reopened.load();
      time = time.add(const Duration(hours: 23));
      await reopened.checkAutomatically();
      expect(transport.requests, 1);
      time = time.add(const Duration(hours: 1));
      await reopened.checkAutomatically();
      expect(transport.requests, 2);
      await reopened.setAutomatic(false);
      time = time.add(const Duration(days: 2));
      await reopened.checkAutomatically();
      expect(transport.requests, 2);
    },
  );

  test(
    'an invalid signature is never offered or persisted as trusted',
    () async {
      final envelope = jsonDecode(utf8.decode(transport.wire)) as Map;
      envelope['signature'] = base64Encode(List.filled(64, 0));
      transport.wire = utf8.encode(jsonEncode(envelope));
      await controller.check();
      expect(controller.error, 'signature');
      expect(controller.available, false);
      expect(storedSequence(), 0);
      expect(installer.installs, 0);
    },
  );

  test(
    'a different signing key and altered signed bytes are rejected',
    () async {
      final wrong = UpdateConfig(
        feed: config.feed,
        publicKey: List.filled(32, 1),
        channel: 'beta',
      );
      await expectLater(
        UpdateManifest.verify(transport.wire, wrong, verifier: ed25519),
        throwsA(isA<UpdateFailure>()),
      );
      final envelope = jsonDecode(utf8.decode(transport.wire)) as Map;
      envelope['payload'] = base64Encode(
        utf8.encode(jsonEncode(payload(build: 200))),
      );
      await expectLater(
        UpdateManifest.verify(
          utf8.encode(jsonEncode(envelope)),
          config,
          verifier: ed25519,
        ),
        throwsA(isA<UpdateFailure>()),
      );
    },
  );

  test('expired announcements never advance sequence', () async {
    transport.wire = await sign(
      payload(expires: '2030-01-01T00:00:00Z', sequence: 100),
    );
    await controller.check();
    expect(controller.error, 'expired');
    expect(controller.available, false);
    expect(storedSequence(), 0);
  });

  test(
    'rollback protection survives reopening; repeated identical feed is allowed',
    () async {
      transport.wire = await sign(payload(sequence: 5));
      await controller.check();
      final reopened = makeController();
      addTearDown(reopened.dispose);
      await reopened.load();
      await reopened.check();
      expect(reopened.error, null);
      expect(reopened.available, true);
      // An older or conflicting reply is refused and never replaces the offer
      // already verified, which stays valid.
      transport.wire = await sign(payload(sequence: 4));
      await reopened.check();
      expect(reopened.error, 'rollback');
      expect(reopened.manifest!.sequence, 5);
      transport.wire = await sign(payload(sequence: 5, notes: 'different'));
      await reopened.check();
      expect(reopened.error, 'rollback');
      expect(reopened.manifest!.android.notes, 'A new version.');
      transport.wire = await sign(payload(sequence: 6));
      await reopened.check();
      expect(reopened.error, null);
      expect(reopened.available, true);
    },
  );

  test(
    'older and equal builds are not offered, even with a newer manifest',
    () async {
      for (final build in [16, 17]) {
        transport.wire = await sign(payload(sequence: build, build: build));
        await controller.check();
        expect(controller.phase, UpdatePhase.current);
        expect(controller.available, false);
      }
    },
  );

  test(
    'channel mismatch, HTTP download and non-UTC expiry are rejected',
    () async {
      for (final (data, code) in [
        (payload()..['channel'] = 'stable', 'channel'),
        (payload(expires: '2030-02-01T00:00:00'), 'format'),
        (payload()..['platforms'] = {'android-arm64': {}}, 'format'),
      ]) {
        await expectLater(
          UpdateManifest.verify(await sign(data), config, verifier: ed25519),
          throwsA(isA<UpdateFailure>().having((e) => e.code, 'code', code)),
        );
      }
      for (final url in [
        'http://example.org/app.apk',
        'https://user:pass@example.org/a',
        'https://example.org/a#token',
      ]) {
        expect(() => updateUri(url), throwsA(isA<UpdateFailure>()));
      }
    },
  );

  test(
    'another update key or channel keeps its own history instead of blocking updates',
    () async {
      transport.wire = await sign(payload(sequence: 5));
      await controller.check();
      expect(controller.error, null);

      // The same installation, now a stable build: its history starts at zero,
      // and turning automatic checks off still works.
      final stable = UpdateConfig(
        feed: config.feed,
        publicKey: config.publicKey,
        channel: 'stable',
      );
      final switched = makeController(stable);
      addTearDown(switched.dispose);
      await switched.load();
      expect(switched.error, null);
      await switched.setAutomatic(false);
      expect(switched.error, null);
      transport.wire = await sign(payload(sequence: 1, channel: 'stable'));
      await switched.check();
      expect(switched.error, null);
      expect(switched.available, true);

      // A rotated key, as after losing the update key and installing a build
      // with the new one by hand, also starts at zero.
      final rotated = UpdateConfig(
        feed: config.feed,
        publicKey: List.filled(32, 7),
        channel: 'beta',
      );
      final fresh = makeController(rotated);
      addTearDown(fresh.dispose);
      await fresh.load();
      expect(fresh.error, null);

      // Going back to the first key and channel keeps its rollback protection.
      final back = makeController();
      addTearDown(back.dispose);
      await back.load();
      transport.wire = await sign(payload(sequence: 4));
      await back.check();
      expect(back.error, 'rollback');
    },
  );

  test(
    'state written before per-key histories keeps its rollback protection',
    () async {
      transport.wire = await sign(payload(sequence: 5));
      await controller.check();
      final current = (jsonDecode(store.value!) as Map)['feeds'] as Map;
      final entry = current.entries.single;
      // The format of builds up to 0.1.0+18: one history at the top level.
      store.value = jsonEncode({
        'schema': 1,
        'identity': entry.key,
        'automatic': true,
        'lastAttempt': '2030-01-01T00:00:00.000Z',
        'sequence': (entry.value as Map)['sequence'],
        'digest': (entry.value as Map)['digest'],
      });
      final reopened = makeController();
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.error, null);
      expect(reopened.automatic, true);
      transport.wire = await sign(payload(sequence: 4));
      await reopened.check();
      expect(reopened.error, 'rollback');
      transport.wire = await sign(payload(sequence: 6));
      await reopened.check();
      expect(reopened.error, null);
      expect((jsonDecode(store.value!) as Map)['schema'], 2);
    },
  );

  test('a history with a malformed entry still fails closed', () async {
    for (final damaged in [
      {
        'schema': 2,
        'automatic': true,
        'feeds': {
          'not-hex': {'sequence': 1},
        },
      },
      {
        'schema': 2,
        'automatic': true,
        'feeds': {
          'a' * 64: {'sequence': 3, 'digest': null},
        },
      },
      {'schema': 2, 'automatic': 'yes', 'feeds': {}},
      {'schema': 3, 'automatic': true, 'feeds': {}},
    ]) {
      store.value = jsonEncode(damaged);
      final reopened = makeController();
      addTearDown(reopened.dispose);
      await reopened.load();
      await reopened.check();
      expect(reopened.error, 'state', reason: '$damaged');
    }
    expect(transport.requests, 0);
  });

  test('damaged state fails closed without contacting any service', () async {
    store.value = '{broken';
    await controller.load();
    await controller.check();
    await controller.setAutomatic(true);
    expect(controller.error, 'state');
    expect(transport.requests, 0);
    expect(store.value, '{broken');
  });

  test(
    'failed attempt persistence prevents networking, failed acceptance prevents offering',
    () async {
      store.fail = true;
      await controller.check();
      expect(transport.requests, 0);
      expect(controller.error, 'state');
      expect(controller.available, false);

      // The attempt is saved, then saving the accepted sequence fails.
      store.fail = false;
      store.failAt = store.writes + 2;
      final reopened = makeController();
      addTearDown(reopened.dispose);
      await reopened.check();
      expect(transport.requests, 1);
      expect(reopened.error, 'state');
      expect(reopened.available, false);
      expect(reopened.manifest, null);
    },
  );

  test(
    'state stores only update policy and rollback metadata, outside the profile',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'arveil-update-state-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final fileStore = FileUpdateStore(directory);
      expect(await fileStore.read(), null);
      await controller.check();
      await fileStore.write(store.value!);
      expect(await fileStore.read(), store.value);
      expect(File('${directory.path}/updates.json.tmp').existsSync(), false);
      final state = jsonDecode(store.value!) as Map;
      expect(state.keys.toSet(), {
        'schema',
        'automatic',
        'lastAttempt',
        'feeds',
      });
      final history = (state['feeds'] as Map).values.single as Map;
      expect(history.keys.toSet(), {'sequence', 'digest'});
    },
  );

  test('file I/O errors cannot be mistaken for a first installation', () async {
    final directory = await Directory.systemTemp.createTemp('arveil-state-io-');
    addTearDown(() => directory.delete(recursive: true));
    final notDirectory = File('${directory.path}/not-a-directory');
    await notDirectory.writeAsString('fixture');
    final fileStore = FileUpdateStore(Directory(notDirectory.path));
    await expectLater(fileStore.read(), throwsA(isA<FileSystemException>()));
  });

  test(
    'failure to persist an accepted sequence prevents offering the signed update',
    () async {
      store.failAt = 2;
      await controller.check();
      expect(transport.requests, 1);
      expect(controller.error, 'state');
      expect(controller.available, false);
      expect(storedSequence(), 0);
    },
  );

  test(
    'download never installs automatically; permission and current build are checked again',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'arveil-install-policy-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/update.apk').writeAsBytes(apk);
      transport.fetch = (_) async => file;
      await controller.check();
      await controller.download();
      expect(controller.phase, UpdatePhase.ready);
      expect(installer.installs, 0);
      installer.permissionAllowed = false;
      await controller.install();
      expect(controller.error, 'permission');
      expect(installer.installs, 0);
      installer.permissionAllowed = true;
      // The installed build caught up meanwhile: nothing is wrong with the
      // package, there is simply nothing left to install.
      installer.build = 18;
      await controller.install();
      expect(controller.error, null);
      expect(controller.phase, UpdatePhase.current);
      expect(installer.installs, 0);
      expect(await file.exists(), false);
    },
  );

  test('installing hands the package over once, then removes it', () async {
    final directory = await Directory.systemTemp.createTemp('arveil-install-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/update.apk').writeAsBytes(apk);
    transport.fetch = (_) async => file;
    await controller.check();
    await controller.download();
    await controller.install();
    expect(controller.error, null);
    expect(installer.installs, 1);
    expect(controller.phase, UpdatePhase.current);
    expect(await file.exists(), false);
  });

  test(
    'a storage failure keeps the package; a refused package is deleted',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'arveil-install-failure-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/update.apk').writeAsBytes(apk);
      transport.fetch = (_) async => file;
      await controller.check();
      await controller.download();
      for (final code in ['storage', 'cancelled']) {
        installer.failure = code;
        await controller.install();
        expect(controller.error, code);
        expect(controller.phase, UpdatePhase.ready, reason: code);
        expect(await file.exists(), true, reason: code);
      }
      installer.failure = 'package';
      await controller.install();
      expect(controller.error, 'package');
      expect(controller.phase, UpdatePhase.available);
      expect(await file.exists(), false);
    },
  );

  test(
    'expiry during download deletes the package and never offers installation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'arveil-expired-download-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/update.apk').writeAsBytes(apk);
      transport.fetch = (_) async {
        time = DateTime.utc(2030, 3, 1);
        return file;
      };
      await controller.check();
      await controller.download();
      expect(controller.error, 'expired');
      expect(controller.phase, UpdatePhase.idle);
      expect(controller.manifest, null);
      expect(await file.exists(), false);
      expect(installer.installs, 0);
    },
  );

  test('an offer that expired leaves instead of failing every tap', () async {
    await controller.check();
    expect(controller.available, true);
    time = DateTime.utc(2030, 3, 1);
    await controller.download();
    expect(controller.error, 'expired');
    expect(controller.available, false);
    expect(controller.manifest, null);
    await controller.download();
    expect(controller.error, null);
  });

  test(
    'a failed check keeps a valid offer and its package, but not an expired one',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'arveil-kept-offer-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/update.apk').writeAsBytes(apk);
      transport.fetch = (_) async => file;
      await controller.check();
      await controller.setAutomatic(true);
      transport.fail = true;
      time = time.add(const Duration(days: 2));
      await controller.checkAutomatically();
      expect(controller.error, 'network');
      expect(controller.phase, UpdatePhase.available);

      await controller.download();
      await controller.check();
      expect(controller.error, 'network');
      expect(controller.phase, UpdatePhase.ready);
      expect(await file.exists(), true);

      time = DateTime.utc(2030, 3, 1);
      await controller.check();
      expect(controller.phase, UpdatePhase.idle);
      expect(controller.manifest, null);
      expect(await file.exists(), false);
    },
  );

  test('an attempt dated in the future does not stop checks', () async {
    await controller.load();
    await controller.setAutomatic(true);
    // Checked while the clock said 2035, then the clock was corrected.
    time = DateTime.utc(2035, 1, 1);
    await controller.check();
    time = clock;
    await controller.checkAutomatically();
    expect(transport.requests, 2);
    await controller.checkAutomatically();
    expect(transport.requests, 2);
  });

  test('a package left by an earlier run is removed at start', () async {
    await controller.load();
    expect(transport.discards, 1);
    final unconfigured = UpdateController(
      verifier: ed25519,
      config: null,
      store: store,
      transport: transport,
      installer: installer,
    );
    addTearDown(unconfigured.dispose);
    await unconfigured.load();
    expect(transport.discards, 2);
    expect(transport.requests, 0);
  });

  test('two checks at once make a single request', () async {
    transport.hold = Completer<void>();
    final first = controller.check();
    final second = controller.check();
    transport.hold!.complete();
    await Future.wait([first, second]);
    expect(transport.requests, 1);
    expect(controller.available, true);
  });

  test('download progress notifies once per percentage point', () async {
    final directory = await Directory.systemTemp.createTemp('arveil-progress-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/update.apk').writeAsBytes(apk);
    await controller.check();
    var notifications = 0;
    controller.addListener(() => notifications++);
    transport.fetch = (progress) async {
      // 14 bytes, each reported many times over, as small pieces would be.
      for (var count = 1; count <= 14; count++) {
        for (var repeat = 0; repeat < 50; repeat++) {
          progress(count);
        }
      }
      return file;
    };
    await controller.download();
    expect(controller.phase, UpdatePhase.ready);
    expect(controller.received, 14);
    expect(notifications, lessThan(20));
  });

  test('the permission hint goes once Android allows installing', () async {
    final directory = await Directory.systemTemp.createTemp(
      'arveil-permission-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/update.apk').writeAsBytes(apk);
    transport.fetch = (_) async => file;
    installer.permissionAllowed = false;
    await controller.check();
    await controller.download();
    expect(controller.needsPermission, true);
    await controller.refreshPermission();
    expect(controller.needsPermission, true);
    installer.permissionAllowed = true;
    await controller.refreshPermission();
    expect(controller.needsPermission, false);
    expect(installer.installs, 0);
  });

  test('the signed release notes link opens on request', () async {
    await controller.openNotes();
    expect(installer.opened, isEmpty);
    await controller.check();
    await controller.openNotes();
    expect(installer.opened, [Uri.parse('https://example.org/releases/18')]);
  });

  test(
    'a cancelled download that finishes concurrently is discarded',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'arveil-cancel-download-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/update.apk').writeAsBytes(apk);
      transport.fetch = (_) async {
        controller.cancelDownload();
        return file;
      };
      await controller.check();
      await controller.download();
      expect(controller.error, null);
      expect(controller.phase, UpdatePhase.available);
      expect(await file.exists(), false);
      expect(installer.installs, 0);
    },
  );

  testWidgets('opening the screen does not check until the user asks', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: UpdatesPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(transport.requests, 0);
    expect(find.text('Buscar actualizaciones'), findsOneWidget);
    await tester.tap(find.byKey(const Key('updates-check')));
    await tester.pumpAndSettle();
    expect(transport.requests, 1);
    expect(controller.available, true);
    expect(installer.installs, 0);
  });

  /// The app's arrangement: the banner above the navigator it watches.
  Widget app({required void Function(double) inset}) {
    final navigator = GlobalKey<NavigatorState>();
    final routes = UpdateRoutes();
    return MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [routes],
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => UpdateScope(
        controller: controller,
        child: UpdateLifecycle(
          controller: controller,
          navigator: navigator,
          routes: routes,
          child: child!,
        ),
      ),
      home: Builder(
        builder: (context) {
          inset(MediaQuery.paddingOf(context).top);
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(content: Text('Dialog')),
                ),
                child: const Text('Open dialog'),
              ),
            ),
          );
        },
      ),
    );
  }

  testWidgets('foreground checks run after the first frame and on resume', (
    tester,
  ) async {
    await controller.load();
    await controller.setAutomatic(true);
    await tester.pumpWidget(app(inset: (_) {}));
    await tester.pumpAndSettle();
    expect(transport.requests, 1);
    for (final (advance, requests) in [
      (const Duration(hours: 1), 1),
      (const Duration(days: 1), 2),
    ]) {
      time = time.add(advance);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(transport.requests, requests);
    }
  });

  testWidgets(
    'the banner takes the status bar inset, is covered by dialogs and hides on the updates page',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.reset);
      var inset = -1.0;
      await tester.pumpWidget(app(inset: (value) => inset = value));
      await tester.pumpAndSettle();
      expect(inset, 24);
      expect(find.text('View'), findsNothing);

      await controller.check();
      await tester.pumpAndSettle();
      expect(find.text('An Arveil update is available'), findsOneWidget);
      expect(inset, 0);

      // Under a dialog, a tap on the banner reaches the dialog's barrier,
      // which closes it, and never the banner's button.
      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();
      expect(find.text('Dialog'), findsOneWidget);
      await tester.tap(find.text('View'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Dialog'), findsNothing);
      expect(find.byType(UpdatesPage), findsNothing);

      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(find.byType(UpdatesPage), findsOneWidget);
      expect(find.text('An Arveil update is available'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('An Arveil update is available'), findsOneWidget);
    },
  );

  testWidgets('the page shows the size in MiB and links the release notes', (
    tester,
  ) async {
    await controller.check();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: UpdatesPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Download: 0.0 MiB'), findsOneWidget);
    await tester.tap(find.text('Release notes on example.org'));
    await tester.pumpAndSettle();
    expect(installer.opened, [Uri.parse('https://example.org/releases/18')]);
  });

  group('rules shared with the release signer', () {
    final vectors =
        jsonDecode(
              File(
                'test/fixtures/update-manifest-vectors.json',
              ).readAsStringSync(),
            )
            as Map;

    test('domain and notes limit match', () {
      expect(updateDomain, vectors['domain']);
      expect(maxNotes, vectors['max_notes']);
    });

    test(
      'notes are counted in code points, as the signer counts them',
      () async {
        for (final vector in (vectors['notes'] as List).cast<Map>()) {
          final notes =
              'a' * (vector['ascii'] as int) +
              '\u{1F600}' * (vector['emoji'] as int);
          final result = UpdateManifest.verify(
            await sign(payload(notes: notes)),
            config,
            verifier: ed25519,
          );
          if (vector['valid'] as bool) {
            await expectLater(result, completes, reason: '$vector');
          } else {
            await expectLater(
              result,
              throwsA(isA<UpdateFailure>()),
              reason: '$vector',
            );
          }
        }
      },
    );

    test('feed and link URLs are judged as the signer judges them', () {
      for (final vector in (vectors['urls'] as List).cast<Map>()) {
        final url = vector['url'] as String;
        void link() => updateUri(url);
        void feed() => UpdateConfig(
          feed: updateUri(url),
          publicKey: List.filled(32, 1),
          channel: 'beta',
        );
        for (final (valid, check) in [
          (vector['link'] as bool, link),
          (vector['feed'] as bool, feed),
        ]) {
          if (valid) {
            expect(check, returnsNormally, reason: url);
          } else {
            expect(check, throwsA(isA<UpdateFailure>()), reason: url);
          }
        }
      }
    });
  });
}
