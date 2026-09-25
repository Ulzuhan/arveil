import 'dart:convert';

import 'package:arveil/main.dart';
import 'package:arveil/src/appearance.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat_list_test.dart' show chatWith, peer;
import '../contacts_test.dart' show person;
import '../conversation_view_test.dart' show HistoryProfile;
import '../widget_test.dart' show FakeProfile, destination, relay;
import 'support.dart';

// Fixed local times render the same in any time zone, and a date in the
// past keeps "today" out of the pictures.
final day = DateTime(2026, 9, 20);
DateTime at(int hour, int minute) =>
    day.add(Duration(hours: hour, minutes: minute));
int seconds(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

HistoryEventView said(
  String id,
  DateTime time,
  String body, {
  String? author,
  String? identity,
  bool own = false,
  List<String> delivery = const [],
  NoticeView? notice,
}) => HistoryEventView(
  cursor: time.millisecondsSinceEpoch,
  eventId: id,
  kind: notice != null
      ? 'devices-changed'
      : own
      ? 'sent'
      : 'received',
  body: utf8.encode(body),
  delivery: delivery,
  createdAt: seconds(time),
  senderIdentity: own ? null : identity,
  senderLabel: author,
  own: own,
  notice: notice,
);

LastEventView last(
  String preview,
  DateTime time, {
  String? author,
  bool own = false,
  List<String> delivery = const [],
}) => LastEventView(
  cursor: 1,
  kind: own ? 'sent' : 'received',
  preview: preview,
  senderLabel: author,
  own: own,
  createdAt: seconds(time),
  delivery: delivery,
);

/// A small, invented circle of people: nothing here is real.
class ShowcaseProfile extends HistoryProfile {
  ShowcaseProfile()
    : super(
        [
          chatWith(
            'familia',
            [peer('lucia', 'Lucía'), peer('pablo', 'Pablo', verified: false)],
            last: last(
              '¿Quién trae el postre el domingo?',
              at(18, 40),
              author: 'Lucía',
            ),
            unread: 3,
            activity: seconds(at(18, 40)),
          ),
          chatWith(
            'lucia-chat',
            [peer('lucia', 'Lucía')],
            last: last(
              'Llego a las nueve',
              at(17, 55),
              own: true,
              delivery: const ['accepted'],
            ),
            activity: seconds(at(17, 55)),
          ),
          chatWith(
            'pablo-chat',
            [peer('pablo', 'Pablo', verified: false)],
            last: last('Vale, mañana lo miramos', at(12, 10), author: 'Pablo'),
            activity: seconds(at(12, 10)),
          ),
          chatWith(
            'marta-chat',
            [peer('marta', 'Marta Ruiz')],
            last: last(
              'Te paso el plano de la casa',
              at(9, 30),
              author: 'Marta Ruiz',
            ),
            activity: seconds(at(9, 30)),
          ),
        ],
        [
          said(
            '1',
            at(18, 30),
            '¿Quién trae el postre el domingo?',
            author: 'Lucía',
            identity: 'lucia',
          ),
          said(
            '2',
            at(18, 31),
            'Yo puedo hacer tarta de queso',
            author: 'Lucía',
            identity: 'lucia',
          ),
          said(
            '3',
            at(18, 33),
            'Yo llevo las bebidas',
            author: 'Pablo',
            identity: 'pablo',
          ),
          said(
            'n',
            at(18, 35),
            '',
            author: 'Pablo',
            identity: 'pablo',
            notice: const NoticeView(added: 1, removed: 0),
          ),
          said(
            '4',
            at(18, 38),
            '¡Perfecto! Entonces nos vemos a la una',
            own: true,
            delivery: const ['accepted', 'accepted'],
          ),
          said(
            '5',
            at(18, 40),
            '¿Alguien se acuerda de las velas?',
            own: true,
            delivery: const ['sealed'],
          ),
        ],
      ) {
    state = const SetupView(
      stage: SetupStage.ready,
      administrator: true,
      recoveryWarning: false,
      kitStale: false,
      kitSavedAt: 1790000000,
      bootstrap: relay,
    );
  }

  @override
  Future<List<ContactView>> contacts() async => [
    person(id: 'lucia', name: 'Lucía', verified: true),
    person(id: 'marta', name: 'Marta Ruiz', verified: true),
    person(id: 'pablo', name: 'Pablo'),
  ];
}

Future<void> show(
  WidgetTester tester,
  Size size,
  Brightness brightness,
  FakeProfile profile,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  final session = ProfileSession(opener: () async => profile);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    ArveilApp(
      session: session,
      appearance: AppearanceController(MemoryAppearanceStore()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> open(WidgetTester tester) async {
  await tester.tap(find.text('Abrir perfil'));
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> snap(String name) => expectLater(
  find.byType(MaterialApp),
  matchesGoldenFile('screens/$name.png'),
);

void main() {
  setUpAll(() async {
    goldenFileComparator = TolerantComparator(
      Uri.parse('test/goldens/screens_test.dart'),
    );
    await loadFonts();
  });

  const phone = Size(390, 844);
  const desktop = Size(1280, 800);
  for (final (mode, brightness) in [
    ('light', Brightness.light),
    ('dark', Brightness.dark),
  ]) {
    testWidgets('phone welcome and ways in, $mode', (tester) async {
      await show(tester, phone, brightness, FakeProfile());
      await snap('phone_welcome_$mode');
      await open(tester);
      await snap('phone_start_$mode');
    });

    testWidgets('phone chats, conversation, contacts and settings, $mode', (
      tester,
    ) async {
      await show(tester, phone, brightness, ShowcaseProfile());
      await open(tester);
      await snap('phone_chats_$mode');
      await tap(tester, find.byKey(const Key('conversation-familia')));
      await snap('phone_conversation_$mode');
      await tap(tester, find.byTooltip('Volver a conversaciones'));
      await tap(tester, destination('Contactos'));
      await snap('phone_contacts_$mode');
      await tap(tester, destination('Ajustes'));
      await snap('phone_settings_$mode');
    });

    testWidgets('desktop conversation with details and settings, $mode', (
      tester,
    ) async {
      await show(tester, desktop, brightness, ShowcaseProfile());
      await open(tester);
      await tap(tester, find.byKey(const Key('conversation-familia')));
      await tap(tester, find.byTooltip('Detalles de la conversación'));
      await snap('desktop_conversation_$mode');
      await tap(tester, destination('Ajustes'));
      await snap('desktop_settings_$mode');
    });
  }
}
