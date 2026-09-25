// Loss/recovery exercise with disposable profiles only. Exports remain in memory.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:arveil/src/archive_files.dart';
import 'package:arveil/src/archives_page.dart';
import 'package:arveil/src/attachment_files.dart';
import 'package:arveil/src/profile_keys.dart';
import 'package:arveil/src/profile_location.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:arveil/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class MemoryArchive extends ArchiveFiles {
  Uint8List? bytes;
  @override
  Future<bool> save(Uint8List encrypted) async {
    bytes = encrypted;
    return true;
  }

  @override
  Future<Uint8List?> open() async => bytes;
}

class MemoryAttachment extends AttachmentFiles {
  Uint8List? bytes;
  @override
  Future<bool> save(String name, Uint8List value) async {
    bytes = value;
    return true;
  }
}

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const bootstrap = String.fromEnvironment('ARVEIL_TEST_BOOTSTRAP');
  const inviteA = String.fromEnvironment('ARVEIL_TEST_INVITE_A');
  const inviteB = String.fromEnvironment('ARVEIL_TEST_INVITE_B');
  setUpAll(() async => ArveilRust.init());
  testWidgets(
    'lost profile recovers identity and read-only history under a new key',
    (tester) async {
      expect(
        bootstrap.isNotEmpty && inviteA.isNotEmpty && inviteB.isNotEmpty,
        isTrue,
      );
      final root = await Directory.systemTemp.createTemp('arveil-archives-');
      final keys = [
        for (var n = 0; n < 3; n++)
          ProfileKeys(
            keyName: 'test-archive-$n-${DateTime.now().microsecondsSinceEpoch}',
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
      final alice = profiles[0], bob = profiles[1];
      var recovered = profiles[2];
      await alice.enroll(bootstrap: bootstrap, invite: inviteA);
      await bob.enroll(bootstrap: bootstrap, invite: inviteB);
      final route = await bob.ownRoute();
      final safety = (await alice.previewRoutes(
        routes: [route],
      )).single.safetyNumber;
      final group = (await alice.createConversation(
        bootstrap: bootstrap,
        routes: [route],
        safetyNumbers: [safety],
      )).groupId;
      await bob.sync_(bootstrap: bootstrap);
      await alice.queueMessage(groupId: group, text: 'before loss');
      await alice.sync_(bootstrap: bootstrap);
      await bob.sync_(bootstrap: bootstrap);
      final bytes = Uint8List.fromList(utf8.encode('attachment before loss'));
      final id = await alice.queueAttachment(
        groupId: group,
        name: 'history.txt',
        bytes: bytes,
      );
      await alice.resumeAttachment(
        bootstrap: bootstrap,
        groupId: group,
        eventId: id,
      );
      await bob.sync_(bootstrap: bootstrap);
      final kit = await alice
          .exportKit(); // Disposable identity, never a user's kit.
      final archive = MemoryArchive(), file = MemoryAttachment();
      Future<void> until(bool Function() ready) async {
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (!ready()) {
          expect(
            DateTime.now().isBefore(deadline),
            isTrue,
            reason: 'Archive UI did not finish',
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
      }

      Future<void> tap(Finder f) async {
        await until(() => f.evaluate().isNotEmpty);
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pumpAndSettle();
      }

      Future<void> page(Profile p) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: ArchivesPage(profile: p, files: archive, attachments: file),
          ),
        );
        await until(
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
      }

      await page(alice);
      await tap(find.byType(CheckboxListTile));
      await tap(find.byKey(const Key('export-archive')));
      await until(
        () => find
            .byKey(const Key('archive-export-secret'))
            .evaluate()
            .isNotEmpty,
      );
      final secret = tester
          .widget<SelectableText>(
            find.byKey(const Key('archive-export-secret')),
          )
          .data!;
      expect(archive.bytes, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await alice.close();
      await Directory('${root.path}/0').delete(recursive: true);
      await keys[0].forget();
      await recovered.restoreKit(
        bootstrap: bootstrap,
        encrypted: kit.encrypted,
        secret: kit.secret,
      );
      expect(await recovered.conversations(), isEmpty);
      await page(recovered);
      Future<void> import() async {
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        await tap(find.text('Elegir archivo cifrado'));
        await tester.enterText(
          find.byKey(const Key('archive-import-secret')),
          secret,
        );
        await tester.pump();
        await tap(find.byKey(const Key('import-archive')));
        await until(
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(find.byKey(const Key('archive-error')), findsNothing);
      }

      await import();
      expect((await recovered.archivePage(limit: 50)).entries.length, 2);
      await tester.scrollUntilVisible(
        find.text('before loss'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('before loss'), findsOneWidget);
      await tap(find.text('Guardar copia del adjunto'));
      await until(() => file.bytes != null);
      expect(file.bytes, bytes);
      await import();
      expect((await recovered.archivePage(limit: 50)).entries.length, 2);
      await tester.pumpWidget(const SizedBox());
      await recovered.close();
      recovered = await open(2);
      profiles[2] = recovered;
      expect((await recovered.archivePage(limit: 50)).entries.length, 2);
      expect(await recovered.conversations(), isEmpty);
      await recovered.sync_(bootstrap: bootstrap);
      await bob.sync_(bootstrap: bootstrap);
      expect(
        (await bob.historyPage(groupId: group, limit: 50)).events.length,
        2,
      );
      // Recovery did not rejoin the old group. Explicitly start a new conversation.
      final freshRoute = await recovered.ownRoute();
      final freshSafety = (await bob.previewRoutes(
        routes: [freshRoute],
      )).single.safetyNumber;
      final fresh = (await bob.createConversation(
        bootstrap: bootstrap,
        routes: [freshRoute],
        safetyNumbers: [freshSafety],
      )).groupId;
      await recovered.sync_(bootstrap: bootstrap);
      await recovered.queueMessage(groupId: fresh, text: 'after recovery');
      await recovered.sync_(bootstrap: bootstrap);
      await bob.sync_(bootstrap: bootstrap);
      expect(
        (await bob.historyPage(groupId: fresh, limit: 50)).events
            .where(
              (e) =>
                  utf8.decode(e.body, allowMalformed: true) == 'after recovery',
            )
            .length,
        1,
      );
      expect(await Directory('${root.path}/2/downloads').exists(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
