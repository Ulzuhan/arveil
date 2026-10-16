import 'package:arveil/src/android_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' show FakeProfile;

class WatchProfile extends FakeProfile {
  int registered = 0, cleared = 0;
  final hints = <String>[];
  bool offline = false;
  @override
  Future<Uint8List> registerWatchKey() async {
    if (offline) throw StateError('PRIVATE_WATCH_DIAGNOSTIC');
    registered++;
    return Uint8List.fromList(List.filled(96, registered));
  }

  @override
  Future<void> clearWatchKey() async {
    if (offline) throw StateError('PRIVATE_WATCH_DIAGNOSTIC');
    cleared++;
  }

  @override
  Future<void> setNotificationHint({required String endpoint}) async {
    if (offline) throw StateError('PRIVATE_ENDPOINT_DIAGNOSTIC');
    hints.add(endpoint);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.ulzuhan.arveil/push');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late WatchProfile profile;
  late AndroidNotifications controller;
  late Map<String, Object?> state;
  late List<Uint8List> handed;
  late int syncs;
  setUp(() async {
    profile = WatchProfile();
    syncs = 0;
    handed = [];
    state = {
      'owner': 'a' * 64,
      'enabled': false,
      'listening': false,
      'pending': false,
      'hintRevision': '',
      'error': '',
      'removal': false,
      'legacy': false,
      'legacyEnabled': false,
      'permission': true,
      'battery': false,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'takeOpen':
          return false;
        case 'enable':
          handed.add(call.arguments['credentials'] as Uint8List);
          state.addAll({'enabled': true, 'error': ''});
        case 'disable':
          state.addAll({'enabled': false, 'removal': true, 'pending': false});
        case 'removed':
          state['removal'] = false;
        case 'legacyCleared':
          state.addAll({'legacy': false, 'legacyEnabled': false});
        case 'synced':
          if (call.arguments['revision'] == state['hintRevision']) {
            state['pending'] = false;
          }
      }
      return Map<String, Object?>.of(state);
    });
    controller = AndroidNotifications(
      profile: profile,
      supported: true,
      testOwner: 'a' * 64,
      sync: () async {
        syncs++;
        return !profile.offline;
      },
    );
    await controller.initialize();
  });
  tearDown(() {
    controller.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'turning on registers a watch key and hands it to the service',
    () async {
      await controller.configure(enable: true);
      expect(profile.registered, 1);
      expect(handed.single, hasLength(96));
      expect(controller.enabled, isTrue);
    },
  );

  test(
    'turning off stops at once and tells the realm, retrying offline',
    () async {
      await controller.configure(enable: true);
      profile.offline = true;
      await controller.configure(enable: false);
      expect(controller.enabled, isFalse);
      expect(state['removal'], isTrue);
      expect(controller.error, isNot(contains('PRIVATE')));
      profile.offline = false;
      await controller.reconcile();
      expect(profile.cleared, 1);
      expect(state['removal'], isFalse);
    },
  );

  test(
    'the ntfy hint of beta 6 is removed and an enabled choice carries over',
    () async {
      state.addAll({'legacy': true, 'legacyEnabled': true, 'enabled': false});
      await controller.reconcile();
      expect(profile.hints, ['']);
      expect(state['legacy'], isFalse);
      expect(profile.registered, 1);
      expect(controller.enabled, isTrue);
    },
  );

  test('a refused key is renewed once per foreground', () async {
    await controller.configure(enable: true);
    state['error'] = 'refused';
    await controller.reconcile();
    expect(profile.registered, 2);
    state['error'] = 'refused';
    await controller.reconcile();
    expect(profile.registered, 2, reason: 'not again until the next resume');
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await controller.reconcile();
    expect(profile.registered, 3);
  });

  test(
    'background notices never open a second profile or start a sync',
    () async {
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      state.addAll({'pending': true, 'hintRevision': 'hint'});
      await controller.reconcile();
      expect(syncs, 0);
      expect(state['pending'], isTrue);
    },
  );

  test('failed sync keeps the generic notice pending', () async {
    state.addAll({'pending': true, 'hintRevision': 'hint'});
    profile.offline = true;
    await controller.reconcile();
    expect(state['pending'], isTrue);
    profile.offline = false;
    await controller.reconcile();
    expect(state['pending'], isFalse);
  });
}
