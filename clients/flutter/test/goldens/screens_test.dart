import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:arveil/l10n/app_localizations.dart';
import 'package:arveil/main.dart';
import 'package:arveil/src/incoming_links.dart';
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

/// Not verified yet: the conversation offers to compare this number.
final pablo = peer(
  'pablo',
  'Pablo',
  verified: false,
  safetyNumber: '40512 83307 19264 55871 02938 67145 38820 91476',
);

/// What the invented people say, in the language of the pictures.
typedef Copy = ({
  String dessert,
  String cheesecake,
  String recipe,
  String drinks,
  String perfect,
  String candles,
  String nine,
  String tomorrow,
  String plan,
});

const copies = <String, Copy>{
  'es': (
    dessert: '¿Quién trae el postre el domingo?',
    cheesecake: 'Yo puedo hacer tarta de queso',
    recipe: 'receta-tarta-de-queso.pdf',
    drinks: 'Yo llevo las bebidas',
    perfect: '¡Perfecto! Entonces nos vemos a la una',
    candles: '¿Alguien se acuerda de las velas?',
    nine: 'Llego a las nueve',
    tomorrow: 'Vale, mañana lo miramos',
    plan: 'Te paso el plano de la casa',
  ),
  'en': (
    dessert: 'Who is bringing dessert on Sunday?',
    cheesecake: 'I can make a cheesecake',
    recipe: 'cheesecake-recipe.pdf',
    drinks: "I'll bring the drinks",
    perfect: 'Perfect! See you at one, then',
    candles: 'Did anyone remember the candles?',
    nine: "I'll be there at nine",
    tomorrow: "OK, let's look at it tomorrow",
    plan: "Here's the floor plan of the house",
  ),
};

/// An invented contact link and its QR code, so the in-person code shows a
/// real pattern. It names no one.
final qr =
    jsonDecode(File('test/fixtures/showcase-qr.json').readAsStringSync())
        as Map<String, Object?>;

/// A small, invented circle of people: nothing here is real.
class ShowcaseProfile extends HistoryProfile {
  ShowcaseProfile(Copy copy)
    : super(
        [
          chatWith(
            'familia',
            [peer('lucia', 'Lucía'), pablo],
            last: last(copy.dessert, at(18, 40), author: 'Lucía'),
            unread: 3,
            activity: seconds(at(18, 40)),
          ),
          chatWith(
            'lucia-chat',
            [peer('lucia', 'Lucía')],
            last: last(
              copy.nine,
              at(17, 55),
              own: true,
              delivery: const ['accepted'],
            ),
            activity: seconds(at(17, 55)),
          ),
          chatWith(
            'pablo-chat',
            [pablo],
            last: last(copy.tomorrow, at(12, 10), author: 'Pablo'),
            activity: seconds(at(12, 10)),
          ),
          chatWith(
            'marta-chat',
            [peer('marta', 'Marta Ruiz')],
            last: last(copy.plan, at(9, 30), author: 'Marta Ruiz'),
            activity: seconds(at(9, 30)),
          ),
        ],
        [
          said(
            '1',
            at(18, 30),
            copy.dessert,
            author: 'Lucía',
            identity: 'lucia',
          ),
          said(
            '2',
            at(18, 31),
            copy.cheesecake,
            author: 'Lucía',
            identity: 'lucia',
          ),
          HistoryEventView(
            cursor: at(18, 32).millisecondsSinceEpoch,
            eventId: 'f',
            kind: 'file-pending',
            body: Uint8List(0),
            delivery: const [],
            createdAt: seconds(at(18, 32)),
            senderIdentity: 'lucia',
            senderLabel: 'Lucía',
            own: false,
            attachment: AttachmentView(
              name: copy.recipe,
              size: BigInt.from(248 * 1024),
              outgoing: false,
              state: AttachmentStateView.ready,
              transferred: BigInt.from(248 * 1024),
              total: BigInt.from(248 * 1024),
            ),
          ),
          said(
            '3',
            at(18, 33),
            copy.drinks,
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
            copy.perfect,
            own: true,
            delivery: const ['accepted', 'accepted'],
          ),
          said(
            '5',
            at(18, 40),
            copy.candles,
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

  @override
  Future<String?> cardName() async => 'Elena';

  @override
  Future<List<CardOfferView>> sharedCards() async => const [];

  @override
  Future<CardOfferView> offerCard({required bool inPerson}) async {
    // The screen counts down from the moment it asked; ten minutes.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return CardOfferView(
      secret: Uint8List.fromList([1]),
      link: qr['text']! as String,
      inPerson: inPerson,
      createdAt: now,
      expiresAt: now + 600,
    );
  }

  @override
  Future<void> closeCard({required List<int> secret}) async {}

  @override
  Future<QrView?> qrCode({required String text}) async => QrView(
    width: qr['width']! as int,
    modules: Uint8List.fromList([
      for (final row in (qr['rows']! as List).cast<String>())
        for (final module in row.codeUnits) module == 0x31 ? 1 : 0,
    ]),
  );

  @override
  Future<CardView> readCard({required String text}) async =>
      const CardView.contact(name: 'Ana');

  @override
  Future<CardPreviewView> previewCard({required String text}) async =>
      const CardPreviewView(
        identityId: 'ana',
        name: 'Ana',
        safetyNumber: '71834 20957 66412 08391 57120 39486 21075 64853',
        verified: false,
      );
}

Future<void> show(
  WidgetTester tester,
  Size size,
  Brightness brightness,
  FakeProfile profile,
  Locale locale,
) async {
  tester.platformDispatcher.localesTestValue = [locale];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  // The clock a system in each language usually shows: 24 hours in Spain,
  // 12 in the United States.
  tester.platformDispatcher.alwaysUse24HourFormatTestValue =
      locale.languageCode != 'en';
  addTearDown(
    () => tester.platformDispatcher.alwaysUse24HourFormatTestValue = true,
  );
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

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    goldenFileComparator = TolerantComparator(
      Uri.parse('test/goldens/screens_test.dart'),
    );
    await loadFonts();
  });

  const phone = Size(390, 844);
  const desktop = Size(1280, 800);
  for (final language in ['es', 'en']) {
    final locale = Locale(language);
    final l10n = lookupAppLocalizations(locale);
    final copy = copies[language]!;
    Future<void> snap(String name) => expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screens/$language/$name.png'),
    );
    Future<void> open(WidgetTester tester) =>
        tap(tester, find.text(l10n.profileOpen));

    for (final (mode, brightness) in [
      ('light', Brightness.light),
      ('dark', Brightness.dark),
    ]) {
      testWidgets('phone welcome and ways in, $language $mode', (tester) async {
        await show(tester, phone, brightness, FakeProfile(), locale);
        await snap('phone_welcome_$mode');
        await open(tester);
        await snap('phone_start_$mode');
      });

      testWidgets('phone about, $language $mode', (tester) async {
        await show(tester, phone, brightness, FakeProfile(), locale);
        await tap(tester, find.byKey(const Key('welcome-about')));
        await snap('phone_about_$mode');
      });

      testWidgets('phone chats, conversation, contacts and settings, '
          '$language $mode', (tester) async {
        await show(tester, phone, brightness, ShowcaseProfile(copy), locale);
        await open(tester);
        await snap('phone_chats_$mode');
        await tap(tester, find.byKey(const Key('conversation-familia')));
        await snap('phone_conversation_$mode');
        await tap(tester, find.byTooltip(l10n.backToConversations));
        await tap(tester, destination(l10n.navContacts));
        await snap('phone_contacts_$mode');
        await tap(tester, destination(l10n.navSettings));
        await snap('phone_settings_$mode');
      });

      testWidgets('phone contact card, its code and a contact link, '
          '$language $mode', (tester) async {
        await show(tester, phone, brightness, ShowcaseProfile(copy), locale);
        await open(tester);
        await tap(tester, destination(l10n.navContacts));
        await tap(tester, find.byKey(const Key('my-card')));
        await snap('phone_card_$mode');
        await tap(tester, find.byKey(const Key('card-show-code')));
        await snap('phone_card_code_$mode');
        await tap(tester, find.byType(BackButton));
        await tap(tester, find.byType(BackButton));
        incomingLinks.receive(qr['text']! as String);
        await tester.pumpAndSettle();
        await snap('phone_card_link_$mode');
        await tap(tester, find.text(l10n.cancel));
      });

      testWidgets('desktop conversation with details and settings, '
          '$language $mode', (tester) async {
        await show(tester, desktop, brightness, ShowcaseProfile(copy), locale);
        await open(tester);
        await tap(tester, find.byKey(const Key('conversation-familia')));
        await tap(tester, find.byTooltip(l10n.conversationDetails));
        await snap('desktop_conversation_$mode');
        await tap(tester, destination(l10n.navSettings));
        await snap('desktop_settings_$mode');
      });
    }
  }
}
