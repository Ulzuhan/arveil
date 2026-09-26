import 'dart:async';
import 'dart:typed_data';

import 'package:arveil/main.dart';
import 'package:arveil/src/kit_files.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart'
    show FakeProfile, destination, home, openSetting, openSettings, relay;

const secret = 'TEST-ONLY-RECOVERY-SECRET';
const sas = '123456';
PairingView pairing({String? comparison, bool expired = false}) => PairingView(
  sessionId: Uint8List.fromList([1, 2, 3]),
  code: 'arveil-pair:v1:fixture',
  expiresAt: BigInt.from(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300),
  verificationCode: comparison,
  committing: false,
  expired: expired,
);

class RecoveryProfile extends FakeProfile {
  int restores = 0;
  int resumes = 0;
  int confirmations = 0;
  int cancellations = 0;
  Completer<void>? wait;
  void ready({bool admin = true}) {
    state = SetupView(
      stage: SetupStage.ready,
      administrator: admin,
      recoveryWarning: false,
      kitStale: false,
      bootstrap: relay,
    );
  }

  void pendingPair({String? comparison, bool expired = false}) {
    state = SetupView(
      stage: SetupStage.linkedDevice,
      administrator: false,
      recoveryWarning: false,
      kitStale: false,
      bootstrap: relay,
      pairing: pairing(comparison: comparison, expired: expired),
    );
  }

  @override
  Future<KitView> exportKit() async =>
      KitView(encrypted: Uint8List.fromList([1, 2, 3]), secret: secret);
  int kitConfirmations = 0;
  @override
  Future<void> confirmKitSaved() async {
    kitConfirmations++;
    state = SetupView(
      stage: SetupStage.ready,
      administrator: true,
      recoveryWarning: false,
      kitSavedAt: 1790000000,
      kitStale: false,
      bootstrap: relay,
    );
  }

  @override
  Future<void> restoreKit({
    required String bootstrap,
    required List<int> encrypted,
    required String secret,
  }) async {
    expect(bootstrap, relay);
    expect(encrypted, [1, 2, 3]);
    expect(secret, 'TEST-ONLY-RECOVERY-SECRET');
    restores++;
    state = const SetupView(
      stage: SetupStage.recovering,
      administrator: true,
      recoveryWarning: false,
      kitStale: false,
      bootstrap: relay,
    );
    throw const CommandError.transport(
      operation: 'restore',
      reason: 'PRIVATE_DIAGNOSTIC',
    );
  }

  @override
  Future<void> resumeRecovery() async {
    resumes++;
    ready();
  }

  @override
  Future<void> confirmPairing({
    required String bootstrap,
    required List<int> sessionId,
    required String verificationCode,
  }) async {
    confirmations++;
    if (verificationCode != sas) {
      throw const CommandError.domain(
        operation: 'confirm',
        reason: 'PRIVATE_DIAGNOSTIC',
      );
    }
    ready(admin: false);
  }

  @override
  Future<void> awaitPairing({
    required String bootstrap,
    required PairingView session,
  }) async {
    await wait?.future;
  }

  @override
  Future<bool> cancelPairing({required List<int> sessionId}) async {
    cancellations++;
    state = const SetupView(
      stage: SetupStage.linkedDevice,
      administrator: false,
      recoveryWarning: false,
      kitStale: false,
      bootstrap: relay,
    );
    wait?.completeError(
      const CommandError.domain(operation: 'wait', reason: 'cancelled'),
    );
    return true;
  }
}

class MemoryKitFiles extends KitFiles {
  bool saved = false;
  Completer<bool>? saving;
  @override
  Future<bool> save(List<int> encrypted) async {
    expect(encrypted, [1, 2, 3]);
    return saving == null ? saved : await saving!.future;
  }

  @override
  Future<Uint8List?> open() async => Uint8List.fromList([1, 2, 3]);
}

void main() {
  Future<ProfileSession> open(
    WidgetTester tester,
    RecoveryProfile profile, {
    KitFiles files = const KitFiles(),
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = ProfileSession(opener: () async => profile);
    addTearDown(session.dispose);
    await tester.pumpWidget(ArveilApp(session: session, kitFiles: files));
    await tester.tap(find.text('Abrir perfil'));
    await tester.pumpAndSettle();
    return session;
  }

  testWidgets('cancelled save reveals no key; saved key clears on background', (
    tester,
  ) async {
    final profile = RecoveryProfile()..ready();
    final files = MemoryKitFiles();
    await open(tester, profile, files: files);
    await openSetting(tester, 'open-kit');
    await tester.tap(find.text('Guardar kit cifrado'));
    await tester.pumpAndSettle();
    expect(find.text(secret), findsNothing);
    files.saved = true;
    await tester.tap(find.text('Guardar kit cifrado'));
    await tester.pumpAndSettle();
    expect(find.text(secret), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text(secret), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Posponer el kit'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('kit-deferred-warning')), findsOneWidget);
  });
  testWidgets(
    'confirming the saved key records the kit and ends the reminder',
    (tester) async {
      final profile = RecoveryProfile()..ready();
      final files = MemoryKitFiles()..saved = true;
      await open(tester, profile, files: files);
      expect(find.byKey(const Key('kit-reminder')), findsOneWidget);
      // The reminder leads to the kit screen.
      await tester.tap(find.text('Guardar kit'));
      await tester.pumpAndSettle();
      expect(find.text('Guardar kit cifrado').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Guardar kit cifrado'));
      await tester.pumpAndSettle();
      expect(profile.kitConfirmations, 0, reason: 'a saved file is not enough');
      await tester.ensureVisible(
        find.text('He guardado la clave por separado'),
      );
      await tester.tap(find.text('He guardado la clave por separado'));
      await tester.pumpAndSettle();
      expect(profile.kitConfirmations, 1);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(destination('Chats'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('kit-reminder')), findsNothing);
    },
  );

  testWidgets('a stale kit is asked for again, and later hides it for now', (
    tester,
  ) async {
    final profile = RecoveryProfile()
      ..state = SetupView(
        stage: SetupStage.ready,
        administrator: true,
        recoveryWarning: false,
        kitSavedAt: 1790000000,
        kitStale: true,
        bootstrap: relay,
      );
    await open(tester, profile);
    expect(
      find.textContaining('cambiaron después de guardar el kit'),
      findsOneWidget,
    );
    await tester.tap(find.text('Más tarde'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('kit-reminder')), findsNothing);
  });

  testWidgets('a linked device is not asked for a kit it cannot export', (
    tester,
  ) async {
    await open(tester, RecoveryProfile()..ready(admin: false));
    expect(find.byKey(const Key('kit-reminder')), findsNothing);
  });

  testWidgets('a background save needs an explicit foreground key reveal', (
    tester,
  ) async {
    final profile = RecoveryProfile()..ready();
    final files = MemoryKitFiles()..saving = Completer<bool>();
    await open(tester, profile, files: files);
    await openSetting(tester, 'open-kit');
    await tester.tap(find.text('Guardar kit cifrado'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    files.saving!.complete(true);
    await tester.pumpAndSettle();
    expect(find.text(secret), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(secret), findsNothing);
    await tester.tap(find.text('Mostrar clave del kit guardado'));
    await tester.pumpAndSettle();
    expect(find.text(secret), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(secret), findsNothing);
    expect(find.text('Mostrar clave del kit guardado'), findsNothing);
  });

  testWidgets(
    'recovery requires consent and resumes after a lost reply without the kit',
    (tester) async {
      final profile = RecoveryProfile();
      await open(tester, profile, files: MemoryKitFiles());
      await tester.tap(find.text('Restaurar desde un kit'));
      await tester.pumpAndSettle();
      final restore = find.widgetWithText(
        FilledButton,
        'Restaurar identidad y revocar dispositivos',
      );
      expect(tester.widget<FilledButton>(restore).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('recovery-bootstrap')),
        relay,
      );
      await tester.tap(find.text('Seleccionar kit cifrado'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('recovery-secret')), secret);
      await tester.tap(find.byKey(const Key('recovery-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(profile.restores, 1);
      expect(find.text('Continúa la recuperación'), findsOneWidget);
      expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
      expect(find.byKey(const Key('recovery-secret')), findsNothing);
      await tester.tap(find.text('Reanudar recuperación'));
      await tester.pumpAndSettle();
      expect(profile.resumes, 1);
      expect(home, findsOneWidget);
    },
  );
  testWidgets(
    'comparison requires manually entering the code and retains a wrong-code session',
    (tester) async {
      final profile = RecoveryProfile()..pendingPair(comparison: sas);
      await open(tester, profile);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('pair-comparison')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('pair-comparison')),
        '000000',
      );
      await tester.tap(find.text('Confirmar comparación'));
      await tester.pumpAndSettle();
      expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
      expect(find.text('Código de comparación'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('pair-comparison')), sas);
      await tester.tap(find.text('Confirmar comparación'));
      await tester.pumpAndSettle();
      expect(profile.confirmations, 2);
      expect(home, findsOneWidget);
      await openSettings(tester);
      expect(find.text('Guardar kit cifrado'), findsNothing);
      expect(
        find.textContaining('El kit de identidad se exporta'),
        findsOneWidget,
      );
    },
  );
  testWidgets('expired pairing cannot be confirmed', (tester) async {
    final profile = RecoveryProfile()
      ..pendingPair(comparison: sas, expired: true);
    await open(tester, profile);
    expect(find.text('Confirmar comparación'), findsNothing);
    await tester.tap(find.text('Cancelar vinculación'));
    await tester.pumpAndSettle();
    expect(profile.cancellations, 1);
    expect(find.text('Generar código de vinculación'), findsOneWidget);
  });
  testWidgets('cancel remains available during the network wait', (
    tester,
  ) async {
    final profile = RecoveryProfile()
      ..pendingPair()
      ..wait = Completer<void>();
    final session = await open(tester, profile);
    final waiting = session.waitForPairing();
    await tester.pump();
    expect(session.busy, isTrue);
    await tester.tap(find.text('Cancelar vinculación'));
    await waiting;
    await tester.pumpAndSettle();
    expect(profile.cancellations, 1);
    expect(session.error, isNull);
    expect(session.busy, isFalse);
    expect(find.text('Generar código de vinculación'), findsOneWidget);
  });
}
