import 'dart:async';

import 'package:arveil/main.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const relay = 'arveil-bootstrap:v0:fixture';
final invitation = 'ab' * 32;

class FakeProfile implements Profile {
  SetupView state = const SetupView(
    administrator: false,
    recoveryWarning: false,
    kitStale: false,
    stage: SetupStage.new_,
  );
  int enrollments = 0;
  int closes = 0;
  bool failSetup = false;
  bool failEnrollment = true;
  Completer<void>? pending;

  @override
  Future<SetupView> setup() async {
    if (failSetup) throw StateError('private storage diagnostic');
    return state;
  }

  @override
  Future<void> enroll({
    required String bootstrap,
    required String invite,
  }) async {
    enrollments++;
    await pending?.future;
    expect(bootstrap, relay);
    expect(invite, invitation);
    if (failEnrollment) {
      state = const SetupView(
        administrator: false,
        recoveryWarning: false,
        kitStale: false,
        stage: SetupStage.redeeming,
        bootstrap: relay,
      );
      throw const CommandError.transport(
        operation: 'enroll',
        reason: 'PRIVATE_TOKEN_AND_PATH',
      );
    }
    state = const SetupView(
      administrator: false,
      recoveryWarning: false,
      kitStale: false,
      stage: SetupStage.ready,
      bootstrap: relay,
    );
  }

  @override
  Future<KeyPackageSupplyView> keyPackageSupply() async =>
      const KeyPackageSupplyView(
        available: null,
        checkedAt: null,
        level: KeyPackageLevelView.unknown,
        publicationPending: false,
        target: 10,
      );

  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<List<ConversationView>> conversations() async => [];

  // A ready profile opens the chats, which watch progress and sync.
  @override
  BigInt startWatching() => BigInt.one;
  @override
  Stream<ProgressView> watch({required BigInt generation}) =>
      const Stream.empty();
  @override
  void stopWatching({required BigInt generation}) {}
  @override
  Future<SyncView> sync_({required String bootstrap}) async =>
      const SyncView(processedEnvelopes: 0);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A destination of the main navigation, in the rail or the bottom bar.
Finder destination(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is NavigationRail || w is NavigationBar),
  matching: find.text(label),
);

/// Whether the main navigation of a ready profile is on screen.
Finder get home =>
    find.byWidgetPredicate((w) => w is NavigationRail || w is NavigationBar);

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(destination('Ajustes'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'enrollment validates, retries and recognizes completion after reopening',
    (tester) async {
      // The whole form on screen: a lazy list does not build what is
      // scrolled away, and the title is what this test reads.
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final profile = FakeProfile();
      final session = ProfileSession(opener: () async => profile);
      addTearDown(session.dispose);
      await tester.pumpWidget(ArveilApp(session: session));
      await tester.tap(find.text('Abrir perfil'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Crear identidad y unirme'));
      await tester.tap(find.text('Crear identidad y unirme'));
      await tester.pumpAndSettle();
      expect(profile.enrollments, 0);
      expect(
        find.text('Pega los datos completos del servidor.'),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const Key('bootstrap')), relay);
      await tester.enterText(find.byKey(const Key('invite')), invitation);
      await tester.ensureVisible(find.text('Crear identidad y unirme'));
      await tester.tap(find.text('Crear identidad y unirme'));
      await tester.pumpAndSettle();
      expect(find.text('Retoma tu alta'), findsOneWidget);
      expect(find.textContaining('PRIVATE_TOKEN_AND_PATH'), findsNothing);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('invite')))
            .controller!
            .text,
        invitation,
      );
      profile.failEnrollment = false;
      await tester.ensureVisible(find.text('Reintentar alta'));
      await tester.tap(find.text('Reintentar alta'));
      await tester.pumpAndSettle();
      expect(home, findsOneWidget);
      expect(find.byKey(const Key('invite')), findsNothing);
      await openSettings(tester);
      await tester.tap(find.text('Cerrar perfil'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Abrir perfil'));
      await tester.tap(find.text('Abrir perfil'));
      await tester.pumpAndSettle();
      expect(home, findsOneWidget);
      expect(profile.enrollments, 2);
    },
  );

  test('an in-flight enrollment cannot be duplicated', () async {
    final profile = FakeProfile()..pending = Completer<void>();
    final session = ProfileSession(opener: () async => profile);
    addTearDown(session.dispose);
    await session.open();
    final first = session.enroll(relay, invitation);
    expect(await session.enroll(relay, invitation), isFalse);
    profile.pending!.complete();
    await first;
    expect(profile.enrollments, 1);
    expect(session.setup!.stage, SetupStage.redeeming);
  });

  test('a failed setup read releases the profile for another open', () async {
    final profile = FakeProfile()..failSetup = true;
    final session = ProfileSession(opener: () async => profile);
    addTearDown(session.dispose);
    expect(await session.open(), isFalse);
    expect(profile.closes, 1);
    expect(session.isOpen, isFalse);
    expect(session.error, isNot(contains('private storage')));
    profile.failSetup = false;
    expect(await session.open(), isTrue);
  });

  test('disposing during open closes the late native handle', () async {
    final opened = Completer<Profile>();
    final profile = FakeProfile();
    final session = ProfileSession(opener: () => opened.future);
    final operation = session.open();
    session.dispose();
    opened.complete(profile);
    await operation;
    expect(profile.closes, 1);
    expect(session.isOpen, isFalse);
  });

  test('platform and profile diagnostics are never presented verbatim', () {
    for (final failure in [
      const ProfileError.io(
        path: '/private-fixture',
        reason: 'PRIVATE_TOKEN_AND_PATH',
      ),
      const ProfileError.unusable(
        path: '/private-fixture',
        reason: 'PRIVATE_TOKEN_AND_PATH',
      ),
      PlatformException(code: 'error', message: 'PRIVATE_TOKEN_AND_PATH'),
    ]) {
      expect(
        describeFailure(failure),
        isNot(contains('PRIVATE_TOKEN_AND_PATH')),
      );
      expect(describeFailure(failure), isNot(contains('/private-fixture')));
    }
  });

  test('a profile from a newer app asks for an update, not for its key', () {
    final message = describeFailure(
      const ProfileError.tooNew(
        path: '/private-fixture',
        found: 2,
        supported: 1,
      ),
    );
    expect(message, contains('Actualiza la app'));
    expect(message, contains('no se ha modificado'));
    expect(message, isNot(contains('clave')));
    expect(message, isNot(contains('/private-fixture')));
  });
}
