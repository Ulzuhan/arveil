// Real platform key storage, Dart/Rust bridge and relay. Use only a disposable
// realm, supplied through a private --dart-define-from-file outside Git.
import 'dart:io';

import 'package:arveil/src/profile_keys.dart';
import 'package:arveil/src/profile_location.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:arveil/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const bootstrap = String.fromEnvironment('ARVEIL_TEST_BOOTSTRAP');
  const invitation = String.fromEnvironment('ARVEIL_TEST_INVITE');
  setUpAll(() async => ArveilRust.init());

  testWidgets(
    'pair, compare after reopen, export and recover the same identity',
    (tester) async {
      expect(
        bootstrap.isNotEmpty && invitation.isNotEmpty,
        isTrue,
        reason:
            'Supply a disposable relay and invitation in a private define file.',
      );
      final directories = <Directory>[];
      final keys = <ProfileKeys>[];
      final profiles = <Profile>[];
      Future<Profile> create() async {
        final directory = await Directory.systemTemp.createTemp(
          'arveil-pairing-',
        );
        directories.add(directory);
        await ProfileLocation.excludeFromBackup(directory);
        final storage = ProfileKeys(
          keyName: 'test-pairing-${DateTime.now().microsecondsSinceEpoch}',
        );
        keys.add(storage);
        final key = await storage.forProfile(profileExists: false);
        expect(key.state, KeyState.fresh);
        final profile = await openProfile(dir: directory.path, key: key.value!);
        profiles.add(profile);
        return profile;
      }

      Future<Profile> reopen(int index) async {
        await profiles[index].close();
        final key = await keys[index].forProfile(profileExists: true);
        expect(key.state, KeyState.present);
        return profiles[index] = await openProfile(
          dir: directories[index].path,
          key: key.value!,
        );
      }

      addTearDown(() async {
        for (final profile in profiles) {
          await profile.close();
        }
        for (final key in keys) {
          await key.forget();
        }
        for (final directory in directories) {
          await directory.delete(recursive: true);
        }
      });

      final admin = await create();
      await admin.enroll(bootstrap: bootstrap, invite: invitation);
      final identity = (await admin.setup()).identityId;
      expect(identity, isNotNull);
      var linked = await create();
      await linked.beginPairing(bootstrap: bootstrap);
      final pair = (await linked.setup()).pairing!;
      final waiting = linked.awaitPairing(bootstrap: bootstrap, session: pair);
      final comparison = await admin.approvePairing(
        bootstrap: bootstrap,
        code: pair.code,
      );
      await waiting;
      expect((await linked.setup()).pairing!.verificationCode, comparison);
      await expectLater(
        linked.confirmPairing(
          bootstrap: bootstrap,
          sessionId: pair.sessionId,
          verificationCode: 'wrong-code',
        ),
        throwsA(isA<CommandError>()),
      );
      linked = await reopen(1);
      expect((await linked.setup()).pairing!.verificationCode, comparison);
      await linked.confirmPairing(
        bootstrap: bootstrap,
        sessionId: pair.sessionId,
        verificationCode: comparison,
      );
      expect((await linked.setup()).identityId, identity);
      expect((await linked.setup()).stage, SetupStage.ready);
      expect((await linked.setup()).administrator, isFalse);
      await expectLater(linked.exportKit(), throwsA(isA<CommandError>()));

      final kit = await admin.exportKit();
      expect(
        String.fromCharCodes(kit.encrypted.take(21)),
        'age-encryption.org/v1',
      );
      var recovered = await create();
      await expectLater(
        recovered.restoreKit(
          bootstrap: bootstrap,
          encrypted: kit.encrypted,
          secret: 'wrong-secret',
        ),
        throwsA(isA<CommandError>()),
      );
      expect((await recovered.setup()).identityId, isNull);
      await recovered.restoreKit(
        bootstrap: bootstrap,
        encrypted: kit.encrypted,
        secret: kit.secret,
      );
      final restored = await recovered.setup();
      expect(restored.identityId, identity);
      expect(restored.stage, SetupStage.ready);
      expect(restored.administrator, isTrue);
      expect(restored.recoveryWarning, isFalse);
      expect(await recovered.conversations(), isEmpty);
      // Repeating and reopening must reuse the same device, mailbox and identity.
      await recovered.restoreKit(
        bootstrap: bootstrap,
        encrypted: kit.encrypted,
        secret: kit.secret,
      );
      recovered = await reopen(2);
      await recovered.resumeRecovery();
      expect((await recovered.setup()).identityId, identity);
      expect((await recovered.setup()).stage, SetupStage.ready);
      await expectLater(
        admin.approvePairing(bootstrap: bootstrap, code: pair.code),
        throwsA(isA<CommandError>()),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
