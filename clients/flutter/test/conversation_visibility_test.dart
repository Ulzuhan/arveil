import 'dart:async';

import 'package:arveil/src/conversations_page.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'conversation_view_test.dart' show message;
import 'navigation_test.dart' show HomeProfile, desktop, openHome;
import 'widget_test.dart' show destination;

final at = DateTime(2026, 9, 26, 12);

Future<HomeProfile> openChat(WidgetTester tester) async {
  final profile = HomeProfile()
    ..messages = [message('first', at, text: 'already visible')];
  await openHome(tester, desktop, profile: profile);
  await tester.tap(find.byKey(const Key('conversation-group-a')));
  await tester.pumpAndSettle();
  expect(profile.marks, hasLength(1));
  return profile;
}

HistoryEventView incoming() => message(
  'unseen',
  at.add(const Duration(seconds: 1)),
  text: 'arrived while the history was hidden',
);

void main() {
  for (final label in ['Ajustes', 'Contactos']) {
    testWidgets('sync keeps messages unread behind $label until chats return', (
      tester,
    ) async {
      final profile = await openChat(tester);
      final lastVisibleCursor = profile.marks.last.$2;
      await tester.tap(destination(label));
      await tester.pumpAndSettle();
      final syncs = profile.syncs;
      final next = incoming();
      profile.messages.add(next);
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(profile.syncs, greaterThan(syncs));
      expect(find.text('arrived while the history was hidden'), findsNothing);
      expect(profile.marks.last.$2, lastVisibleCursor);

      await tester.tap(destination('Chats'));
      await tester.pumpAndSettle();
      expect(find.text('arrived while the history was hidden'), findsOneWidget);
      expect(profile.marks.last.$2, next.cursor);
    });
  }

  testWidgets('search does not mark the hidden history read', (tester) async {
    final profile = await openChat(tester);
    final lastVisibleCursor = profile.marks.last.$2;
    await tester.tap(find.byKey(const Key('open-conversation-search')));
    await tester.pumpAndSettle();
    final next = incoming();
    profile.messages.add(next);
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(profile.marks.last.$2, lastVisibleCursor);
    await tester.tap(find.byTooltip('Cerrar la búsqueda'));
    await tester.pumpAndSettle();
    expect(profile.marks.last.$2, next.cursor);
  });

  testWidgets('a covering route defers reading until the history returns', (
    tester,
  ) async {
    final profile = await openChat(tester);
    final lastVisibleCursor = profile.marks.last.$2;
    final context = tester.element(find.byType(ConversationsPage));
    final navigator = Navigator.of(context);
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('another screen')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final next = incoming();
    profile.messages.add(next);
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(profile.marks.last.$2, lastVisibleCursor);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(profile.marks.last.$2, next.cursor);
  });

  testWidgets('a history request completed after navigation stays unread', (
    tester,
  ) async {
    final profile = await openChat(tester);
    final lastVisibleCursor = profile.marks.last.$2;
    final controller = tester
        .widget<ConversationsPage>(find.byType(ConversationsPage))
        .controller;
    profile.history = Completer<HistoryPageView>();
    final refresh = controller.refresh();
    await tester.pump();
    await tester.tap(destination('Ajustes'));
    await tester.pumpAndSettle();
    final next = incoming();
    profile.history!.complete(HistoryPageView(events: [next], next: null));
    await refresh;
    await tester.pumpAndSettle();
    expect(profile.marks.last.$2, lastVisibleCursor);
    await tester.tap(destination('Chats'));
    await tester.pumpAndSettle();
    expect(profile.marks.last.$2, next.cursor);
  });

  testWidgets('background history refresh stays unread until resume', (
    tester,
  ) async {
    final profile = await openChat(tester);
    final lastVisibleCursor = profile.marks.last.$2;
    final controller = tester
        .widget<ConversationsPage>(find.byType(ConversationsPage))
        .controller;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final next = incoming();
    profile.messages.add(next);
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(profile.marks.last.$2, lastVisibleCursor);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(profile.marks.last.$2, next.cursor);
  });
}
