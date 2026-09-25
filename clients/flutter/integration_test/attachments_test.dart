// Run through scripts/test_client_conversations.py --scenario attachments.
import 'dart:io';
import 'dart:typed_data';
import 'package:arveil/src/attachment_files.dart';
import 'package:arveil/src/conversation_controller.dart';
import 'package:arveil/src/conversations_page.dart';
import 'package:arveil/src/profile_keys.dart';
import 'package:arveil/src/profile_location.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:arveil/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// The native crypto/storage/network and GUI actions run here; native picker
// dialogs have separate acceptance. No exported fixture is written to disk.
class TestFiles extends AttachmentFiles {
  TestFiles(this.bytes);
  final Uint8List bytes;
  Uint8List? exported;
  @override
  Future<PickedAttachment?> open() async => PickedAttachment('same.txt', bytes);
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    expect(name, 'same.txt');
    exported = bytes;
    return true;
  }
}

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const bootstrap = String.fromEnvironment('ARVEIL_TEST_BOOTSTRAP');
  const inviteA = String.fromEnvironment('ARVEIL_TEST_INVITE_A');
  const inviteB = String.fromEnvironment('ARVEIL_TEST_INVITE_B');
  const control = String.fromEnvironment('ARVEIL_TEST_CONTROL');
  const token = String.fromEnvironment('ARVEIL_TEST_CONTROL_TOKEN');
  setUpAll(() async => ArveilRust.init());
  testWidgets(
    'explicit attachments survive offline reopen without plaintext downloads or name collisions',
    (tester) async {
      expect(
        bootstrap.isNotEmpty && inviteA.isNotEmpty && inviteB.isNotEmpty,
        isTrue,
      );
      final root = await Directory.systemTemp.createTemp('arveil-attachments-');
      final keys = [
        for (var n = 0; n < 2; n++)
          ProfileKeys(
            keyName: 'test-file-$n-${DateTime.now().microsecondsSinceEpoch}',
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
      var bob = await open(1);
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
      Future<void> until(bool Function() ready, String reason) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!ready()) {
          expect(DateTime.now().isBefore(deadline), isTrue, reason: reason);
          await tester.pump(const Duration(milliseconds: 100));
        }
        await settle();
      }

      Future<void> transferred(
        ConversationController controller,
        String id,
        AttachmentStateView state,
      ) => until(
        () =>
            !controller.activeTransfers.contains(id) &&
            controller.events.any(
              (event) =>
                  event.eventId == id && event.attachment?.state == state,
            ),
        'The transfer did not reach $state',
      );

      Future<void> tap(Finder finder) async {
        await until(() => finder.evaluate().isNotEmpty, 'Missing UI action');
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await settle();
      }

      await alice.enroll(bootstrap: bootstrap, invite: inviteA);
      await bob.enroll(bootstrap: bootstrap, invite: inviteB);
      final route = await bob.ownRoute();
      final comparison = (await alice.previewRoutes(
        routes: [route],
      )).single.safetyNumber;
      final created = await alice.createConversation(
        bootstrap: bootstrap,
        routes: [route],
        safetyNumbers: [comparison],
      );
      final group = created.groupId;
      await bob.sync_(bootstrap: bootstrap);
      final bytes = Uint8List.fromList(List.generate(170000, (n) => n % 251));
      final files = TestFiles(bytes);
      var chat = ConversationController(alice, bootstrap);
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsPage(controller: chat, attachmentFiles: files),
        ),
      );
      await settle();
      await chat.select(group);
      await settle();
      chat.setActive(false);
      await relayState('offline');
      await tap(find.byKey(const Key('attach-file')));
      await tap(find.byKey(const Key('confirm-attachment')));
      // A settled frame does not mean native I/O has completed.
      await until(
        () => chat.events.length == 1 && chat.activeTransfers.isEmpty,
        'Offline attachment was not durably queued',
      );
      final queued = (await alice.historyPage(
        groupId: group,
        limit: 50,
      )).events.single;
      expect(queued.attachment!.state, AttachmentStateView.pending);
      expect(queued.body, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await alice.close();
      alice = await open(0);
      await relayState('online');
      chat = ConversationController(alice, bootstrap);
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsPage(controller: chat, attachmentFiles: files),
        ),
      );
      await settle();
      await chat.select(group);
      await settle();
      await tap(find.byKey(Key('resume-${queued.eventId}')));
      await transferred(chat, queued.eventId, AttachmentStateView.sent);
      expect(
        (await alice.historyPage(
          groupId: group,
          limit: 50,
        )).events.single.attachment!.state,
        AttachmentStateView.sent,
      );
      await bob.sync_(bootstrap: bootstrap);
      var received = (await bob.historyPage(
        groupId: group,
        limit: 50,
      )).events.single;
      expect(received.attachment!.state, AttachmentStateView.pending);
      expect(received.body, isEmpty);
      expect(await Directory('${root.path}/1/downloads').exists(), isFalse);
      await tester.pumpWidget(const SizedBox());
      var peerChat = ConversationController(bob, bootstrap);
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsPage(controller: peerChat, attachmentFiles: files),
        ),
      );
      await settle();
      await peerChat.select(group);
      await settle();
      await tap(find.byKey(Key('resume-${received.eventId}')));
      await transferred(peerChat, received.eventId, AttachmentStateView.ready);
      await tap(find.byKey(Key('export-${received.eventId}')));
      expect(files.exported, isNull);
      await tap(find.byKey(const Key('confirm-export')));
      await until(() => files.exported != null, 'Export did not complete');
      expect(files.exported, bytes);

      final secondBytes = Uint8List.fromList([9, 8, 7, 6]);
      final second = await alice.queueAttachment(
        groupId: group,
        name: 'same.txt',
        bytes: secondBytes,
      );
      await alice.resumeAttachment(
        bootstrap: bootstrap,
        groupId: group,
        eventId: second,
      );
      await peerChat.sync();
      await settle();
      final secondIncoming = peerChat.events.singleWhere(
        (e) => e.eventId != received.eventId,
      );
      expect(secondIncoming.attachment!.name, received.attachment!.name);
      await tap(find.byKey(Key('resume-${secondIncoming.eventId}')));
      await transferred(
        peerChat,
        secondIncoming.eventId,
        AttachmentStateView.ready,
      );
      expect(
        await bob.exportAttachment(groupId: group, eventId: received.eventId),
        bytes,
      );
      expect(
        await bob.exportAttachment(
          groupId: group,
          eventId: secondIncoming.eventId,
        ),
        secondBytes,
      );
      await tester.pumpWidget(const SizedBox());
      await bob.close();
      bob = await open(1);
      expect(
        await bob.exportAttachment(groupId: group, eventId: received.eventId),
        bytes,
      );
      expect(
        await bob.exportAttachment(
          groupId: group,
          eventId: secondIncoming.eventId,
        ),
        secondBytes,
      );
      await bob.sync_(bootstrap: bootstrap);
      await bob.sync_(bootstrap: bootstrap);
      expect(
        (await bob.historyPage(groupId: group, limit: 50)).events.length,
        2,
      );

      final cancelled = await alice.queueAttachment(
        groupId: group,
        name: 'same.txt',
        bytes: [1],
      );
      chat = ConversationController(alice, bootstrap);
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsPage(controller: chat, attachmentFiles: files),
        ),
      );
      await settle();
      await chat.select(group);
      await settle();
      await tap(find.byKey(Key('cancel-$cancelled')));
      await transferred(chat, cancelled, AttachmentStateView.cancelled);
      final row = (await alice.historyPage(
        groupId: group,
        limit: 50,
      )).events.singleWhere((e) => e.eventId == cancelled);
      expect(row.attachment!.state, AttachmentStateView.cancelled);
      expect(await Directory('${root.path}/0/downloads').exists(), isFalse);
      expect(await Directory('${root.path}/1/downloads').exists(), isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
