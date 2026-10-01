// Run through scripts/test_client_conversations.py --scenario invitations.
// All profiles, roles, server keys and URLs belong to a disposable fixture.
import 'dart:convert';
import 'dart:io';

import 'package:arveil/l10n/l10n.dart';
import 'package:arveil/src/design/qr_code.dart';
import 'package:arveil/src/invitations_page.dart';
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
  const invite = String.fromEnvironment('ARVEIL_TEST_INVITE_A');
  const control = String.fromEnvironment('ARVEIL_TEST_CONTROL');
  const token = String.fromEnvironment('ARVEIL_TEST_CONTROL_TOKEN');
  setUpAll(() async => ArveilRust.init());
  testWidgets(
    'native invitation consent, offline reopen and first chat',
    (tester) async {
      expect(
        bootstrap.isNotEmpty && invite.isNotEmpty && token.isNotEmpty,
        isTrue,
      );
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      final root = await Directory.systemTemp.createTemp(
        'arveil-invitations-ui-',
      );
      final keys = [
        for (var n = 0; n < 2; n++)
          ProfileKeys(
            keyName: 'test-invite-$n-${DateTime.now().microsecondsSinceEpoch}',
          ),
      ];
      final profiles = <Profile>[];
      Future<Profile> open(int n) async {
        final directory = await Directory('${root.path}/$n').create();
        await ProfileLocation.excludeFromBackup(directory);
        final key = await keys[n].forProfile(
          profileExists: await hasProfile(dir: directory.path),
        );
        expect(key.state, anyOf(KeyState.fresh, KeyState.present));
        final profile = await openProfile(dir: directory.path, key: key.value!);
        profiles.add(profile);
        return profile;
      }

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        for (final profile in profiles) {
          await profile.close();
        }
        for (final key in keys) {
          await key.forget();
        }
        await root.delete(recursive: true);
      });
      Future<void> command(String path, [String? identity]) async {
        final client = HttpClient();
        try {
          final request = await client.postUrl(Uri.parse('$control/$path'));
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          if (identity != null) {
            request.contentLength = utf8.encode(identity).length;
            request.write(identity);
          }
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
            reason: 'Invitation UI did not reach the expected state',
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await settle();
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await settle();
      }

      var alice = await open(0);
      var bob = await open(1);
      await alice.enroll(bootstrap: bootstrap, invite: invite);
      await alice.setCardName(name: 'Ana');
      await command('owner', (await alice.setup()).identityId!);
      await tester.pumpWidget(
        MaterialApp(home: InvitationsPage(profile: alice)),
      );
      await until(
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(await alice.invitationPolicy(), isTrue);
      await tap(find.byKey(const Key('invite-create')));
      await until(() => find.byType(InvitationCodePage).evaluate().isNotEmpty);
      await until(
        () => find
            .byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is QrPainter,
            )
            .evaluate()
            .isNotEmpty,
      );
      final issued = (await alice.invitations(refresh: false)).single;
      final link = issued.link!;
      expect(issued.state, 'pending');
      expect(find.byType(QrCodeView), findsOneWidget);
      expect(await bob.readCard(text: link), isA<CardView_Invitation>());
      await tester.pumpWidget(const SizedBox());
      await alice.close(); // The inviter is offline for the rest of admission.
      await command('offline');
      String? group;
      Future<void> acceptance({String? text}) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  key: const Key('test-open-invitation'),
                  onPressed: () async {
                    group = await openPersonalInvitation(
                      context,
                      profile: bob,
                      text: text,
                    );
                  },
                  child: const Text('Open test invitation'),
                ),
              ),
            ),
          ),
        );
        await tap(find.byKey(const Key('test-open-invitation')));
        await until(
          () => find.byKey(const Key('invite-accept')).evaluate().isNotEmpty,
        );
      }

      await acceptance(text: link);
      // Preview succeeds even offline, and has not created an identity or intent.
      expect((await bob.setup()).identityId, isNull);
      expect(await bob.pendingInvitation(), isNull);
      expect(find.text(currentStrings.inviteFrom('Ana')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('invite-name')), 'Berta');
      await tap(find.byKey(const Key('invite-accept')));
      await until(
        () => find.text(currentStrings.inviteOffline).evaluate().isNotEmpty,
      );
      expect(await bob.pendingInvitation(), isNotNull);
      final identity = (await bob.setup()).identityId;
      expect(identity, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await bob.close();
      bob = await open(1);
      expect((await bob.setup()).identityId, identity);
      await command('online');
      await acceptance(); // Durable operation; no second paste/scan.
      expect(find.text(currentStrings.inviteResume), findsOneWidget);
      await tap(find.byKey(const Key('invite-accept')));
      await until(() => group != null);
      expect(await bob.pendingInvitation(), isNull);
      expect((await bob.setup()).identityId, identity);
      expect((await bob.conversations()).single.groupId, group);
      expect((await bob.contacts()).single.accepted, isTrue);
      expect((await bob.contacts()).single.verified, isFalse);
      expect((await bob.acceptInvitation(text: link)).groupId, group);
      expect((await bob.conversations()).length, 1);
      expect(await bob.invitationPolicy(), isFalse);
      alice = await open(0);
      await alice.sync_(bootstrap: bootstrap);
      expect((await alice.conversations()).single.groupId, group);
      expect((await alice.conversations()).single.request, isNull);
      expect((await alice.contacts()).single.accepted, isTrue);
      expect((await alice.contacts()).single.verified, isFalse);
      expect(
        (await alice.invitations(refresh: true)).single.state,
        'connected',
      );
      await bob.queueMessage(groupId: group!, text: 'Hola desde la invitación');
      await bob.sync_(bootstrap: bootstrap);
      await alice.sync_(bootstrap: bootstrap);
      expect(
        utf8.decode(
          (await alice.historyPage(
            groupId: group!,
            limit: 50,
          )).events.single.body,
        ),
        'Hola desde la invitación',
      );
      await alice.queueMessage(groupId: group!, text: 'Bienvenida');
      await alice.sync_(bootstrap: bootstrap);
      await bob.sync_(bootstrap: bootstrap);
      final history = await bob.historyPage(groupId: group!, limit: 50);
      expect(history.events.map((e) => utf8.decode(e.body)), [
        'Hola desde la invitación',
        'Bienvenida',
      ]);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
