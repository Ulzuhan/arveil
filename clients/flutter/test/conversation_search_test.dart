import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_list_test.dart' show chatWith, peer;
import 'conversation_view_test.dart' show HistoryProfile, message;
import 'navigation_test.dart' show chord, desktop, openHome, phone;

final now = DateTime.now();
final history = [
  message('a', now, author: 'Lucía'),
  message('b', now, own: true, delivery: const ['accepted']),
];

/// A conversation whose messages talk about dessert, once with an accent.
class SearchProfile extends HistoryProfile {
  SearchProfile()
    : super([
        chatWith('g', [peer('lucia', 'Lucía')]),
      ], history) {
    messages = [
      message('1', now, author: 'Lucía', text: '¿Quién trae el póstre?'),
      message(
        '2',
        now,
        own: true,
        text: 'Yo llevo tarta',
        delivery: const ['accepted'],
      ),
      message('3', now, author: 'Lucía', text: 'El postre, genial'),
    ];
  }
}

/// A search that stops before the start and continues when asked.
class PagedSearchProfile extends SearchProfile {
  @override
  Future<HistoryPageView> searchHistory({
    required String groupId,
    required String text,
    int? before,
    required int limit,
  }) async {
    searches.add(text);
    return before == null
        ? const HistoryPageView(events: [], next: 99)
        : HistoryPageView(events: [messages.first], next: null);
  }
}

Finder get field => find.byKey(const Key('conversation-search'));

Future<SearchProfile> openSearch(
  WidgetTester tester,
  Size size, [
  SearchProfile? profile,
]) async {
  final opened = profile ?? SearchProfile();
  await openHome(tester, size, profile: opened);
  await tester.tap(find.byKey(const Key('conversation-g')));
  await tester.pumpAndSettle();
  return opened;
}

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(field, text);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a search lists matching messages and says when none match', (
    tester,
  ) async {
    final profile = await openSearch(tester, phone);
    await tester.tap(find.byKey(const Key('open-conversation-search')));
    await tester.pumpAndSettle();
    expect(field, findsOneWidget);
    expect(find.byKey(const Key('message-draft')), findsNothing);

    await type(tester, 'postre');
    expect(profile.searches, ['postre']);
    expect(find.byKey(const Key('search-result-1')), findsOneWidget);
    expect(find.byKey(const Key('search-result-3')), findsOneWidget);
    expect(find.byKey(const Key('search-result-2')), findsNothing);

    await type(tester, 'helado');
    expect(find.text('Ningún mensaje contiene «helado»'), findsOneWidget);

    await tester.tap(find.byTooltip('Cerrar la búsqueda'));
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    expect(find.byKey(const Key('message-draft')), findsOneWidget);
  });

  testWidgets('a search that stopped offers to keep looking further back', (
    tester,
  ) async {
    await openSearch(tester, phone, PagedSearchProfile());
    await tester.tap(find.byKey(const Key('open-conversation-search')));
    await tester.pumpAndSettle();
    await type(tester, 'postre');
    expect(find.text('Nada entre los mensajes más recientes.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-older')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-result-1')), findsOneWidget);
    expect(find.byKey(const Key('search-older')), findsNothing);
  });

  testWidgets('on a phone, back leaves the search before the conversation', (
    tester,
  ) async {
    await openSearch(tester, phone);
    await tester.tap(find.byKey(const Key('open-conversation-search')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    expect(find.byKey(const Key('message-draft')), findsOneWidget);
  });

  testWidgets(
    'the find shortcut opens the search and Escape closes it',
    (tester) async {
      await openSearch(tester, desktop);
      final primary = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.meta
          : LogicalKeyboardKey.control;
      await chord(tester, primary, LogicalKeyboardKey.keyF);
      expect(field, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(field, findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
  );
}
