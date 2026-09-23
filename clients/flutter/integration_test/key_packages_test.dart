// scripts/test_client_key_packages.py owns the disposable relay and consumes
// its initial five packages. Never point this acceptance at a shared realm.
import 'dart:io';

import 'package:arveil/main.dart';
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
  const invitation = String.fromEnvironment('ARVEIL_TEST_INVITE');
  setUpAll(() async => ArveilRust.init());
  testWidgets(
    'the real GUI detects exhausted keys, replenishes and reopens the dated snapshot',
    (tester) async {
      expect(bootstrap.isNotEmpty && invitation.isNotEmpty, isTrue);
      final directory = await Directory.systemTemp.createTemp(
        'arveil-key-packages-',
      );
      final keys = ProfileKeys(
        keyName: 'test-key-packages-${DateTime.now().microsecondsSinceEpoch}',
      );
      final session = ProfileSession(
        opener: () async {
          await ProfileLocation.excludeFromBackup(directory);
          final key = await keys.forProfile(
            profileExists: await hasProfile(dir: directory.path),
          );
          expect(key.state, anyOf(KeyState.fresh, KeyState.present));
          return openProfile(dir: directory.path, key: key.value!);
        },
      );
      addTearDown(() async {
        await session.close();
        session.dispose();
        await keys.forget();
        await directory.delete(recursive: true);
      });
      Future<void> tap(String text) async {
        await tester.ensureVisible(find.text(text));
        await tester.tap(find.text(text));
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 90),
        );
      }

      await tester.pumpWidget(ArveilApp(session: session));
      await tap('Abrir perfil');
      await tester.enterText(find.byKey(const Key('bootstrap')), bootstrap);
      await tester.enterText(find.byKey(const Key('invite')), invitation);
      await tap('Crear identidad y unirme');
      expect(session.setup!.stage, SetupStage.ready);
      expect(find.text('Disponibilidad sin comprobar'), findsOneWidget);
      for (var i = 0; i < 30; i++) {
        await tap('Comprobar disponibilidad');
        if (session.keyPackages?.available == 0) break;
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(session.keyPackages!.level, KeyPackageLevelView.empty);
      await tap('Reponer claves');
      expect(session.keyPackages!.available, 10);
      expect(session.keyPackages!.publicationPending, isFalse);
      final observed = session.keyPackages!.checkedAt;
      await tap('Cerrar perfil');
      await tap('Abrir perfil');
      expect(session.keyPackages!.available, 10);
      expect(session.keyPackages!.checkedAt, observed);
      await tap('Comprobar disponibilidad');
      expect(session.keyPackages!.available, 10);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
