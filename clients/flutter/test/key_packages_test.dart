import 'dart:async';

import 'package:arveil/main.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeProfile, relay;

KeyPackageSupplyView supply(int? count, {bool pending = false}) =>
    KeyPackageSupplyView(
      available: count,
      checkedAt: count == null ? null : BigInt.from(1800000000),
      level: count == null
          ? KeyPackageLevelView.unknown
          : count == 0
          ? KeyPackageLevelView.empty
          : count <= 3
          ? KeyPackageLevelView.low
          : KeyPackageLevelView.ready,
      publicationPending: pending,
      target: 10,
    );

class SupplyProfile extends FakeProfile {
  SupplyProfile() {
    state = const SetupView(
      stage: SetupStage.ready,
      administrator: false,
      recoveryWarning: false,
      kitStale: false,
      bootstrap: relay,
    );
  }
  KeyPackageSupplyView cached = supply(null);
  KeyPackageSupplyView remote = supply(2);
  bool offline = false;
  bool loseAck = false;
  int checks = 0;
  int publications = 0;
  Completer<void>? publishing;
  @override
  Future<KeyPackageSupplyView> keyPackageSupply() async => cached;
  @override
  Future<KeyPackageSupplyView> checkKeyPackages() async {
    checks++;
    if (offline) {
      throw const CommandError.transport(
        operation: 'check-key-packages',
        reason: 'PRIVATE_DIAGNOSTIC',
      );
    }
    return cached = remote;
  }

  @override
  Future<KeyPackageSupplyView> replenishKeyPackages() async {
    publications++;
    await publishing?.future;
    if (loseAck) {
      cached = supply(0, pending: true);
      throw const CommandError.transport(
        operation: 'replenish-key-packages',
        reason: 'PRIVATE_DIAGNOSTIC',
      );
    }
    return cached = supply(10);
  }
}

void main() {
  Future<ProfileSession> open(
    WidgetTester tester,
    SupplyProfile profile,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = ProfileSession(opener: () async => profile);
    addTearDown(session.dispose);
    await tester.pumpWidget(ArveilApp(session: session));
    await tester.tap(find.text('Abrir perfil'));
    await tester.pumpAndSettle();
    return session;
  }

  testWidgets(
    'opening shows unknown, never zero, and makes no network request',
    (tester) async {
      final profile = SupplyProfile();
      await open(tester, profile);
      expect(profile.checks, 0);
      expect(find.text('Disponibilidad sin comprobar'), findsOneWidget);
      expect(find.byKey(const Key('key-package-count')), findsNothing);
      expect(find.text('Reponer claves'), findsNothing);
      await tester.tap(find.text('Comprobar disponibilidad'));
      await tester.pumpAndSettle();
      expect(find.text('Última consulta: quedan pocas claves'), findsOneWidget);
      expect(find.text('2 claves disponibles según el relay.'), findsOneWidget);
      expect(find.text('Reponer claves'), findsOneWidget);
    },
  );

  testWidgets(
    'exhaustion explains the effect and duplicate replenishment is disabled',
    (tester) async {
      final profile = SupplyProfile()
        ..cached = supply(0)
        ..publishing = Completer<void>();
      final session = await open(tester, profile);
      expect(
        find.text('Última consulta: sin claves disponibles'),
        findsOneWidget,
      );
      await tester.tap(find.text('Reponer claves'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Reponer claves'),
            )
            .onPressed,
        isNull,
      );
      expect(await session.checkKeyPackages(replenish: true), isFalse);
      expect(profile.publications, 1);
      profile.publishing!.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('10 claves disponibles según el relay.'),
        findsOneWidget,
      );
      expect(find.text('Reponer claves'), findsNothing);
    },
  );

  testWidgets(
    'lost acknowledgement is resumable after reopening without private errors',
    (tester) async {
      final profile = SupplyProfile()
        ..cached = supply(0)
        ..loseAck = true;
      await open(tester, profile);
      await tester.tap(find.text('Reponer claves'));
      await tester.pumpAndSettle();
      expect(find.text('Reanudar publicación de claves'), findsOneWidget);
      expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
      await tester.tap(find.text('Cerrar perfil'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abrir perfil'));
      await tester.pumpAndSettle();
      expect(find.text('Reanudar publicación de claves'), findsOneWidget);
      profile.loseAck = false;
      await tester.tap(find.text('Reanudar publicación de claves'));
      await tester.pumpAndSettle();
      expect(find.text('Última consulta: claves disponibles'), findsOneWidget);
    },
  );

  testWidgets(
    'failed refresh retains the dated report and marks it unconfirmed',
    (tester) async {
      final profile = SupplyProfile()
        ..cached = supply(7)
        ..offline = true;
      await open(tester, profile);
      await tester.tap(find.text('Comprobar disponibilidad'));
      await tester.pumpAndSettle();
      expect(find.text('7 claves disponibles según el relay.'), findsOneWidget);
      expect(find.byKey(const Key('key-package-unavailable')), findsOneWidget);
      expect(find.textContaining('Consultado el'), findsOneWidget);
      expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
      expect(
        find.text('Última consulta: sin claves disponibles'),
        findsNothing,
      );
    },
  );
}
