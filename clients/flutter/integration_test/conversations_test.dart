// Run only through scripts/test_client_conversations.py (disposable relay).
import 'dart:convert';
import 'dart:io';

import 'package:arveil/src/conversation_controller.dart';
import 'package:arveil/src/conversations_page.dart';
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
  testWidgets(
    'saved contacts, explicit verification, rename, encrypted reopen, duplex text and offline reconnect',
    (tester) async {
      expect(
        bootstrap.isNotEmpty && inviteA.isNotEmpty && inviteB.isNotEmpty,
        isTrue,
      );
      // Text is injected through the test channel. Do not let a native IME
      // race those synthetic editing values when the desktop app lacks focus.
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      final root = await Directory.systemTemp.createTemp(
        'arveil-conversations-',
      );
      final keys = [
        for (var i = 0; i < 2; i++)
          ProfileKeys(
            keyName: 'test-chat-$i-${DateTime.now().microsecondsSinceEpoch}',
          ),
      ];
      Future<Profile> open(int n) async {
        final directory = await Directory('${root.path}/$n').create();
        await ProfileLocation.excludeFromBackup(directory);
        final key = await keys[n].forProfile(
          profileExists: await hasProfile(dir: directory.path),
        );
        expect(key.state, anyOf(KeyState.fresh, KeyState.present));
        return openProfile(dir: directory.path, key: key.value!);
      }

      var alice = await open(0);
      final bob = await open(1);
      addTearDown(() async {
        await alice.close();
        await bob.close();
        for (final key in keys) {
          await key.forget();
        }
        await root.delete(recursive: true);
      });
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
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await settle();
      }

      final cancelledGeneration = alice.startWatching();
      alice.stopWatching(generation: cancelledGeneration);
      await alice
          .watch(generation: cancelledGeneration)
          .drain<void>()
          .timeout(const Duration(seconds: 2));
      await alice.enroll(bootstrap: bootstrap, invite: inviteA);
      await bob.enroll(bootstrap: bootstrap, invite: inviteB);
      final bobRoute = await bob.ownRoute();
      final aPreview = await alice.previewRoutes(routes: [bobRoute]);
      final bPreview = await bob.previewRoutes(
        routes: [await alice.ownRoute()],
      );
      expect(aPreview.single.safetyNumber, bPreview.single.safetyNumber);
      var chat = ConversationController(alice, bootstrap);
      await tester.pumpWidget(
        MaterialApp(home: ConversationsPage(controller: chat)),
      );
      await settle();
      await tap(find.byTooltip('Contactos'));
      await tap(find.byTooltip('Añadir contacto'));
      await tester.enterText(
        find.byKey(const Key('contact-name')),
        'Contacto de prueba',
      );
      await tester.enterText(find.byKey(const Key('contact-route')), bobRoute);
      await tap(find.text('Preparar contacto'));
      expect(find.text(aPreview.single.safetyNumber), findsOneWidget);
      await tap(find.byKey(const Key('save-contact')));
      expect((await alice.contacts()).single.verified, isFalse);
      await tap(find.byKey(const Key('contact-compared')));
      await tap(find.byKey(const Key('verify-contact')));
      await tap(find.byType(BackButton));
      await tap(find.byType(BackButton));
      // Reopen before choosing the saved contact: no route is pasted again.
      await tester.pumpWidget(const SizedBox());
      await alice.close();
      alice = await open(0);
      final saved = (await alice.contacts()).single;
      expect(saved.label, 'Contacto de prueba');
      expect(saved.verified, isTrue);
      chat = ConversationController(alice, bootstrap);
      await tester.pumpWidget(
        MaterialApp(home: ConversationsPage(controller: chat)),
      );
      await settle();
      await tap(find.byTooltip('Nueva conversación'));
      await tap(find.byKey(const Key('choose-contacts')));
      await tap(find.byKey(Key('select-contact-${saved.identityId}')));
      await tap(find.byKey(const Key('use-contacts')));
      expect(
        chat.conversations.single.peers.single.label,
        'Contacto de prueba',
      );
      await tap(find.byTooltip('Contactos'));
      await tap(find.byKey(Key('contact-${saved.identityId}')));
      await tester.enterText(
        find.byKey(const Key('contact-name')),
        'Contacto renombrado',
      );
      await tap(find.byKey(const Key('save-contact')));
      await tap(find.byType(BackButton));
      await tap(find.byType(BackButton));
      expect(
        chat.conversations.single.peers.single.label,
        'Contacto renombrado',
      );
      final group = chat.selected!;
      await bob.sync_(bootstrap: bootstrap);
      expect((await bob.conversations()).single.groupId, group);
      await tester.enterText(
        find.byKey(const Key('message-draft')),
        'native online message',
      );
      await tap(find.byKey(const Key('send-message')));
      await bob.sync_(bootstrap: bootstrap);
      expect(
        utf8.decode(
          (await bob.historyPage(groupId: group, limit: 50)).events.single.body,
        ),
        'native online message',
      );
      await bob.queueMessage(groupId: group, text: 'native reply');
      await bob.sync_(bootstrap: bootstrap);
      await chat.sync();
      await settle();
      expect(find.text('native reply'), findsOneWidget);
      chat.setActive(false);
      await relayState('offline');
      await tester.enterText(
        find.byKey(const Key('message-draft')),
        'native offline message',
      );
      await tap(find.byKey(const Key('send-message')));
      for (var i = 0; i < 100 && (chat.sending || chat.syncing); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await settle();
      expect(chat.error, isNull);
      expect(find.text('native offline message'), findsOneWidget);
      expect(chat.networkError, isNotNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message-draft')))
            .controller!
            .text,
        isEmpty,
      );
      // Populate enough durable events to exercise a second native GUI page.
      for (var i = 0; i < 52; i++) {
        await alice.queueMessage(groupId: group, text: 'paged message $i');
      }
      await tester.pumpWidget(const SizedBox());
      await alice.close();
      alice = await open(0);
      chat = ConversationController(alice, bootstrap);
      await tester.pumpWidget(
        MaterialApp(home: ConversationsPage(controller: chat)),
      );
      await settle();
      chat.setActive(false);
      await tap(find.byKey(Key('conversation-$group')));
      expect(
        chat.conversations.single.peers.single.label,
        'Contacto renombrado',
      );
      expect(chat.events.length, 50);
      await chat.older();
      await settle();
      expect(chat.events.length, 55);
      expect(
        chat.events
            .where((e) => utf8.decode(e.body) == 'native offline message')
            .length,
        1,
      );
      await relayState('online');
      await chat.sync();
      for (var i = 0; i < 3; i++) {
        await bob.sync_(bootstrap: bootstrap);
      }
      await chat.sync();
      await chat.sync();
      await settle();
      final received = await bob.historyPage(groupId: group, limit: 200);
      expect(received.events.length, 55);
      expect(
        received.events
            .where((e) => utf8.decode(e.body) == 'native offline message')
            .length,
        1,
      );
      expect(chat.events.length, 55);
      final offline = chat.events.singleWhere(
        (e) => utf8.decode(e.body) == 'native offline message',
      );
      expect(offline.delivery.every((d) => d.startsWith('accepted')), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
