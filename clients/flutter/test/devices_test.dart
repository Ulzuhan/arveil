import 'dart:async';

import 'package:arveil/src/devices_page.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'conversations_test.dart' show ChatProfile;
import 'widget_test.dart' show relay;

class DevicesProfile extends ChatProfile {
  bool administrator = true;
  bool revoked = false;
  bool published = false;
  bool fail = false;
  int revocations = 0;
  String? target;
  Completer<void>? waiting;
  @override
  Future<DeviceInventoryView> devices() async => DeviceInventoryView(
    administrator: administrator,
    manifestSequence: BigInt.from(revoked ? 3 : 2),
    unknownActive: administrator ? 0 : 1,
    unknownRevoked: 0,
    devices: [
      const ManagedDeviceView(
        deviceId: 'current-device',
        current: true,
        revoked: false,
      ),
      ManagedDeviceView(
        deviceId: 'other-device',
        current: false,
        revoked: revoked,
        revocation: !revoked
            ? null
            : RevocationProgressView(
                relayPublished: published,
                groupsWaiting: 1,
                notificationsPending: published ? 0 : 2,
                notificationsUnconfirmed: 0,
                withoutRoute: 0,
              ),
      ),
    ],
  );
  @override
  Future<void> revokeDevice({
    required String bootstrap,
    required String deviceId,
  }) async {
    revocations++;
    target = deviceId;
    revoked = true;
    await waiting?.future;
    if (fail) throw StateError('PRIVATE_PATH_AND_ENDPOINT');
    published = true;
  }

  @override
  Future<SyncView> sync_({required String bootstrap}) async {
    syncs++;
    published = true;
    return const SyncView(processedEnvelopes: 0);
  }
}

void main() {
  Future<void> show(WidgetTester tester, DevicesProfile p) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DevicesPage(profile: p, bootstrap: relay),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'confirmation identifies the target; cancelling does not revoke',
    (tester) async {
      final p = DevicesProfile();
      await show(tester, p);
      expect(find.byKey(const Key('revoke-current-device')), findsNothing);
      await press(tester, find.byKey(const Key('revoke-other-device')));
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('other-device'),
        ),
        findsOneWidget,
      );
      await press(tester, find.text('Cancelar'));
      expect(p.revocations, 0);
      await press(tester, find.byKey(const Key('revoke-other-device')));
      await press(tester, find.byKey(const Key('confirm-device-revocation')));
      expect(p.revocations, 1);
      expect(p.target, 'other-device');
      expect(find.text('Revocación aceptada por el servidor'), findsOneWidget);
      expect(
        find.text('Conversaciones locales pendientes de retirarlo: 1'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'linked devices show a partial inventory without revocation controls',
    (tester) async {
      final p = DevicesProfile()..administrator = false;
      await show(tester, p);
      expect(find.byKey(const Key('partial-device-inventory')), findsOneWidget);
      expect(find.text('Revocar dispositivo'), findsNothing);
    },
  );

  testWidgets(
    'failed publication reloads durable state; retry synchronizes once',
    (tester) async {
      final p = DevicesProfile()..fail = true;
      await show(tester, p);
      await press(tester, find.byKey(const Key('revoke-other-device')));
      await press(tester, find.byKey(const Key('confirm-device-revocation')));
      expect(
        find.text('Pendiente de publicar la revocación en el servidor'),
        findsOneWidget,
      );
      expect(find.textContaining('PRIVATE_PATH'), findsNothing);
      expect(find.byKey(const Key('revoke-other-device')), findsNothing);
      await press(tester, find.byKey(const Key('sync-devices')));
      expect(p.syncs, 1);
      expect(p.revocations, 1);
      expect(find.text('Revocación aceptada por el servidor'), findsOneWidget);
    },
  );

  testWidgets('closing the page while a confirmed revocation waits is safe', (
    tester,
  ) async {
    final p = DevicesProfile()..waiting = Completer<void>();
    await show(tester, p);
    await press(tester, find.byKey(const Key('revoke-other-device')));
    await tester.tap(find.byKey(const Key('confirm-device-revocation')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final syncButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('sync-devices')),
    );
    expect(syncButton.onPressed, isNull);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    p.waiting!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(p.revocations, 1);
  });
}
