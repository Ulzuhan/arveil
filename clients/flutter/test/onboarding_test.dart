import 'package:arveil/main.dart';
import 'package:arveil/src/design/design.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'navigation_test.dart' show phone;
import 'widget_test.dart' show FakeProfile, home, invitation, relay;

/// An enrollment that succeeds and leaves an administration device with no
/// kit saved yet.
class AdminProfile extends FakeProfile {
  @override
  Future<void> enroll({
    required String bootstrap,
    required String invite,
  }) async {
    enrollments++;
    state = const SetupView(
      administrator: true,
      recoveryWarning: false,
      kitStale: false,
      stage: SetupStage.ready,
      bootstrap: relay,
    );
  }
}

Future<void> openProfile(WidgetTester tester, FakeProfile profile) async {
  tester.view.physicalSize = phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session = ProfileSession(opener: () async => profile);
  addTearDown(session.dispose);
  await tester.pumpWidget(ArveilApp(session: session));
  expect(find.byType(BrandMark), findsOneWidget);
  await tester.tap(find.text('Abrir perfil'));
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a new profile offers three ways in, each with a way back', (
    tester,
  ) async {
    await openProfile(tester, FakeProfile());
    expect(find.text('¿Cómo quieres empezar?'), findsOneWidget);
    for (final key in ['entry-invitation', 'entry-pairing', 'entry-restore']) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    await tapText(tester, 'Vincular con mi otro dispositivo');
    expect(find.byKey(const Key('pair-new-device')), findsOneWidget);
    await tapText(tester, 'Volver al alta');
    await tapText(tester, 'Restaurar desde un kit');
    expect(find.byKey(const Key('restore-panel')), findsOneWidget);
    await tapText(tester, 'Volver al alta');
    expect(find.text('¿Cómo quieres empezar?'), findsOneWidget);
  });

  testWidgets('the invitation goes step by step and keeps what was typed', (
    tester,
  ) async {
    await openProfile(tester, FakeProfile());
    await tapText(tester, 'Unirme con una invitación');
    expect(find.text('Paso 1 de 2'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('bootstrap')), relay);
    await tapText(tester, 'Siguiente');
    expect(find.text('Paso 2 de 2'), findsOneWidget);
    expect(find.byKey(const Key('bootstrap')), findsNothing);
    await tapText(tester, 'Atrás');
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('bootstrap')))
          .controller!
          .text,
      relay,
    );
    await tapText(tester, 'Volver al alta');
    expect(find.text('¿Cómo quieres empezar?'), findsOneWidget);
  });

  testWidgets(
    'a new administration device is offered its kit, and later lands in chats',
    (tester) async {
      final profile = AdminProfile();
      await openProfile(tester, profile);
      await tapText(tester, 'Unirme con una invitación');
      await tester.enterText(find.byKey(const Key('bootstrap')), relay);
      await tapText(tester, 'Siguiente');
      await tester.enterText(find.byKey(const Key('invite')), invitation);
      await tapText(tester, 'Crear identidad y unirme');
      expect(profile.enrollments, 1);
      expect(find.text('Guarda ahora tu kit de identidad'), findsOneWidget);
      expect(find.byKey(const Key('kit-offer-risk')), findsOneWidget);
      expect(home, findsNothing);

      await tester.tap(find.byKey(const Key('kit-offer-later')));
      await tester.pumpAndSettle();
      expect(home, findsOneWidget);
      // The risk stays in view on the chat list until the kit is saved.
      expect(find.byKey(const Key('kit-reminder')), findsOneWidget);
    },
  );

  testWidgets('saving the kit from the offer opens the kit screen', (
    tester,
  ) async {
    final profile = AdminProfile();
    await openProfile(tester, profile);
    await tapText(tester, 'Unirme con una invitación');
    await tester.enterText(find.byKey(const Key('bootstrap')), relay);
    await tapText(tester, 'Siguiente');
    await tester.enterText(find.byKey(const Key('invite')), invitation);
    await tapText(tester, 'Crear identidad y unirme');
    await tester.tap(find.byKey(const Key('kit-offer-save')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Kit de identidad'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(home, findsOneWidget);
  });

  testWidgets('reopening a ready profile goes straight to the chats', (
    tester,
  ) async {
    final profile = FakeProfile()
      ..state = const SetupView(
        administrator: true,
        recoveryWarning: false,
        kitStale: false,
        stage: SetupStage.ready,
        bootstrap: relay,
      );
    await openProfile(tester, profile);
    expect(find.byKey(const Key('kit-offer-risk')), findsNothing);
    expect(home, findsOneWidget);
  });
}
