// Disposable identities/relay only. No identity kits or history are exported.
import 'dart:io';
import 'dart:convert';

import 'package:arveil/src/devices_page.dart';
import 'package:arveil/src/profile_keys.dart';
import 'package:arveil/src/profile_location.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:arveil/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const bootstrap = String.fromEnvironment('ARVEIL_TEST_BOOTSTRAP');
  const inviteA = String.fromEnvironment('ARVEIL_TEST_INVITE_A');
  const inviteB = String.fromEnvironment('ARVEIL_TEST_INVITE_B');
  const control = String.fromEnvironment('ARVEIL_TEST_CONTROL');
  const token = String.fromEnvironment('ARVEIL_TEST_CONTROL_TOKEN');
  setUpAll(() async => ArveilRust.init());
  testWidgets('device revocation survives offline reopen and removes access', (
    tester,
  ) async {
    expect(
      bootstrap.isNotEmpty && inviteA.isNotEmpty && inviteB.isNotEmpty,
      isTrue,
    );
    final root = await Directory.systemTemp.createTemp('arveil-devices-');
    final keys = [
      for (var n = 0; n < 3; n++)
        ProfileKeys(
          keyName: 'test-device-$n-${DateTime.now().microsecondsSinceEpoch}',
        ),
    ];
    final profiles = <Profile>[];
    Future<Profile> open(int n) async {
      final directory = await Directory('${root.path}/$n').create();
      await ProfileLocation.excludeFromBackup(directory);
      final key = await keys[n].forProfile(
        profileExists: await hasProfile(dir: directory.path),
      );
      return openProfile(dir: directory.path, key: key.value!);
    }

    addTearDown(() async {
      for (final p in profiles) {
        await p.close();
      }
      for (final k in keys) {
        await k.forget();
      }
      await root.delete(recursive: true);
    });
    for (var n = 0; n < 3; n++) {
      profiles.add(await open(n));
    }
    var admin = profiles[0];
    final linked = profiles[1];
    final bob = profiles[2];
    Future<void> relayState(String state) async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(Uri.parse('$control/$state'));
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        final response = await request.close();
        expect(response.statusCode, 200);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    }

    Future<void> settle() => tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 90),
    );
    Future<void> until(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (!ready()) {
        expect(
          DateTime.now().isBefore(deadline),
          isTrue,
          reason: 'Device UI did not reach the expected state',
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await settle();
    }

    Future<void> tap(Finder finder) async {
      await until(() => finder.evaluate().isNotEmpty);
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await settle();
    }

    Future<void> page(Profile p) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: DevicesPage(profile: p, bootstrap: bootstrap),
        ),
      );
      await until(() => find.text('Este dispositivo').evaluate().isNotEmpty);
    }

    await admin.enroll(bootstrap: bootstrap, invite: inviteA);
    await bob.enroll(bootstrap: bootstrap, invite: inviteB);
    await linked.beginPairing(bootstrap: bootstrap);
    final pair = (await linked.setup()).pairing!;
    final waiting = linked.awaitPairing(bootstrap: bootstrap, session: pair);
    final comparison = await admin.approvePairing(
      bootstrap: bootstrap,
      code: pair.code,
    );
    await waiting;
    await linked.confirmPairing(
      bootstrap: bootstrap,
      sessionId: pair.sessionId,
      verificationCode: comparison,
    );
    final target = (await linked.devices()).devices.single.deviceId;
    await page(linked);
    expect(find.byKey(const Key('partial-device-inventory')), findsOneWidget);
    expect(find.text('Revocar dispositivo'), findsNothing);
    final routes = [await linked.ownRoute(), await bob.ownRoute()];
    final numbers = (await admin.previewRoutes(
      routes: routes,
    )).map((r) => r.safetyNumber).toList();
    final created = await admin.createConversation(
      bootstrap: bootstrap,
      routes: routes,
      safetyNumbers: numbers,
    );
    expect(created.warning, isNull);
    await linked.sync_(bootstrap: bootstrap);
    await bob.sync_(bootstrap: bootstrap);
    await page(admin);
    await tap(find.byKey(Key('revoke-$target')));
    await tap(find.text('Cancelar'));
    expect((await admin.devices()).devices.every((d) => !d.revoked), isTrue);
    await relayState('offline');
    await tap(find.byKey(Key('revoke-$target')));
    await tap(find.byKey(const Key('confirm-device-revocation')));
    await until(
      () => find
          .text('Pendiente de publicar la revocación en el relay')
          .evaluate()
          .isNotEmpty,
    );
    final pending = (await admin.devices()).devices.firstWhere(
      (d) => d.deviceId == target,
    );
    expect(pending.revoked, isTrue);
    expect(pending.revocation!.relayPublished, isFalse);
    expect(pending.revocation!.groupsWaiting, 0);
    expect(pending.revocation!.notificationsPending, 2);
    final sequence = (await admin.devices()).manifestSequence;
    await tester.pumpWidget(const SizedBox());
    await admin.close();
    admin = await open(0);
    profiles[0] = admin;
    expect((await admin.devices()).manifestSequence, sequence);
    await relayState('online');
    await page(admin);
    await tap(find.byKey(const Key('sync-devices')));
    await until(
      () => find.text('Revocación aceptada por el relay').evaluate().isNotEmpty,
    );
    final done = (await admin.devices()).devices
        .firstWhere((d) => d.deviceId == target)
        .revocation!;
    expect(done.notificationsPending, 0);
    expect(done.groupsWaiting, 0);
    await expectLater(
      linked.sync_(bootstrap: bootstrap),
      throwsA(isA<CommandError>()),
    );
    await bob.sync_(bootstrap: bootstrap);
    await admin.queueMessage(
      groupId: created.groupId,
      text: 'after revocation',
    );
    await admin.sync_(bootstrap: bootstrap);
    await bob.sync_(bootstrap: bootstrap);
    final events = (await bob.historyPage(
      groupId: created.groupId,
      limit: 50,
    )).events;
    expect(
      events
          .where(
            (e) =>
                utf8.decode(e.body, allowMalformed: true) == 'after revocation',
          )
          .length,
      1,
    );
    await admin.sync_(bootstrap: bootstrap);
    await bob.sync_(bootstrap: bootstrap);
    expect((await admin.devices()).manifestSequence, sequence);
    expect(
      (await bob.historyPage(groupId: created.groupId, limit: 50)).events
          .where(
            (e) =>
                utf8.decode(e.body, allowMalformed: true) == 'after revocation',
          )
          .length,
      1,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
