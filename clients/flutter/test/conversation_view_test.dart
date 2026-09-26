import 'dart:convert';

import 'package:arveil/src/conversations_page.dart';
import 'package:arveil/src/design/design.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_list_test.dart' show ListProfile, chatWith, peer;
import 'navigation_test.dart' show desktop, openHome, phone;

final now = DateTime.now();
int seconds(DateTime at) => at.millisecondsSinceEpoch ~/ 1000;

HistoryEventView message(
  String id,
  DateTime at, {
  bool own = false,
  String? author,
  List<String> delivery = const [],
  NoticeView? notice,
  String? text,
}) => HistoryEventView(
  cursor: at.millisecondsSinceEpoch,
  eventId: id,
  kind: notice != null
      ? 'devices-changed'
      : own
      ? 'sent'
      : 'received',
  body: notice != null ? Uint8List(0) : utf8.encode(text ?? 'text $id'),
  delivery: delivery,
  createdAt: seconds(at),
  senderIdentity: own ? null : author,
  senderLabel: author,
  own: own,
  notice: notice,
);

List<String> shape(List<HistoryItem> items) => [
  for (final item in items)
    switch (item) {
      DayItem() => 'day',
      EventItem(:final event, :final position) =>
        '${event.eventId}:${position.name}',
    },
];

class HistoryProfile extends ListProfile {
  HistoryProfile(super.rows, this.events);
  final List<HistoryEventView> events;
  @override
  Future<HistoryPageView> historyPage({
    required String groupId,
    int? before,
    required int limit,
  }) async => HistoryPageView(events: events, next: null);
}

final group = chatWith('g', [peer('lucia', 'Lucía'), peer('pablo', 'Pablo')]);

Future<void> openChat(
  WidgetTester tester,
  Size size,
  List<HistoryEventView> history,
) async {
  await openHome(tester, size, profile: HistoryProfile([group], history));
  await tester.tap(find.byKey(const Key('conversation-g')));
  await tester.pumpAndSettle();
}

void main() {
  test('runs join one author a few minutes apart; days and notices split', () {
    final day = DateTime(2026, 9, 24, 10);
    final items = historyItems([
      message('a1', day, author: 'lucia'),
      message('a2', day.add(const Duration(minutes: 2)), author: 'lucia'),
      message('a3', day.add(const Duration(minutes: 4)), author: 'lucia'),
      message('b1', day.add(const Duration(minutes: 5)), author: 'pablo'),
      message(
        'n',
        day.add(const Duration(minutes: 6)),
        author: 'pablo',
        notice: const NoticeView(added: 1, removed: 0),
      ),
      message('b2', day.add(const Duration(minutes: 7)), author: 'pablo'),
      message('b3', day.add(const Duration(hours: 1)), author: 'pablo'),
      message('m1', day.add(const Duration(days: 1)), own: true),
    ]);
    expect(shape(items), [
      'day',
      'a1:first',
      'a2:middle',
      'a3:last',
      'b1:single',
      'n:single',
      'b2:single',
      'b3:single',
      'day',
      'm1:single',
    ]);
  });

  test('day separators say today, yesterday or the date', () {
    final today = DateTime(2026, 9, 25, 9);
    expect(dayLabel(DateTime(2026, 9, 25), now: today), 'Hoy');
    expect(dayLabel(DateTime(2026, 9, 24), now: today), 'Ayer');
    expect(dayLabel(DateTime(2026, 9, 2), now: today), '2/9/2026');
  });

  testWidgets('a group names authors on the first bubble of each run', (
    tester,
  ) async {
    await openChat(tester, phone, [
      message('a1', now, author: 'Lucía'),
      message('a2', now, author: 'Lucía'),
      message('b1', now, author: 'Pablo'),
    ]);
    expect(find.text('Hoy'), findsOneWidget);
    Finder inBubble(String id, String text) => find.descendant(
      of: find.byKey(Key('message-$id')),
      matching: find.text(text),
    );
    expect(inBubble('a1', 'Lucía'), findsOneWidget);
    expect(inBubble('a2', 'Lucía'), findsNothing);
    expect(inBubble('b1', 'Pablo'), findsOneWidget);
    // The header names the group and how many people it has.
    expect(find.text('2 personas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a right click shows delivery per mailbox and copies the text', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await openChat(tester, desktop, [
      message(
        'mine',
        now,
        own: true,
        delivery: const ['accepted', 'undeliverable (mailbox refused)'],
      ),
    ]);
    await tester.tap(find.text('text mine'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Buzón 1'), findsOneWidget);
    expect(
      find.text('Aceptado por el servidor · lectura sin confirmar'),
      findsOneWidget,
    );
    expect(find.text('El buzón rechazó el mensaje'), findsOneWidget);
    await tester.tap(find.text('Copiar texto'));
    await tester.pumpAndSettle();
    expect(copied, 'text mine');
    expect(find.text('Texto copiado'), findsOneWidget);
  });

  testWidgets('from 1200 dp the details stay open beside the conversation', (
    tester,
  ) async {
    await openChat(tester, desktop, [message('a1', now, author: 'Lucía')]);
    final details = find.byKey(const Key('conversation-details'));
    expect(details, findsNothing);
    await tester.tap(find.byTooltip('Detalles de la conversación'));
    await tester.pumpAndSettle();
    expect(details, findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const Key('message-draft')), findsOneWidget);
    await tester.tap(find.byTooltip('Detalles de la conversación'));
    await tester.pumpAndSettle();
    expect(details, findsNothing);
  });

  testWidgets('below 1200 dp the details open in a dialog', (tester) async {
    await openChat(tester, const Size(1000, 800), [
      message('a1', now, author: 'Lucía'),
    ]);
    await tester.tap(find.byTooltip('Detalles de la conversación'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byKey(const Key('conversation-details')),
      ),
      findsOneWidget,
    );
    expect(find.text('Lucía'), findsWidgets);
  });

  testWidgets('an open conversation on a phone says when it is offline', (
    tester,
  ) async {
    final profile = HistoryProfile([group], [message('a1', now)])
      ..offline = true;
    await openHome(tester, phone, profile: profile);
    await tester.tap(find.byKey(const Key('conversation-g')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conversation-offline')), findsOneWidget);
    expect(find.text('Sin conexión'), findsOneWidget);
    expect(find.byType(Composer), findsOneWidget);
  });

  testWidgets('an empty conversation invites the first message', (
    tester,
  ) async {
    await openChat(tester, phone, const []);
    expect(find.text('Escribe el primer mensaje.'), findsOneWidget);
    expect(find.byType(EmptyState), findsOneWidget);
  });
}
