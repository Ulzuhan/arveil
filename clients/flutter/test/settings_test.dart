import 'dart:async';

import 'package:arveil/src/contacts_page.dart';
import 'package:arveil/src/design/design.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'contacts_test.dart' show AddressProfile, person;
import 'devices_test.dart' show DevicesProfile;
import 'navigation_test.dart' show HomeProfile, desktop, openHome, phone;
import 'widget_test.dart' show destination, openSetting, openSettings, relay;

class SettingsProfile extends HomeProfile {
  SettingsProfile({
    bool administrator = true,
    int? kitSavedAt = 1790000000,
    bool kitStale = false,
  }) {
    state = SetupView(
      stage: SetupStage.ready,
      administrator: administrator,
      recoveryWarning: false,
      kitStale: kitStale,
      kitSavedAt: kitSavedAt,
      bootstrap: relay,
    );
  }
  List<ContactView> people = [];
  @override
  Future<List<ContactView>> contacts() async => people;
  @override
  Future<String> ownRoute() async => 'arveil-route:v0:fixture';
}

Finder row(String key) => find.byKey(Key(key));

class RevocationProfile extends SettingsProfile {
  final deviceState = DevicesProfile();

  @override
  Future<DeviceInventoryView> devices() => deviceState.devices();

  @override
  Future<void> revokeDevice({
    required String bootstrap,
    required String deviceId,
  }) async {
    try {
      await deviceState.revokeDevice(bootstrap: bootstrap, deviceId: deviceId);
    } finally {
      state = const SetupView(
        stage: SetupStage.ready,
        administrator: true,
        recoveryWarning: false,
        kitStale: true,
        kitSavedAt: 1790000000,
        bootstrap: relay,
      );
    }
  }
}

void main() {
  testWidgets('a revocation completing after leaving still refreshes the kit', (
    tester,
  ) async {
    final profile = RevocationProfile()
      ..deviceState.waiting = Completer<void>();
    await openHome(tester, desktop, profile: profile);
    await openSetting(tester, 'open-devices');
    await tester.ensureVisible(row('revoke-other-device'));
    await tester.tap(row('revoke-other-device'));
    await tester.pumpAndSettle();
    await tester.tap(row('confirm-device-revocation'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    profile.deviceState.waiting!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Desactualizado: tus dispositivos cambiaron'), findsOne);
    expect(tester.takeException(), isNull);
  });

  for (final offline in [false, true]) {
    testWidgets('revocation refreshes the kit warning (offline: $offline)', (
      tester,
    ) async {
      final profile = RevocationProfile()..deviceState.fail = offline;
      await openHome(tester, desktop, profile: profile);
      await openSetting(tester, 'open-devices');
      final revoke = row('revoke-other-device');
      await tester.ensureVisible(revoke);
      await tester.tap(revoke);
      await tester.pumpAndSettle();
      await tester.tap(row('confirm-device-revocation'));
      await tester.pumpAndSettle();
      expect(profile.deviceState.revocations, 1);
      expect((await profile.setup()).kitStale, isTrue);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Desactualizado: tus dispositivos cambiaron'), findsOne);
      expect(tester.widget<SettingsRow>(row('open-kit')).attention, isTrue);
      await tester.tap(destination('Chats'));
      await tester.pumpAndSettle();
      expect(find.text('Actualiza tu kit de identidad'), findsOne);
    });
  }

  testWidgets('settings group what the profile can do in sections', (
    tester,
  ) async {
    await openHome(tester, desktop, profile: SettingsProfile());
    await openSettings(tester);
    for (final section in [
      'Tu identidad',
      'Seguridad y recuperación',
      'Conexión',
      'Aplicación',
    ]) {
      expect(find.text(section), findsOneWidget);
    }
    expect(find.text('Este dispositivo administra tus dispositivos'), findsOne);
    expect(find.text('Guardado el 21/9/2026'), findsOneWidget);
    expect(row('open-pairing'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a kit never saved or out of date asks for attention', (
    tester,
  ) async {
    await openHome(tester, phone, profile: SettingsProfile(kitSavedAt: null));
    await openSettings(tester);
    expect(find.text('Sin guardar'), findsOneWidget);
    expect(
      tester.widget<SettingsRow>(row('open-kit')).attention,
      isTrue,
      reason: 'the row draws itself as needing the user',
    );
  });

  testWidgets('a linked device explains where the kit is exported', (
    tester,
  ) async {
    await openHome(
      tester,
      desktop,
      profile: SettingsProfile(administrator: false),
    );
    await openSettings(tester);
    expect(row('open-kit'), findsNothing);
    expect(row('open-pairing'), findsNothing);
    expect(find.text('Dispositivo vinculado'), findsOneWidget);
    expect(find.textContaining('El kit de identidad se exporta'), findsOne);
  });

  testWidgets('each row opens its own screen with a bar that names it', (
    tester,
  ) async {
    await openHome(tester, desktop, profile: SettingsProfile());
    await openSetting(tester, 'open-kit');
    expect(find.widgetWithText(AppBar, 'Kit de identidad'), findsOneWidget);
    expect(find.text('Guardar kit cifrado'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await openSetting(tester, 'open-keys');
    expect(
      find.widgetWithText(AppBar, 'Claves para grupos nuevos'),
      findsOneWidget,
    );
    expect(find.text('Comprobar disponibilidad'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await openSetting(tester, 'open-pairing');
    expect(
      find.widgetWithText(AppBar, 'Vincular otro dispositivo'),
      findsOneWidget,
    );
  });

  testWidgets('contacts share this device route and list people', (
    tester,
  ) async {
    final profile = SettingsProfile()
      ..people = [person(verified: true), person(id: 'bob', name: 'Bruno')];
    await openHome(tester, phone, profile: profile);
    await tester.tap(destination('Contactos'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: row('contact-alice'),
        matching: find.byType(VerifiedMark),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row('contact-bob'),
        matching: find.byType(UnverifiedChip),
      ),
      findsOneWidget,
    );
    await tester.tap(row('share-route'));
    await tester.pumpAndSettle();
    expect(find.text('arveil-route:v0:fixture'), findsOneWidget);
  });

  testWidgets('an empty contact list offers to add someone', (tester) async {
    await openHome(tester, phone, profile: SettingsProfile());
    await tester.tap(destination('Contactos'));
    await tester.pumpAndSettle();
    expect(find.byType(EmptyState), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Añadir contacto'));
    await tester.pumpAndSettle();
    expect(find.byType(ContactEditorPage), findsOneWidget);
  });

  testWidgets('a new contact is saved verified only after «Coinciden»', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final profile = AddressProfile();
    await tester.pumpWidget(
      MaterialApp(home: ContactEditorPage(profile: profile)),
    );
    await tester.enterText(row('contact-route'), 'fixture route');
    await tester.tap(find.text('Preparar contacto'));
    await tester.pumpAndSettle();
    expect(find.byType(SafetyNumberGrid), findsOneWidget);
    await tester.tap(row('contact-mismatch'));
    await tester.pumpAndSettle();
    expect(find.text('Los números no coinciden'), findsOneWidget);
    await tester.tap(row('contact-compared'));
    await tester.pumpAndSettle();
    expect(find.text('Los números no coinciden'), findsNothing);
    expect(
      find.text('Coinciden: el contacto se guardará como verificado.'),
      findsOneWidget,
    );
    await tester.tap(row('save-contact'));
    await tester.pumpAndSettle();
    expect(profile.savedNumber, '12345 67890');
  });
}
