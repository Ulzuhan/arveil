import 'package:arveil/main.dart';
import 'package:arveil/src/conversations_page.dart';
import 'package:arveil/src/design/design.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'conversations_test.dart' show ChatProfile, row;
import 'widget_test.dart' show destination, relay;

const second = ConversationView(
  groupId: 'group-b',
  creator: true,
  peerDevices: 1,
  peers: [],
  eventCount: 1,
  unread: 0,
  lastActivity: 0,
);

class HomeProfile extends ChatProfile {
  HomeProfile() {
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
  Future<List<ConversationView>> conversations() async => [row, second];
  @override
  Future<List<ContactView>> contacts() async => [];
}

/// Opens a ready profile in a window of [size] logical pixels.
Future<HomeProfile> openHome(
  WidgetTester tester,
  Size size, {
  HomeProfile? profile,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  profile ??= HomeProfile();
  final opened = profile;
  final session = ProfileSession(opener: () async => opened);
  addTearDown(session.dispose);
  await tester.pumpWidget(ArveilApp(session: session));
  await tester.tap(find.text('Abrir perfil'));
  await tester.pumpAndSettle();
  return profile;
}

String? selected(WidgetTester tester) => tester
    .widget<ConversationsPage>(find.byType(ConversationsPage))
    .controller
    .selected;

const phone = Size(390, 844);
const desktop = Size(1280, 800);
final rail = find.byType(NavigationRail);
final bar = find.byType(NavigationBar);
final draft = find.byKey(const Key('message-draft'));

/// ⌘ on Apple systems, Ctrl elsewhere.
LogicalKeyboardKey get primary => defaultTargetPlatform == TargetPlatform.macOS
    ? LogicalKeyboardKey.meta
    : LogicalKeyboardKey.control;

Future<void> chord(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a phone navigates with a bottom bar the conversation hides', (
    tester,
  ) async {
    await openHome(tester, phone);
    expect(bar, findsOneWidget);
    expect(rail, findsNothing);
    for (final label in ['Chats', 'Contactos', 'Ajustes']) {
      expect(destination(label), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('conversation-group-a')));
    await tester.pumpAndSettle();
    expect(draft, findsOneWidget);
    expect(bar, findsNothing, reason: 'a conversation takes the screen');

    // The system back gesture closes the conversation first.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(selected(tester), isNull);
    expect(bar, findsOneWidget);

    await tester.tap(destination('Contactos'));
    await tester.pumpAndSettle();
    expect(find.text('Todavía no tienes contactos guardados.'), findsOneWidget);
    // From another destination, back returns to the chats.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conversation-group-a')), findsOneWidget);

    await tester.tap(destination('Ajustes'));
    await tester.pumpAndSettle();
    expect(find.text('Seguridad y recuperación'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a desktop window shows a rail beside the list and the chat', (
    tester,
  ) async {
    await openHome(tester, desktop);
    expect(rail, findsOneWidget);
    expect(bar, findsNothing);
    expect(find.text('Elige una conversación para leerla.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('conversation-group-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conversation-group-b')), findsOneWidget);
    expect(draft, findsOneWidget);
    expect(rail, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('crossing a size class keeps the open chat and its draft', (
    tester,
  ) async {
    await openHome(tester, desktop);
    await tester.tap(find.byKey(const Key('conversation-group-a')));
    await tester.pumpAndSettle();
    await tester.enterText(draft, 'half written');
    tester.view.physicalSize = phone;
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    expect(selected(tester), 'group-a');
    expect(find.text('half written'), findsOneWidget);
    tester.view.physicalSize = desktop;
    await tester.pumpAndSettle();
    expect(rail, findsOneWidget);
    expect(find.text('half written'), findsOneWidget);
  });

  testWidgets(
    'desktop shortcuts open chats, a new chat and settings, and Esc closes',
    (tester) async {
      await openHome(tester, desktop);
      await chord(tester, LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowDown);
      expect(selected(tester), 'group-a');
      await chord(tester, LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowDown);
      expect(selected(tester), 'group-b');
      await chord(tester, LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowUp);
      expect(selected(tester), 'group-a');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(selected(tester), isNull);

      await chord(tester, primary, LogicalKeyboardKey.comma);
      expect(find.text('Cerrar perfil'), findsOneWidget);

      // From settings, a new chat brings the chats back first.
      await chord(tester, primary, LogicalKeyboardKey.keyN);
      expect(find.byType(NewConversationPage), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byType(NewConversationPage),
        findsOneWidget,
        reason: 'Esc does not throw away a form',
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('conversation-group-a')), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'Enter sends on desktop and Shift+Enter does not',
    (tester) async {
      final profile = await openHome(tester, desktop);
      await tester.tap(find.byKey(const Key('conversation-group-a')));
      await tester.pumpAndSettle();
      await tester.enterText(draft, 'hello');
      await chord(tester, LogicalKeyboardKey.shift, LogicalKeyboardKey.enter);
      expect(profile.sends, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(profile.sends, 1);
      expect(tester.widget<TextField>(draft).controller!.text, isEmpty);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Enter starts a new line on a phone instead of sending',
    (tester) async {
      final profile = await openHome(tester, phone);
      await tester.tap(find.byKey(const Key('conversation-group-a')));
      await tester.pumpAndSettle();
      await tester.enterText(draft, 'hello');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(profile.sends, 0);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('Tab moves from the rail to the list and then the composer', (
    tester,
  ) async {
    await openHome(tester, desktop);
    await tester.tap(find.byKey(const Key('conversation-group-a')));
    await tester.pumpAndSettle();
    // Start from the shell, as after opening the profile.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    String? region() {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      if (context.findAncestorWidgetOfExactType<NavigationRail>() != null) {
        return 'rail';
      }
      final tile = context.findAncestorWidgetOfExactType<ConversationTile>();
      if (tile?.key case ValueKey<String>(
        :final value,
      ) when value.startsWith('conversation-')) {
        return 'list';
      }
      if (context.findAncestorWidgetOfExactType<TextField>()?.key ==
          const Key('message-draft')) {
        return 'composer';
      }
      if (context.widget.key == const Key('send-message') ||
          context.findAncestorWidgetOfExactType<IconButton>()?.key ==
              const Key('send-message')) {
        return 'send';
      }
      return 'other';
    }

    final order = <String>[];
    for (var i = 0; i < 40 && !order.contains('send'); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final here = region();
      if (here != null && (order.isEmpty || order.last != here)) {
        order.add(here);
      }
    }
    final firsts = [
      for (final r in ['rail', 'list', 'composer', 'send']) order.indexOf(r),
    ];
    expect(firsts, everyElement(greaterThanOrEqualTo(0)), reason: '$order');
    expect(firsts, orderedEquals([...firsts]..sort()), reason: '$order');
  });
}
