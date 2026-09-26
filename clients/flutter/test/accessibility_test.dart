import 'package:arveil/l10n/l10n.dart';
import 'package:arveil/main.dart';
import 'package:arveil/src/appearance_page.dart';
import 'package:arveil/src/contacts_page.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_list_test.dart' show chatWith, peer, text;
import 'contacts_test.dart' show person;
import 'conversation_view_test.dart' show HistoryProfile, message;
import 'navigation_test.dart' show phone;
import 'onboarding_test.dart' show AdminProfile;
import 'settings_test.dart' show SettingsProfile;
import 'widget_test.dart' show FakeProfile, destination, invitation, relay;

final at = DateTime.now().copyWith(hour: 18, minute: 40);

class RichProfile extends HistoryProfile {
  RichProfile()
    : super(
        [
          chatWith(
            'g',
            [peer('lucia', 'Lucía Fernández de la Vega')],
            last: text('Un mensaje largo para una sola línea de la lista'),
            unread: 12,
            activity: at.millisecondsSinceEpoch ~/ 1000,
          ),
        ],
        [
          message('a', at, author: 'Lucía Fernández de la Vega'),
          message('b', at, own: true, delivery: const ['accepted']),
        ],
      );

  @override
  Future<List<ContactView>> contacts() async => [
    person(verified: true),
    person(id: 'b', name: 'Bruno Díaz del Castillo'),
  ];
}

Future<void> openRich(WidgetTester tester, {FakeProfile? profile}) async {
  tester.view.physicalSize = phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final opened = profile ?? RichProfile();
  final session = ProfileSession(opener: () async => opened);
  addTearDown(session.dispose);
  await tester.pumpWidget(ArveilApp(session: session));
  await settle(tester, find.text('Abrir perfil'));
}

/// Scrolls [finder] into view, building it first if a lazy list has not.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      150,
      scrollable: find.byType(Scrollable).hitTestable().first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> settle(WidgetTester tester, Finder finder) async {
  await reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> back(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a message reads as who, when and what, with its state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openRich(tester);
    await tester.tap(find.byKey(const Key('conversation-g')));
    await tester.pumpAndSettle();
    final time = clockTime(at);
    expect(
      find.bySemanticsLabel('Lucía Fernández de la Vega, $time: text a'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Tú, $time: text b. Aceptado por el servidor'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('a settings heading and each row are stops of their own', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openRich(tester);
    await settle(tester, destination('Ajustes'));
    // A group whose only tappable row folded the heading into it read as
    // one pressable heading: «Conexión, Claves para grupos nuevos…».
    for (final (heading, row) in [
      ('Tu identidad', 'share-route'),
      ('Conexión', 'open-keys'),
    ]) {
      await reveal(tester, find.byKey(Key(row)));
      expect(
        tester.getSemantics(find.text(heading)),
        isSemantics(label: heading, isHeader: true, hasTapAction: false),
      );
      final node = tester.getSemantics(find.byKey(Key(row)));
      expect(
        node,
        isSemantics(isButton: true, hasTapAction: true, isHeader: false),
      );
      expect(node.label, isNot(contains(heading)));
      if (row == 'share-route') {
        // The row above it says what this device is and does nothing.
        final identity = tester.getSemantics(
          find.text('Este dispositivo administra tus dispositivos'),
        );
        expect(identity, isSemantics(hasTapAction: false));
        expect(identity.label, isNot(contains(heading)));
        expect(node.label, isNot(contains('administra')));
      }
    }
    semantics.dispose();
  });

  testWidgets('the text size slider says what it sizes, and the size once', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openRich(tester);
    await settle(tester, destination('Ajustes'));
    final appearance = find.byKey(const Key('open-appearance'));
    await tester.scrollUntilVisible(appearance, 100);
    await settle(tester, appearance);
    await reveal(tester, find.byKey(const Key('text-size')));
    expect(
      tester.getSemantics(find.byKey(const Key('text-size'))),
      isSemantics(
        label: 'Tamaño del texto',
        value: '100 %',
        increasedValue: '110 %',
        isSlider: true,
      ),
    );
    expect(find.text('100 %'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('reduced motion shows a new screen without moving it', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await openRich(tester, profile: SettingsProfile());
    await tester.tap(destination('Ajustes'));
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('open-appearance'));
    await tester.scrollUntilVisible(row, 100);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.getTopLeft(find.byType(AppearancePage)), Offset.zero);
    expect(tester.getSize(find.byType(AppearancePage)), phone);
  });

  testWidgets('without reduced motion the same screen does move in', (
    tester,
  ) async {
    await openRich(tester, profile: SettingsProfile());
    await tester.tap(destination('Ajustes'));
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('open-appearance'));
    await tester.scrollUntilVisible(row, 100);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final rect = tester.getRect(find.byType(AppearancePage));
    expect(rect, isNot(Offset.zero & phone));
    await tester.pumpAndSettle();
  });

  group('at 200 % text a phone shows every main screen without overflow', () {
    testWidgets('welcome, ways in, invitation and kit offer', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await openRich(tester, profile: AdminProfile());
      expect(tester.takeException(), isNull);
      await settle(tester, find.text('Unirme con una invitación'));
      await tester.enterText(find.byKey(const Key('bootstrap')), relay);
      await settle(tester, find.byKey(const Key('enroll-next')));
      await tester.enterText(find.byKey(const Key('invite')), invitation);
      await settle(tester, find.text('Crear identidad y unirme'));
      await reveal(tester, find.byKey(const Key('kit-offer-risk')));
      expect(find.byKey(const Key('kit-offer-risk')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('chats, conversation, details, contacts and settings', (
      tester,
    ) async {
      await openRich(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'chat list');
      await settle(tester, find.byKey(const Key('conversation-g')));
      expect(tester.takeException(), isNull, reason: 'conversation');
      await settle(tester, find.byTooltip('Detalles de la conversación'));
      expect(tester.takeException(), isNull, reason: 'details');
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await settle(tester, find.byTooltip('Volver a conversaciones'));
      await settle(tester, destination('Contactos'));
      expect(tester.takeException(), isNull, reason: 'contacts');
      await settle(tester, find.byKey(const Key('contact-b')));
      expect(find.byType(ContactEditorPage), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'contact details');
      await back(tester);
      await settle(tester, destination('Ajustes'));
      expect(tester.takeException(), isNull, reason: 'settings');
      final appearance = find.byKey(const Key('open-appearance'));
      await tester.scrollUntilVisible(appearance, 100);
      await settle(tester, appearance);
      expect(tester.takeException(), isNull, reason: 'appearance');
    });
  });

  testWidgets('main phone screens meet the tap target and label guidelines', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openRich(tester);
    Future<void> check(String screen) async {
      await expectLater(
        tester,
        meetsGuideline(androidTapTargetGuideline),
        reason: screen,
      );
      await expectLater(
        tester,
        meetsGuideline(labeledTapTargetGuideline),
        reason: screen,
      );
    }

    await check('chat list');
    await settle(tester, find.byKey(const Key('conversation-g')));
    await check('conversation');
    await settle(tester, find.byTooltip('Volver a conversaciones'));
    await settle(tester, destination('Contactos'));
    await check('contacts');
    await settle(tester, destination('Ajustes'));
    await check('settings');
    final appearance = find.byKey(const Key('open-appearance'));
    await tester.scrollUntilVisible(appearance, 100);
    await settle(tester, appearance);
    await check('appearance');
    semantics.dispose();
  });
}
