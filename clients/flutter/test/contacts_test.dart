import 'dart:async';

import 'package:arveil/src/contacts_page.dart';
import 'package:arveil/src/conversation_controller.dart';
import 'package:arveil/src/conversations_page.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'conversations_test.dart' show ChatProfile;
import 'widget_test.dart' show relay;

ContactView person({
  String id = 'alice',
  String name = 'Ana',
  bool verified = false,
  List<ContactDeviceView>? devices,
}) => ContactView(
  identityId: id,
  label: name,
  name: name,
  verified: verified,
  safetyNumber: '12345 67890',
  devices:
      devices ??
      const [ContactDeviceView(deviceId: 'device-a', revoked: false)],
);

class AddressProfile extends ChatProfile {
  List<ContactView> people = [];
  List<PeerView>? conversationPeople;
  @override
  Future<List<ConversationView>> conversations() async =>
      conversationPeople == null
      ? await super.conversations()
      : [
          ConversationView(
            groupId: 'group-a',
            creator: true,
            peerDevices: conversationPeople!.length,
            peers: conversationPeople!,
            eventCount: 1,
            unread: 0,
            lastActivity: 0,
          ),
        ];

  String? savedNumber;
  List<SavedRecipientView>? selectedRecipients;
  int saves = 0;
  bool fail = false;
  Completer<ContactView>? pendingSave;
  @override
  Future<List<ContactView>> contacts() async => [...people];
  @override
  Future<List<RoutePreviewView>> previewRoutes({
    required List<String> routes,
  }) async => const [
    RoutePreviewView(
      identityId: 'alice',
      deviceId: 'device-a',
      safetyNumber: '12345 67890',
    ),
  ];
  @override
  Future<ContactView> saveContact({
    required String route,
    required String name,
    String? safetyNumber,
  }) async {
    saves++;
    savedNumber = safetyNumber;
    if (pendingSave != null) return pendingSave!.future;
    if (fail) throw StateError('PRIVATE_ROUTE_AND_PATH');
    final c = person(name: name, verified: safetyNumber != null);
    people = [c];
    return c;
  }

  @override
  Future<ContactView> verifyContact({
    required String identityId,
    required String safetyNumber,
  }) async {
    savedNumber = safetyNumber;
    final c = person(verified: true);
    people = [c];
    return c;
  }

  @override
  Future<ContactView> renameContact({
    required String identityId,
    required String name,
  }) async {
    final c = person(name: name, verified: people.single.verified);
    people = [c];
    return c;
  }

  @override
  Future<ChatMutationView> createContactConversation({
    required String bootstrap,
    required List<SavedRecipientView> recipients,
  }) async {
    selectedRecipients = recipients;
    return const ChatMutationView(groupId: 'group-a');
  }
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('participant names and verification fit a phone dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final profile = AddressProfile()
      ..conversationPeople = const [
        PeerView(
          identityId: 'alice-identity',
          deviceId: 'alice-device',
          label: 'Ana',
          own: false,
          verified: true,
          revoked: false,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationsPage(
          controller: ConversationController(profile, relay),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const Key('conversation-group-a')));
    expect(find.text('Ana'), findsWidgets);
    await tap(tester, find.byTooltip('Participantes'));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('Verificado'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tap(tester, find.text('Cerrar'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'saving a name does not verify; comparison explicitly enables verification',
    (tester) async {
      final profile = AddressProfile();
      await tester.pumpWidget(
        MaterialApp(home: ContactEditorPage(profile: profile)),
      );
      await tester.enterText(find.byKey(const Key('contact-name')), 'Ana');
      await tester.enterText(
        find.byKey(const Key('contact-route')),
        'fixture route',
      );
      await tap(tester, find.text('Preparar contacto'));
      await tap(tester, find.byKey(const Key('save-contact')));
      expect(profile.savedNumber, isNull);
      expect(find.text('Sin verificar'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('verify-contact')))
            .onPressed,
        isNull,
      );
      await tap(tester, find.byKey(const Key('contact-compared')));
      await tap(tester, find.byKey(const Key('verify-contact')));
      expect(profile.savedNumber, '12345 67890');
      expect(find.text('Verificado'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('contact-name')),
        'Ana trabajo',
      );
      await tap(tester, find.byKey(const Key('save-contact')));
      expect(profile.people.single.label, 'Ana trabajo');
      expect(profile.people.single.verified, isTrue);
    },
  );

  testWidgets('changing a prepared route invalidates its comparison', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: ContactEditorPage(profile: AddressProfile())),
    );
    await tester.enterText(find.byKey(const Key('contact-route')), 'first');
    await tap(tester, find.text('Preparar contacto'));
    await tap(tester, find.byKey(const Key('contact-compared')));
    await tester.enterText(find.byKey(const Key('contact-route')), 'different');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('contact-safety')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('save-contact')))
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'save prevents duplicates and failure does not expose diagnostics',
    (tester) async {
      final profile = AddressProfile()..pendingSave = Completer<ContactView>();
      await tester.pumpWidget(
        MaterialApp(home: ContactEditorPage(profile: profile)),
      );
      await tester.enterText(find.byKey(const Key('contact-route')), 'fixture');
      await tap(tester, find.text('Preparar contacto'));
      await tester.ensureVisible(find.byKey(const Key('save-contact')));
      await tester.tap(find.byKey(const Key('save-contact')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-contact')))
            .onPressed,
        isNull,
      );
      expect(profile.saves, 1);
      profile.pendingSave!.completeError(StateError('PRIVATE_ROUTE_AND_PATH'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No se pudo guardar'), findsOneWidget);
      expect(find.textContaining('PRIVATE_ROUTE_AND_PATH'), findsNothing);
      expect(find.byKey(const Key('contact-route')), findsOneWidget);
    },
  );

  testWidgets(
    'saved selection excludes unverified contacts and revoked devices',
    (tester) async {
      final profile = AddressProfile()
        ..people = [
          person(
            verified: true,
            devices: const [
              ContactDeviceView(deviceId: 'active', revoked: false),
              ContactDeviceView(deviceId: 'revoked', revoked: true),
            ],
          ),
          person(id: 'unverified', name: 'Sin verificar'),
          person(id: 'no-route', name: 'Sin ruta', verified: true, devices: []),
        ];
      final chat = ConversationController(profile, relay);
      addTearDown(chat.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => NewConversationPage(chat: chat),
                ),
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      );
      await tap(tester, find.text('Start'));
      await tap(tester, find.byKey(const Key('choose-contacts')));
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const Key('select-contact-unverified')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<Checkbox>(find.byKey(const Key('select-contact-no-route')))
            .onChanged,
        isNull,
      );
      await tap(tester, find.byKey(const Key('select-contact-alice')));
      await tap(tester, find.byKey(const Key('use-contacts')));
      expect(profile.selectedRecipients, const [
        SavedRecipientView(identityId: 'alice', deviceId: 'active'),
      ]);
      expect(chat.selected, 'group-a');
      expect(find.text('Start'), findsOneWidget);
    },
  );

  test(
    'conversation title uses local names once per identity, without conflating identical aliases',
    () {
      const peers = [
        PeerView(
          identityId: 'a',
          deviceId: 'a1',
          label: 'Ana',
          own: false,
          verified: true,
          revoked: false,
        ),
        PeerView(
          identityId: 'a',
          deviceId: 'a2',
          label: 'Ana',
          own: false,
          verified: true,
          revoked: false,
        ),
        PeerView(
          identityId: 'b',
          deviceId: 'b1',
          label: 'Ana',
          own: false,
          verified: false,
          revoked: false,
        ),
        PeerView(
          identityId: 'me',
          deviceId: 'me1',
          label: 'Me',
          own: true,
          verified: true,
          revoked: false,
        ),
      ];
      expect(
        conversationTitle(
          const ConversationView(
            groupId: 'group',
            creator: true,
            peerDevices: 4,
            peers: peers,
            eventCount: 0,
            unread: 0,
            lastActivity: 0,
          ),
        ),
        'Ana, Ana',
      );
    },
  );
}
