import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'package:arveil/main.dart';
import 'package:arveil/src/conversation_controller.dart';
import 'package:arveil/src/conversations_page.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' show FakeProfile, relay;

HistoryEventView event(int n, {String? text}) => HistoryEventView(
  cursor: n,
  eventId: 'event-$n',
  kind: 'sent',
  body: utf8.encode(text ?? 'message $n'),
  delivery: const ['queued'],
  createdAt: 1790000000 + n,
  own: true,
);
const row = ConversationView(
  groupId: 'group-a',
  creator: true,
  peerDevices: 1,
  peers: [],
  eventCount: 1,
  unread: 0,
  lastActivity: 0,
);

class ChatProfile extends FakeProfile {
  List<HistoryEventView> messages = [event(1)];
  Completer<SyncView>? network;
  Completer<ChatMutationView>? save;
  Completer<HistoryPageView>? history;
  Completer<List<ConversationView>>? initialRows;
  bool offline = false, failSave = false, partialCreate = false;
  int sends = 0, syncs = 0, creates = 0;
  @override
  Future<List<ConversationView>> conversations() async =>
      initialRows == null ? [row] : await initialRows!.future;
  final List<(String, int)> marks = [];
  @override
  Future<ReadMarkerView> markRead({
    required String groupId,
    required int cursor,
  }) async {
    marks.add((groupId, cursor));
    return ReadMarkerView(cursor: cursor, unread: 0);
  }

  @override
  Future<HistoryPageView> historyPage({
    required String groupId,
    int? before,
    required int limit,
  }) async {
    if (history != null && groupId == 'group-a') return history!.future;
    final all = messages
        .where((e) => before == null || e.cursor < before)
        .toList();
    final page = all.length > limit ? all.sublist(all.length - limit) : all;
    return HistoryPageView(
      events: page,
      next: all.length > page.length ? page.first.cursor : null,
    );
  }

  @override
  Future<SyncView> sync_({required String bootstrap}) async {
    syncs++;
    if (network != null) return network!.future;
    if (offline) {
      throw const CommandError.transport(
        operation: 'sync',
        reason: 'PRIVATE_DIAGNOSTIC',
      );
    }
    return const SyncView(processedEnvelopes: 0);
  }

  @override
  Future<ChatMutationView> queueMessage({
    required String groupId,
    required String text,
  }) async {
    sends++;
    if (save != null) return save!.future;
    if (failSave) {
      throw const CommandError.storage(
        operation: 'queue',
        reason: 'PRIVATE_DIAGNOSTIC',
      );
    }
    final item = event(messages.length + 1, text: text);
    messages.add(item);
    return ChatMutationView(groupId: groupId, eventId: item.eventId);
  }

  @override
  Future<List<RoutePreviewView>> previewRoutes({
    required List<String> routes,
  }) async => const [
    RoutePreviewView(
      identityId: 'identity',
      deviceId: 'device',
      safetyNumber: '12345 67890',
    ),
  ];
  @override
  Future<ChatMutationView> createConversation({
    required String bootstrap,
    required List<String> routes,
    required List<String> safetyNumbers,
  }) async {
    creates++;
    return ChatMutationView(
      groupId: 'group-a',
      warning: partialCreate
          ? const CommandError.transport(
              operation: 'create',
              reason: 'PRIVATE_DIAGNOSTIC',
            )
          : null,
    );
  }
}

void main() {
  testWidgets('route rebuild retains the conversation controller and draft', (
    tester,
  ) async {
    final profile = ChatProfile()
      ..state = const SetupView(
        administrator: false,
        recoveryWarning: false,
        kitStale: false,
        stage: SetupStage.ready,
        bootstrap: relay,
      );
    final session = ProfileSession(opener: () async => profile);
    addTearDown(session.dispose);
    await tester.pumpWidget(ArveilApp(session: session));
    await tester.tap(find.text('Abrir perfil'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-group-a')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('message-draft')),
      'unsent draft',
    );
    final page = find.byType(ConversationsPage);
    final controller = tester.widget<ConversationsPage>(page).controller;
    ModalRoute.of(tester.element(page))!.changedExternalState();
    await tester.pumpAndSettle();
    expect(tester.widget<ConversationsPage>(page).controller, same(controller));
    expect(controller.selected, 'group-a');
    expect(find.text('unsent draft'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('backgrounding during startup keeps automatic sync paused', (
    tester,
  ) async {
    final profile = ChatProfile()
      ..initialRows = Completer<List<ConversationView>>();
    final chat = ConversationController(profile, relay);
    await tester.pumpWidget(
      MaterialApp(home: ConversationsPage(controller: chat)),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    profile.initialRows!.complete([row]);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    expect(profile.syncs, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(profile.syncs, 1);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(profile.syncs, 2);
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'history answers during blocked sync and a second sync drains queued work',
    () async {
      final profile = ChatProfile()..network = Completer<SyncView>();
      final chat = ConversationController(profile, relay);
      addTearDown(chat.dispose);
      await chat.start(automatic: false);
      final sync = chat.sync();
      var joinedFinished = false;
      final joined = chat.sync().then((_) => joinedFinished = true);
      expect(joinedFinished, isFalse);
      await chat.select('group-a');
      expect(chat.events.single.eventId, 'event-1');
      expect(await chat.send('persisted while offline'), isTrue);
      expect(profile.sends, 1);
      profile.network!.complete(const SyncView(processedEnvelopes: 0));
      await sync;
      await joined;
      expect(joinedFinished, isTrue);
      expect(profile.syncs, 2);
      expect(chat.events.length, 2);
    },
  );
  test('late history cannot overwrite a new selection', () async {
    final profile = ChatProfile()..history = Completer<HistoryPageView>();
    final chat = ConversationController(profile, relay);
    addTearDown(chat.dispose);
    final first = chat.select('group-a');
    await chat.select('group-b');
    profile.history!.complete(HistoryPageView(events: [event(99)]));
    await first;
    expect(chat.selected, 'group-b');
    expect(chat.events.single.eventId, 'event-1');
    expect(chat.loading, isFalse);
  });
  test(
    'pagination with concurrent arrivals stays contiguous without duplicates',
    () async {
      final profile = ChatProfile()
        ..messages = List.generate(130, (i) => event(i + 1));
      final chat = ConversationController(profile, relay);
      addTearDown(chat.dispose);
      await chat.select('group-a');
      expect(chat.events.length, 50);
      await chat.older();
      expect(chat.events.length, 100);
      profile.messages.add(event(131));
      await chat.refresh();
      await chat.older();
      expect(
        chat.events.map((e) => e.cursor),
        List.generate(131, (i) => i + 1),
      );
      expect(chat.before, isNull);
    },
  );
  test(
    'background refresh preserves history already opened beyond ten pages',
    () async {
      final profile = ChatProfile()
        ..messages = List.generate(630, (i) => event(i + 1));
      final chat = ConversationController(profile, relay);
      addTearDown(chat.dispose);
      await chat.select('group-a');
      for (var i = 0; i < 10; i++) {
        await chat.older();
      }
      final oldest = chat.events.first.cursor;
      profile.messages.add(event(631));
      await chat.refresh();
      expect(chat.events.any((e) => e.cursor == oldest), isTrue);
      expect(chat.events.last.cursor, 631);
      expect(
        chat.events.map((e) => e.eventId).toSet().length,
        chat.events.length,
      );
    },
  );
  testWidgets(
    'received text is rendered and relay acceptance never claims human reading',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                MessageBubble(
                  event: HistoryEventView(
                    cursor: 1,
                    eventId: 'in',
                    kind: 'received',
                    body: utf8.encode('received body'),
                    delivery: const [],
                    createdAt: 1790000000,
                    own: false,
                  ),
                ),
                MessageBubble(
                  event: HistoryEventView(
                    cursor: 2,
                    eventId: 'out',
                    kind: 'sent',
                    body: utf8.encode('sent body'),
                    delivery: const ['accepted'],
                    createdAt: 1790000000,
                    own: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('received body'), findsOneWidget);
      expect(find.text('Recibido en este dispositivo'), findsOneWidget);
      expect(
        find.text('Aceptado por el servidor · lectura sin confirmar'),
        findsOneWidget,
      );
    },
  );
  Future<ConversationController> open(
    WidgetTester tester,
    ChatProfile profile,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final chat = ConversationController(profile, relay);
    await tester.pumpWidget(
      MaterialApp(home: ConversationsPage(controller: chat)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-group-a')));
    await tester.pumpAndSettle();
    return chat;
  }

  testWidgets(
    'offline acceptance clears its draft and sync retry never resends',
    (tester) async {
      final profile = ChatProfile()..offline = true;
      final chat = await open(tester, profile);
      await tester.enterText(
        find.byKey(const Key('message-draft')),
        'offline text',
      );
      await tester.tap(find.byKey(const Key('send-message')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message-draft')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.text('offline text'), findsOneWidget);
      expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
      profile.offline = false;
      await chat.sync();
      await tester.pumpAndSettle();
      expect(profile.sends, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'failed save keeps draft, double send disabled, newer draft preserved',
    (tester) async {
      final profile = ChatProfile()..failSave = true;
      final chat = await open(tester, profile);
      await tester.enterText(find.byKey(const Key('message-draft')), 'keep me');
      await tester.tap(find.byKey(const Key('send-message')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message-draft')))
            .controller!
            .text,
        'keep me',
      );
      expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
      profile.save = Completer<ChatMutationView>();
      await tester.tap(find.byKey(const Key('send-message')));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('send-message')))
            .onPressed,
        isNull,
      );
      expect(await chat.send('duplicate'), isFalse);
      await tester.enterText(
        find.byKey(const Key('message-draft')),
        'next draft',
      );
      profile.save!.complete(
        const ChatMutationView(groupId: 'group-a', eventId: 'event-2'),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message-draft')))
            .controller!
            .text,
        'next draft',
      );
      expect(profile.sends, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'route edits invalidate comparison; post-commit error leaves creation form',
    (tester) async {
      final profile = ChatProfile()..partialCreate = true;
      await open(tester, profile);
      await tester.tap(find.byTooltip('Nueva conversación'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('peer-routes')),
        'first-route',
      );
      await tester.tap(find.text('Preparar comparación'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('create-conversation')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('compared-routes')));
      await tester.enterText(
        find.byKey(const Key('peer-routes')),
        'changed-route',
      );
      await tester.pump();
      expect(find.byKey(const Key('create-conversation')), findsNothing);
      await tester.tap(find.text('Preparar comparación'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('compared-routes')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('create-conversation')));
      await tester.tap(find.byKey(const Key('create-conversation')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('peer-routes')), findsNothing);
      expect(find.textContaining('Conversación guardada.'), findsOneWidget);
      expect(profile.creates, 1);
      expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'group messages name their author, and own messages from another device sit on the own side',
    (tester) async {
      HistoryEventView message(
        String id, {
        required bool own,
        String? label,
        String kind = 'received',
      }) => HistoryEventView(
        cursor: 1,
        eventId: id,
        kind: kind,
        body: utf8.encode('body $id'),
        delivery: const [],
        createdAt: 1790000000,
        senderLabel: label,
        own: own,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                MessageBubble(
                  event: message('lucia', own: false, label: 'Lucía'),
                  showSender: true,
                ),
                MessageBubble(
                  event: message('pair', own: false, label: 'Pablo'),
                ),
                MessageBubble(event: message('mine', own: true)),
              ],
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('sender-lucia')), findsOneWidget);
      expect(find.text('Lucía'), findsOneWidget);
      // One other person: the author is obvious and not repeated.
      expect(find.byKey(const Key('sender-pair')), findsNothing);
      expect(find.byKey(const Key('sender-mine')), findsNothing);
      expect(
        find.text('Enviado desde otro de tus dispositivos'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('time-lucia')), findsOneWidget);
      final mine = tester.widget<Align>(
        find
            .ancestor(
              of: find.byKey(const Key('message-mine')),
              matching: find.byType(Align),
            )
            .first,
      );
      expect(mine.alignment, Alignment.centerRight);
    },
  );

  test('recorded times show the hour today and the date otherwise', () {
    final at = DateTime(2026, 9, 25, 18, 4);
    final seconds = at.millisecondsSinceEpoch ~/ 1000;
    expect(recordedTime(seconds, now: DateTime(2026, 9, 25, 23)), '18:04');
    expect(
      recordedTime(seconds, now: DateTime(2026, 9, 26, 9)),
      '25/9/2026 18:04',
    );
  });

  testWidgets('opening a conversation marks what it shows as read, once', (
    tester,
  ) async {
    final profile = ChatProfile()..messages = [event(1), event(2)];
    final chat = await open(tester, profile);
    expect(profile.marks, [('group-a', 2)]);
    await chat.refresh();
    await tester.pumpAndSettle();
    expect(profile.marks, [('group-a', 2)], reason: 'same cursor, no new mark');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rows show who wrote last, when, and what is unread', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    PeerView peer(String id, String label) => PeerView(
      identityId: id,
      deviceId: 'device-$id',
      label: label,
      own: false,
      verified: true,
      revoked: false,
    );
    LastEventView last(String preview, {String? label, bool own = false}) =>
        LastEventView(
          cursor: 1,
          kind: own ? 'sent' : 'received',
          preview: preview,
          senderLabel: label,
          own: own,
          createdAt: 1790000000,
          delivery: const [],
        );
    ConversationView conversation(
      String id,
      List<PeerView> peers,
      LastEventView event,
      int unread,
    ) => ConversationView(
      groupId: id,
      creator: true,
      peerDevices: peers.length,
      peers: peers,
      eventCount: 1,
      lastEvent: event,
      unread: unread,
      lastActivity: 1790000000,
    );
    final profile = ChatProfile()
      ..initialRows = Completer<List<ConversationView>>();
    final chat = ConversationController(profile, relay);
    await tester.pumpWidget(
      MaterialApp(home: ConversationsPage(controller: chat)),
    );
    profile.initialRows!.complete([
      conversation(
        'group-a',
        [peer('a', 'Lucía'), peer('b', 'Pablo')],
        last('¿Quién trae el postre?', label: 'Lucía'),
        3,
      ),
      conversation(
        'group-b',
        [peer('a', 'Lucía')],
        last('Llego a las nueve', own: true),
        0,
      ),
      conversation(
        'group-c',
        [peer('c', 'Mamá')],
        last('hola', label: 'Mamá'),
        1,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Lucía: ¿Quién trae el postre?'), findsOneWidget);
    expect(find.text('Tú: Llego a las nueve'), findsOneWidget);
    // With one other person the author is obvious and not repeated.
    expect(find.text('hola'), findsOneWidget);
    expect(find.byKey(const Key('unread-group-a')), findsOneWidget);
    expect(find.byKey(const Key('unread-group-b')), findsNothing);
    // The row reads as one node; the count is part of what it says.
    expect(
      find.bySemanticsLabel(RegExp('3 mensajes sin leer')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp('1 mensaje sin leer')), findsOneWidget);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  test('device notices say who changed how many devices, never which', () {
    expect(
      noticeText('Lucía', const NoticeView(added: 1, removed: 0)),
      'Lucía ha añadido un dispositivo.',
    );
    expect(
      noticeText(null, const NoticeView(added: 2, removed: 1)),
      'Un contacto ha añadido 2 dispositivos y ha retirado un dispositivo.',
    );
  });

  testWidgets('a device notice asks to compare numbers unless verified', (
    tester,
  ) async {
    HistoryEventView notice(String id) => HistoryEventView(
      cursor: 1,
      eventId: id,
      kind: 'devices-changed',
      body: Uint8List(0),
      delivery: const [],
      createdAt: 1790000000,
      senderLabel: 'Lucía',
      own: false,
      notice: const NoticeView(added: 1, removed: 0),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageBubble(event: notice('verified'), senderVerified: true),
              MessageBubble(event: notice('unverified')),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Lucía ha añadido un dispositivo.'), findsNWidgets(2));
    expect(
      find.text('El cambio está firmado por su identidad verificada.'),
      findsOneWidget,
    );
    expect(
      find.text('Compara su número de seguridad si no esperabas este cambio.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('message-verified')), findsNothing);
  });

  test('the sync line says when it last worked, never that mail arrived', () {
    final now = DateTime(2026, 9, 25, 18, 30);
    expect(syncStatusText(SyncState.never, null, now), 'Aún sin sincronizar');
    expect(
      syncStatusText(
        SyncState.synced,
        now.subtract(const Duration(seconds: 20)),
        now,
      ),
      'Sincronizado ahora',
    );
    expect(
      syncStatusText(
        SyncState.synced,
        now.subtract(const Duration(minutes: 2)),
        now,
      ),
      'Sincronizado hace 2 min',
    );
    expect(
      syncStatusText(SyncState.offline, DateTime(2026, 9, 25, 16, 5), now),
      'Sin conexión con tu servidor · última sincronización a las 16:05',
    );
    expect(
      syncStatusText(SyncState.refused, null, now),
      'El servidor rechazó la sincronización',
    );
  });

  testWidgets('a transport failure reads as offline, not as a server refusal', (
    tester,
  ) async {
    final profile = ChatProfile();
    final chat = await open(tester, profile);
    await chat.sync();
    await tester.pumpAndSettle();
    expect(chat.syncState, SyncState.synced);
    expect(chat.lastSynced, isNotNull);
    expect(find.byKey(const Key('sync-status')), findsOneWidget);

    profile.offline = true;
    await chat.sync();
    await tester.pumpAndSettle();
    expect(chat.syncState, SyncState.offline);
    expect(chat.lastSynced, isNotNull, reason: 'the last success is kept');
    expect(find.textContaining('Sin conexión con tu servidor'), findsOneWidget);
    expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
