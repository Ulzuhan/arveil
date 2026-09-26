import 'package:arveil/src/conversations_page.dart';
import 'package:arveil/src/design/design.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'navigation_test.dart' show HomeProfile, chord, desktop, openHome, phone;

PeerView peer(
  String id,
  String label, {
  bool verified = true,
  bool named = true,
}) => PeerView(
  identityId: id,
  deviceId: 'device-$id',
  label: label,
  named: named,
  own: false,
  verified: verified,
  revoked: false,
);

LastEventView text(String body, {bool own = false, List<String>? delivery}) =>
    LastEventView(
      cursor: 1,
      kind: own ? 'sent' : 'received',
      preview: body,
      own: own,
      createdAt: 1790000000,
      delivery: delivery ?? const [],
    );

ConversationView chatWith(
  String id,
  List<PeerView> peers, {
  LastEventView? last,
  int unread = 0,
  int activity = 0,
}) => ConversationView(
  groupId: id,
  creator: true,
  peerDevices: peers.length,
  peers: peers,
  eventCount: last == null ? 0 : 1,
  lastEvent: last,
  unread: unread,
  lastActivity: activity,
);

class ListProfile extends HomeProfile {
  ListProfile(this.rows);
  final List<ConversationView> rows;
  @override
  Future<List<ConversationView>> conversations() async => rows;
}

Future<void> openList(
  WidgetTester tester,
  List<ConversationView> rows, {
  Size size = phone,
}) async {
  await openHome(tester, size, profile: ListProfile(rows));
}

Finder row(String id) => find.byKey(Key('conversation-$id'));
Finder inRow(String id, Finder finder) =>
    find.descendant(of: row(id), matching: finder);

void main() {
  test('list times say the hour today, yesterday, or the date', () {
    int at(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;
    final now = DateTime(2026, 9, 25, 9);
    expect(listTime(at(DateTime(2026, 9, 25, 8, 5)), now: now), '08:05');
    expect(listTime(at(DateTime(2026, 9, 24, 23, 59)), now: now), 'Ayer');
    expect(listTime(at(DateTime(2026, 9, 20, 12)), now: now), '20/9/2026');
  });

  test('search ignores case and accents and looks at every person', () {
    final group = chatWith('g', [peer('a', 'Lucía'), peer('b', 'Pablo')]);
    expect(matchesSearch(group, 'lucia'), isTrue);
    expect(matchesSearch(group, 'PABLO'), isTrue);
    expect(matchesSearch(group, 'mamá'), isFalse);
    expect(matchesSearch(group, '  '), isTrue);
  });

  testWidgets('rows show avatar, verification, delivery and unread', (
    tester,
  ) async {
    await openList(tester, [
      chatWith(
        'verified',
        [peer('lucia', 'Lucía')],
        last: text('Llego a las nueve', own: true, delivery: ['accepted']),
        activity: 1790000000,
      ),
      chatWith(
        'unverified',
        [peer('pablo', 'Pablo', verified: false)],
        last: text('¿Vienes?'),
        unread: 2,
      ),
    ]);
    expect(inRow('verified', find.byType(VerifiedMark)), findsOneWidget);
    expect(inRow('verified', find.byType(UnverifiedChip)), findsNothing);
    expect(inRow('unverified', find.byType(UnverifiedChip)), findsOneWidget);
    expect(
      tester.widget<ArveilAvatar>(inRow('verified', find.byType(ArveilAvatar))),
      isA<ArveilAvatar>().having((a) => a.identity, 'identity', 'lucia'),
    );
    expect(
      tester.widget<DeliveryIcon>(inRow('verified', find.byType(DeliveryIcon))),
      isA<DeliveryIcon>().having(
        (d) => d.status,
        'status',
        DeliveryStatus.accepted,
      ),
    );
    expect(inRow('unverified', find.byType(DeliveryIcon)), findsNothing);
    expect(inRow('unverified', find.byType(UnreadBadge)), findsOneWidget);
    expect(inRow('verified', find.text('Tú: Llego a las nueve')), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search filters by name, says when nothing matches, and clears', (
    tester,
  ) async {
    await openList(tester, [
      chatWith('a', [peer('lucia', 'Lucía')]),
      chatWith('b', [peer('pablo', 'Pablo')]),
    ]);
    final search = find.byKey(const Key('chat-search'));
    await tester.enterText(search, 'lucia');
    await tester.pumpAndSettle();
    expect(row('a'), findsOneWidget);
    expect(row('b'), findsNothing);

    await tester.enterText(search, 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Ningún chat coincide con «zzz»'), findsOneWidget);

    await tester.tap(find.byTooltip('Borrar la búsqueda'));
    await tester.pumpAndSettle();
    expect(row('a'), findsOneWidget);
    expect(row('b'), findsOneWidget);
  });

  testWidgets(
    'the search shortcut puts the cursor in the search, and Esc clears it',
    (tester) async {
      await openList(tester, [
        chatWith('a', [peer('lucia', 'Lucía')]),
        chatWith('b', [peer('pablo', 'Pablo')]),
      ], size: desktop);
      final primary = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.meta
          : LogicalKeyboardKey.control;
      await chord(tester, primary, LogicalKeyboardKey.keyK);
      final field = tester.widget<TextField>(
        find.byKey(const Key('chat-search')),
      );
      expect(field.focusNode!.hasFocus, isTrue);
      await tester.enterText(find.byKey(const Key('chat-search')), 'pab');
      await tester.pumpAndSettle();
      expect(row('a'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(row('a'), findsOneWidget);
      expect(field.focusNode!.hasFocus, isFalse);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets('an empty list says what to do and offers it', (tester) async {
    await openList(tester, const []);
    expect(find.text('Todavía no hay conversaciones guardadas.'), findsOne);
    expect(find.byKey(const Key('chat-search')), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Nueva conversación'));
    await tester.pumpAndSettle();
    expect(find.byType(NewConversationPage), findsOneWidget);
  });

  testWidgets('the kit reminder heads the list until it is put off', (
    tester,
  ) async {
    final profile = ListProfile([
      chatWith('a', [peer('lucia', 'Lucía')]),
    ]);
    profile.state = const SetupView(
      stage: SetupStage.ready,
      administrator: true,
      recoveryWarning: false,
      kitStale: false,
      bootstrap: 'arveil-bootstrap:v0:fixture',
    );
    await openHome(tester, phone, profile: profile);
    expect(find.text('Guarda tu kit de identidad'), findsOneWidget);
    await tester.tap(find.text('Más tarde'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('kit-reminder')), findsNothing);
    expect(row('a'), findsOneWidget);
  });

  testWidgets('a phone shows the list at 200 % text without overflow', (
    tester,
  ) async {
    await openList(tester, [
      chatWith(
        'a',
        [peer('lucia', 'Lucía Fernández de la Vega')],
        last: text('Un mensaje bastante largo para una sola línea'),
        unread: 120,
        activity: 1790000000,
      ),
    ]);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(row('a'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
