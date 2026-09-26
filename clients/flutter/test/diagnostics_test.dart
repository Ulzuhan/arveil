import 'package:arveil/src/diagnostics.dart';
import 'package:arveil/src/diagnostics_page.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:arveil/src/updates/manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'navigation_test.dart' show HomeProfile;

/// Everything a real profile could leak, each marked so a test can look
/// for it in the report.
const secrets = [
  'SECRET-HOST.example',
  'arveil-bootstrap:v0:SECRET',
  'IDENTITY-SECRET-0001',
  'DEVICE-SECRET-0002',
  'Lucía Secreta',
  'MENSAJE-SECRETO',
  'arveil-route:v0:ROUTE-SECRET',
  '11111 22222 33333',
  '/srv/SECRET-PATH/profile',
  'PRIVATE-REASON',
  'GROUP-SECRET-0003',
];

class SecretProfile extends HomeProfile {
  SecretProfile() {
    state = const SetupView(
      stage: SetupStage.ready,
      administrator: true,
      recoveryWarning: false,
      kitStale: true,
      kitSavedAt: 1790000000,
      bootstrap: 'arveil-bootstrap:v0:SECRET-HOST.example:443',
    );
  }

  @override
  Future<List<ConversationView>> conversations() async => [
    ConversationView(
      groupId: 'GROUP-SECRET-0003',
      creator: true,
      peerDevices: 1,
      peers: const [
        PeerView(
          identityId: 'IDENTITY-SECRET-0001',
          deviceId: 'DEVICE-SECRET-0002',
          label: 'Lucía Secreta',
          named: true,
          own: false,
          verified: true,
          revoked: false,
        ),
      ],
      eventCount: 1,
      lastEvent: const LastEventView(
        cursor: 1,
        kind: 'received',
        preview: 'MENSAJE-SECRETO',
        own: false,
        createdAt: 1790000000,
        delivery: [],
      ),
      unread: 1,
      lastActivity: 1790000000,
    ),
  ];

  @override
  Future<DeviceInventoryView> devices() async => DeviceInventoryView(
    administrator: true,
    manifestSequence: BigInt.from(3),
    unknownActive: 0,
    unknownRevoked: 0,
    devices: const [
      ManagedDeviceView(
        deviceId: 'DEVICE-SECRET-0002',
        current: true,
        revoked: false,
      ),
      ManagedDeviceView(
        deviceId: 'DEVICE-SECRET-9',
        current: false,
        revoked: false,
      ),
      ManagedDeviceView(
        deviceId: 'DEVICE-SECRET-8',
        current: false,
        revoked: true,
      ),
    ],
  );

  @override
  Future<String> ownRoute() async => 'arveil-route:v0:ROUTE-SECRET';
}

class MemoryDiagnosticFiles extends DiagnosticFiles {
  String? saved;

  @override
  Future<bool> save(String report) async {
    saved = report;
    return true;
  }
}

Future<ProfileSession> openSecret() async {
  final session = ProfileSession(opener: () async => SecretProfile());
  await session.open();
  return session;
}

void main() {
  setUp(FailureLog.clear);

  test('failure codes keep the kind and operation, never the reason', () {
    expect(
      failureCode(
        const CommandError.transport(
          operation: 'sync',
          reason: 'PRIVATE-REASON at SECRET-HOST.example',
        ),
      ),
      'transport:sync',
    );
    expect(
      failureCode(
        const CommandError.domain(operation: 'Lucía Secreta', reason: 'x'),
      ),
      'domain:unknown',
      reason: 'an operation that is not a plain name is not repeated',
    );
    expect(
      failureCode(
        const ProfileError.tooNew(
          path: '/srv/SECRET-PATH/profile',
          found: 7,
          supported: 6,
        ),
      ),
      'profile:too-new',
    );
    expect(
      failureCode(
        const CommandError.quota(
          operation: 'begin-pairing',
          reason: 'too many pairings from SECRET-HOST.example',
        ),
      ),
      'quota:begin-pairing',
    );
    expect(failureCode(StateError('/srv/SECRET-PATH/profile')), 'other');
  });

  test('only the latest failures are kept', () {
    for (var i = 0; i < FailureLog.limit + 5; i++) {
      FailureLog.record(
        const CommandError.storage(operation: 'queue', reason: ''),
      );
    }
    FailureLog.record(
      const CommandError.transport(operation: 'sync', reason: ''),
    );
    expect(FailureLog.codes, hasLength(FailureLog.limit));
    expect(FailureLog.codes.last, 'transport:sync');
  });

  test(
    'the report says the state in counts and leaks none of the secrets',
    () async {
      final session = await openSecret();
      addTearDown(session.dispose);
      FailureLog.record(
        const CommandError.transport(
          operation: 'sync',
          reason: 'PRIVATE-REASON /srv/SECRET-PATH/profile SECRET-HOST.example',
        ),
      );
      final report = await diagnosticReport(
        session,
        language: 'es',
        system: 'testos 1.0',
      );
      for (final secret in secrets) {
        expect(report, isNot(contains(secret)), reason: secret);
      }
      expect(report, contains('language: es'));
      expect(report, contains('system: testos 1.0'));
      expect(report, contains('setup: ready'));
      expect(report, contains('role: administrator'));
      expect(report, contains('conversations: 1'));
      expect(report, contains('active devices: 2'));
      expect(report, contains('identity kit: stale'));
      expect(report, contains('recent failures: transport:sync'));
      expect(report, contains('version: local build'));
      expect(report, contains('updates: none'));
    },
  );

  test('a refused update configuration is reported, never its values', () {
    const key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
    const feed = 'https://updates.example.org/clients-beta.json';
    expect(UpdateConfig.status(url: '', key: ''), 'none');
    expect(UpdateConfig.status(url: feed, key: key, channel: 'beta'), 'beta');
    expect(
      UpdateConfig.status(url: feed, key: key, channel: 'stable'),
      'stable',
    );
    for (final (url, key, channel) in [
      (feed, '', 'beta'),
      ('', key, 'beta'),
      ('http://updates.example.org/clients.json', key, 'beta'),
      ('$feed?', key, 'beta'),
      (feed, 'not base64', 'beta'),
      (feed, 'AAAA', 'beta'),
      (feed, key, 'nightly'),
    ]) {
      expect(
        UpdateConfig.status(url: url, key: key, channel: channel),
        'invalid',
        reason: '$url $key $channel',
      );
    }
  });

  testWidgets('the screen shows the report and saves exactly that', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = await tester.runAsync(openSecret);
    addTearDown(session!.dispose);
    final files = MemoryDiagnosticFiles();
    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsPage(session: session, files: files),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    final shown = tester
        .widget<SelectableText>(find.byKey(const Key('diagnostic-report')))
        .data!;
    expect(shown, contains('conversations: 1'));
    await tester.tap(find.byKey(const Key('save-diagnostics')));
    await tester.pumpAndSettle();
    expect(files.saved, shown);
    expect(find.text('Informe guardado'), findsOneWidget);
  });
}
