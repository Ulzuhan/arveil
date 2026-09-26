// Run only through scripts/test_client_conversations.py (disposable relay).
import 'dart:convert';
import 'dart:io';

import 'package:arveil/main.dart';
import 'package:arveil/src/appearance.dart';
import 'package:arveil/src/conversation_controller.dart';
import 'package:arveil/src/conversations_page.dart';
import 'package:arveil/src/design/design.dart';
import 'package:arveil/src/profile_keys.dart';
import 'package:arveil/src/profile_location.dart';
import 'package:arveil/src/profile_session.dart';
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
      ProfileSession? uiSession;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await uiSession?.close();
        uiSession?.dispose();
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

      Future<ConversationController> showProfile() async {
        uiSession = ProfileSession(opener: () async => alice);
        await tester.pumpWidget(
          ArveilApp(
            session: uiSession,
            appearance: AppearanceController(
              MemoryAppearanceStore(),
              const Appearance(language: LanguageChoice.spanish),
            ),
          ),
        );
        await tap(find.text('Abrir perfil'));
        return tester
            .widget<ConversationsPage>(find.byType(ConversationsPage))
            .controller;
      }

      Future<void> hideProfile() async {
        await tester.pumpWidget(const SizedBox());
        await uiSession?.close();
        uiSession?.dispose();
        uiSession = null;
      }

      Future<void> destination(String label) async {
        // A phone's open conversation hides its bottom navigation.
        if (find.byKey(const Key('navigation-rail')).evaluate().isEmpty &&
            find.byKey(const Key('navigation-bar')).evaluate().isEmpty) {
          await tap(find.byTooltip('Volver a conversaciones'));
        }
        final navigation = find.byWidgetPredicate(
          (w) => w is NavigationRail || w is NavigationBar,
        );
        await tap(find.descendant(of: navigation, matching: find.text(label)));
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
      var chat = await showProfile();
      await destination('Contactos');
      await tap(find.byTooltip('Añadir contacto'));
      await tester.enterText(
        find.byKey(const Key('contact-name')),
        'Contacto de prueba',
      );
      await tester.enterText(find.byKey(const Key('contact-route')), bobRoute);
      await tap(find.text('Preparar contacto'));
      expect(
        tester
            .widget<SafetyNumberGrid>(find.byKey(const Key('contact-safety')))
            .number,
        aPreview.single.safetyNumber,
      );
      await tap(find.byKey(const Key('save-contact')));
      expect((await alice.contacts()).single.verified, isFalse);
      await tap(find.byKey(const Key('contact-compared')));
      expect((await alice.contacts()).single.verified, isTrue);
      await tap(find.byType(BackButton));
      // Reopen before choosing the saved contact: no route is pasted again.
      await hideProfile();
      alice = await open(0);
      final saved = (await alice.contacts()).single;
      expect(saved.label, 'Contacto de prueba');
      expect(saved.verified, isTrue);
      chat = await showProfile();
      await tap(find.byTooltip('Nueva conversación'));
      await tap(find.byKey(const Key('choose-contacts')));
      await tap(find.byKey(Key('select-contact-${saved.identityId}')));
      await tap(find.byKey(const Key('use-contacts')));
      expect(
        chat.conversations.single.peers.single.label,
        'Contacto de prueba',
      );
      final group = chat.selected!;
      await destination('Contactos');
      await tap(find.byKey(Key('contact-${saved.identityId}')));
      await tester.enterText(
        find.byKey(const Key('contact-name')),
        'Contacto renombrado',
      );
      await tap(find.byKey(const Key('save-contact')));
      await tap(find.byType(BackButton));
      await destination('Chats');
      if (chat.selected == null) {
        await tap(find.byKey(Key('conversation-$group')));
      }
      await chat.refresh();
      await settle();
      expect(
        chat.conversations.single.peers.single.label,
        'Contacto renombrado',
      );
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
      // Actual Rust unread state must survive sync while settings hide the chat.
      await destination('Ajustes');
      await bob.queueMessage(groupId: group, text: 'native reply');
      await bob.sync_(bootstrap: bootstrap);
      await chat.sync();
      await settle();
      expect(find.text('native reply'), findsNothing);
      expect((await alice.conversations()).single.unread, 1);
      await destination('Chats');
      if (chat.selected == null) {
        await tap(find.byKey(Key('conversation-$group')));
      }
      expect(find.text('native reply'), findsOneWidget);
      for (var i = 0; i < 50; i++) {
        if ((await alice.conversations()).single.unread == 0) break;
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect((await alice.conversations()).single.unread, 0);
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
      await hideProfile();
      alice = await open(0);
      chat = await showProfile();
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
      await hideProfile();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
