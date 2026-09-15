// Run only against a disposable test realm. Supply its bootstrap and a
// one-use invitation through a private --dart-define-from-file outside Git.
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
    'secure profile resumes enrollment and reopens without an invitation',
    (tester) async {
      expect(
        bootstrap.isNotEmpty && invitation.isNotEmpty,
        isTrue,
        reason:
            'Supply a disposable relay and invitation in a private define file.',
      );
      final directory = await Directory.systemTemp.createTemp(
        'arveil-onboarding-',
      );
      final keys = ProfileKeys(
        keyName: 'test-onboarding-${DateTime.now().microsecondsSinceEpoch}',
      );
      final session = ProfileSession(
        opener: () async {
          await ProfileLocation.excludeFromBackup(directory);
          final key = await keys.forProfile(
            profileExists: await hasProfile(dir: directory.path),
          );
          expect(
            key.state,
            anyOf(KeyState.fresh, KeyState.present),
            reason: 'This acceptance requires a working platform key store.',
          );
          return openProfile(dir: directory.path, key: key.value!);
        },
      );
      addTearDown(() async {
        await session.close();
        session.dispose();
        await keys.forget();
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(ArveilApp(session: session));
      await tester.tap(find.text('Abrir perfil'));
      await tester.pumpAndSettle();
      expect(session.isOpen, isTrue);
      // Same realm, initially unreachable endpoint. No shell drives the app:
      // the real form, platform key store, Dart bridge and Rust executor run.
      final badEndpoint = bootstrap.replaceFirst(
        RegExp(r'wss?://.*$'),
        'ws://127.0.0.1:1/v1/channel',
      );
      await tester.enterText(find.byKey(const Key('bootstrap')), badEndpoint);
      await tester.enterText(find.byKey(const Key('invite')), invitation);
      await tester.ensureVisible(find.text('Crear identidad y unirme'));
      await tester.tap(find.text('Crear identidad y unirme'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 90),
      );
      expect(session.setup!.stage, SetupStage.redeeming);
      final identity = session.setup!.identityId;
      expect(identity, isNotNull);
      // Closing drops the token. Reopening reads progress from the encrypted
      // native profile; the user can paste the original invitation to resume.
      await tester.tap(find.text('Cerrar perfil'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Abrir perfil'));
      await tester.tap(find.text('Abrir perfil'));
      await tester.pumpAndSettle();
      expect(session.setup!.identityId, identity);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('invite')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(find.byKey(const Key('bootstrap')), bootstrap);
      await tester.enterText(find.byKey(const Key('invite')), invitation);
      await tester.ensureVisible(find.text('Reintentar alta'));
      await tester.tap(find.text('Reintentar alta'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 90),
      );
      expect(session.setup!.stage, SetupStage.ready);
      expect(session.setup!.identityId, identity);
      expect(find.text('Tu perfil está listo'), findsOneWidget);
      await tester.tap(find.text('Cerrar perfil'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Abrir perfil'));
      await tester.tap(find.text('Abrir perfil'));
      await tester.pumpAndSettle();
      expect(session.setup!.stage, SetupStage.ready);
      expect(session.setup!.identityId, identity);
      expect(find.byKey(const Key('invite')), findsNothing);
    },
  );
}
