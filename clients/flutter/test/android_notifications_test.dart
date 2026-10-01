import 'dart:async';
import 'package:arveil/src/android_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' show FakeProfile;

class PushProfile extends FakeProfile {
  final endpoints = <String>[];
  bool offline = false;
  Completer<void>? wait;
  @override
  Future<void> setNotificationHint({required String endpoint}) async {
    endpoints.add(endpoint);
    if (offline) throw StateError('PRIVATE_ENDPOINT_DIAGNOSTIC');
    await wait?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.ulzuhan.arveil/push');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PushProfile profile;
  late AndroidNotifications controller;
  late Map<String, Object?> state;
  late int syncs;
  setUp(() async {
    profile = PushProfile();
    syncs = 0;
    state = {
      'owner': 'a' * 64,
      'enabled': false,
      'installed': true,
      'endpoint': '',
      'revision': '',
      'applied': '',
      'pending': false,
      'hintRevision': '',
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'takeOpen') return false;
      if (call.method == 'ack' &&
          call.arguments['revision'] == state['revision']) {
        state['applied'] = state['revision'];
      }
      if (call.method == 'synced' &&
          call.arguments['revision'] == state['hintRevision']) {
        state['pending'] = false;
      }
      if (call.method == 'disable') {
        state.addAll({'enabled': false, 'endpoint': '', 'revision': 'off'});
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
    'registers once, catches up, and ignores repeated unchanged endpoints',
    () async {
      state.addAll({
        'enabled': true,
        'endpoint': 'https://notify.example.org/up-a?up=1',
        'revision': 'one',
      });
      await Future.wait([controller.reconcile(), controller.reconcile()]);
      expect(profile.endpoints, ['https://notify.example.org/up-a?up=1']);
      expect(syncs, 1);
      expect(controller.relayPending, isFalse);
    },
  );
  test(
    'endpoint rotation cannot be acknowledged by an older network reply',
    () async {
      state.addAll({
        'enabled': true,
        'endpoint': 'https://notify.example.org/up-a',
        'revision': 'one',
      });
      profile.wait = Completer<void>();
      final pending = controller.reconcile();
      await Future<void>.delayed(Duration.zero);
      state.addAll({
        'endpoint': 'https://notify.example.org/up-b',
        'revision': 'two',
      });
      profile.wait!.complete();
      await pending;
      expect(profile.endpoints, [
        'https://notify.example.org/up-a',
        'https://notify.example.org/up-b',
      ]);
      expect(state['applied'], 'two');
    },
  );
  test(
    'offline disable remains local and retries remote removal after reconnect',
    () async {
      state.addAll({
        'enabled': true,
        'endpoint': 'https://notify.example.org/up-a',
        'revision': 'one',
        'applied': 'one',
      });
      profile.offline = true;
      await controller.configure(enable: false);
      expect(controller.enabled, isFalse);
      expect(controller.relayPending, isTrue);
      expect(controller.error, isNot(contains('PRIVATE')));
      profile.offline = false;
      await controller.reconcile();
      expect(profile.endpoints, ['', '']);
      expect(controller.relayPending, isFalse);
    },
  );
  test(
    'background hints never open a second profile or start a sync',
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
