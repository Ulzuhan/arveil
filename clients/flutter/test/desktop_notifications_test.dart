import 'dart:async';
import 'package:arveil/src/desktop_notifications.dart';
import 'package:arveil/src/conversation_controller.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'conversations_test.dart' show ChatProfile;
import 'widget_test.dart' show relay;

class Receipts implements NotificationReceipts {
  List<String> hashes = [];
  Completer<void>? wait;
  @override
  Future<List<String>> read() async => hashes;
  @override
  Future<void> write(List<String> values) async {
    if (wait != null) await wait!.future;
    hashes = values;
  }
}

ConversationView row(
  int cursor,
  int unread, {
  String group = 'group-a',
  bool own = false,
}) => ConversationView(
  groupId: group,
  creator: true,
  peerDevices: 1,
  peers: const [],
  eventCount: cursor,
  unread: unread,
  lastActivity: cursor,
  lastEvent: LastEventView(
    cursor: cursor,
    kind: own ? 'sent' : 'received',
    preview: 'PRIVATE_CONTENT',
    senderLabel: 'PRIVATE_SENDER',
    own: own,
    createdAt: cursor,
    delivery: const [],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.ulzuhan.arveil/notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Receipts receipts;
  late DesktopNotifications notifications;
  setUp(() async {
    calls = [];
    receipts = Receipts();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'status' || call.method == 'configure') {
        return {'enabled': true, 'background': true};
      }
      if (call.method == 'show') return true;
      return null;
    });
    notifications = DesktopNotifications(receipts: receipts, supported: true);
    await notifications.initialize();
  });
  tearDown(() {
    notifications.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'baseline, own activity, unchanged snapshots and visible conversation are silent',
    () async {
      await notifications.observe([row(1, 1)]);
      await notifications.observe([row(2, 1, own: true)]);
      await notifications.observe([row(2, 1, own: true)]);
      notifications.visibleGroup = () => 'group-a';
      await notifications.observe([row(3, 2)]);
      expect(calls.where((c) => c.method == 'show'), isEmpty);
      notifications.visibleGroup = () => null;
      await Future.wait([
        notifications.observe([row(4, 3)]),
        notifications.observe([row(4, 3)]),
      ]);
      final shown = calls.where((c) => c.method == 'show').single;
      expect(shown.arguments.toString(), isNot(contains('PRIVATE_')));
      expect(shown.arguments.toString(), isNot(contains('group-a')));
      expect(receipts.hashes, hasLength(1));
    },
  );

  test(
    'persisted receipt suppresses repeated presentation across notifier instances',
    () async {
      await notifications.observe([row(1, 0)]);
      await notifications.observe([row(2, 1)]);
      notifications.dispose();
      notifications = DesktopNotifications(receipts: receipts, supported: true);
      await notifications.initialize();
      await notifications.observe([row(1, 0)]);
      await notifications.observe([row(2, 1)]);
      expect(calls.where((c) => c.method == 'show'), hasLength(1));
    },
  );

  test(
    'closing a profile while receipt storage is pending prevents presentation',
    () async {
      await notifications.observe([row(1, 0)]);
      receipts.wait = Completer<void>();
      final pending = notifications.observe([row(2, 1)]);
      await Future<void>.delayed(Duration.zero);
      notifications.dispose();
      receipts.wait!.complete();
      await pending;
      expect(calls.where((c) => c.method == 'show'), isEmpty);
      // tearDown owns a fresh instance so ChangeNotifier is disposed once.
      notifications = DesktopNotifications(receipts: receipts, supported: true);
    },
  );

  test('background sync never enables hidden read markers', () async {
    final profile = ChatProfile();
    final chat = ConversationController(profile, relay);
    await chat.start(automatic: false);
    await chat.select('group-a');
    chat.setActive(false);
    chat.setBackgroundSync(true);
    await chat.sync();
    expect(profile.syncs, greaterThan(0));
    await chat.markVisible('group-a', 1);
    expect(profile.marks, isEmpty);
    chat.setActive(true);
    chat.setPageVisible(false);
    await chat.markVisible('group-a', 1);
    expect(profile.marks, isEmpty);
    chat.setPageVisible(true);
    chat.setWindowVisible(false);
    await chat.markVisible('group-a', 1);
    expect(profile.marks, isEmpty);
    expect(chat.visibleGroup, isNull);
    chat.setWindowVisible(true);
    await chat.markVisible('group-a', 1);
    expect(profile.marks, [('group-a', 1)]);
    chat.dispose();
  });

  test(
    'denied OS permission leaves alerts disabled and does not post',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'enabled': false, 'background': true};
      });
      await notifications.configure(alerts: true);
      expect(notifications.enabled, isFalse);
      expect(notifications.error, isNotNull);
      await notifications.observe([row(1, 0)]);
      await notifications.observe([row(2, 1)]);
      expect(calls.where((c) => c.method == 'show'), isEmpty);
    },
  );
}
