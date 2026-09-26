import 'package:arveil/src/contacts_page.dart';
import 'package:arveil/src/conversation_controller.dart';
import 'package:arveil/src/conversations_page.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'conversations_test.dart' show ChatProfile;
import 'widget_test.dart' show relay;

const lucia = 'a1b2c3d4e5f60718';
const pablo = 'b2c3d4e5f6071829';

/// Conversations whose people carry the names this profile gave them.
class NamingProfile extends ChatProfile {
  NamingProfile(this.people, {Map<String, String>? names})
    : names = {...?names};
  final List<String> people;
  final Map<String, String> names;
  final renames = <(String, String)>[];
  bool failRename = false;

  PeerView peer(String identity) => PeerView(
    identityId: identity,
    deviceId: 'device-$identity',
    label: names[identity] ?? identity.substring(0, 8),
    named: names.containsKey(identity),
    own: false,
    verified: false,
    revoked: false,
  );

  @override
  Future<List<ConversationView>> conversations() async => [
    ConversationView(
      groupId: 'group-a',
      creator: true,
      peerDevices: people.length,
      peers: [for (final p in people) peer(p)],
      eventCount: 1,
      unread: 0,
      lastActivity: 0,
    ),
  ];

  @override
  Future<List<ContactView>> contacts() async => [
    for (final p in people)
      ContactView(
        identityId: p,
        name: names[p],
        label: names[p] ?? p.substring(0, 8),
        verified: false,
        safetyNumber: '12345',
        devices: const [],
      ),
  ];

  @override
  Future<ContactView> renameContact({
    required String identityId,
    required String name,
  }) async {
    if (failRename) {
      throw const CommandError.storage(
        operation: 'contact-rename',
        reason: 'PRIVATE_DIAGNOSTIC',
      );
    }
    renames.add((identityId, name));
    if (name.trim().isEmpty) {
      names.remove(identityId);
    } else {
      names[identityId] = name.trim();
    }
    return (await contacts()).firstWhere((c) => c.identityId == identityId);
  }
}

Future<ConversationController> open(
  WidgetTester tester,
  ChatProfile profile, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
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

void main() {
  test('a person without a local name says so, with the short identifier', () {
    final profile = NamingProfile([lucia]);
    expect(peerName(profile.peer(lucia)), 'Sin nombre · a1b2c3d4');
    profile.names[lucia] = 'Lucía';
    expect(peerName(profile.peer(lucia)), 'Lucía');
  });

  testWidgets(
    'an unnamed person is named from the conversation, only in this profile',
    (tester) async {
      final profile = NamingProfile([lucia]);
      await open(tester, profile);
      expect(find.text('Sin nombre · a1b2c3d4'), findsOneWidget);
      expect(find.byKey(const Key('conversation-unnamed')), findsOneWidget);
      expect(
        find.text(
          'Aún no le has puesto nombre a esta persona. Solo tú lo verás.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('name-unnamed')));
      await tester.pumpAndSettle();
      expect(find.text('Nombre de esta persona'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('local-name')), 'Lucía');
      await tester.tap(find.byKey(const Key('save-local-name')));
      await tester.pumpAndSettle();

      expect(profile.renames, [(lucia, 'Lucía')]);
      expect(find.byKey(const Key('conversation-unnamed')), findsNothing);
      expect(find.text('Lucía'), findsOneWidget);
      expect(find.text('Nombre guardado en este perfil.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a failed save keeps the dialog open and says why', (
    tester,
  ) async {
    final profile = NamingProfile([lucia])..failRename = true;
    await open(tester, profile);
    await tester.tap(find.byKey(const Key('name-unnamed')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('local-name')), 'Lucía');
    await tester.tap(find.byKey(const Key('save-local-name')));
    await tester.pumpAndSettle();
    expect(find.text('Nombre de esta persona'), findsOneWidget);
    expect(find.textContaining('No se pudo guardar el nombre'), findsOneWidget);
    expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
    expect(find.byKey(const Key('conversation-unnamed')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'details name the unnamed and rename the named, starting from their name',
    (tester) async {
      final profile = NamingProfile([lucia, pablo], names: {pablo: 'Pablo'});
      await open(tester, profile);
      // A group with one person unnamed names that person straight away.
      expect(
        find.textContaining(
          'Una persona de esta conversación no tiene nombre.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Detalles de la conversación'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('name-$lucia')), findsOneWidget);
      expect(find.byKey(const Key('rename-$pablo')), findsOneWidget);

      await tester.tap(find.byKey(const Key('rename-$pablo')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const Key('local-name')),
      );
      expect(field.controller!.text, 'Pablo');
      await tester.enterText(find.byKey(const Key('local-name')), 'Pablo G.');
      await tester.tap(find.byKey(const Key('save-local-name')));
      await tester.pumpAndSettle();
      expect(profile.renames, [(pablo, 'Pablo G.')]);
      expect(find.text('Pablo G.'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('several unnamed people are named from the details', (
    tester,
  ) async {
    final profile = NamingProfile([lucia, pablo]);
    await open(tester, profile);
    expect(
      find.textContaining('2 personas de esta conversación no tienen nombre.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Poner nombres'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conversation-details')), findsOneWidget);
    expect(find.byKey(const Key('name-$lucia')), findsOneWidget);
    expect(find.byKey(const Key('name-$pablo')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a new conversation names its people as it is created', (
    tester,
  ) async {
    final profile = NamingProfile(['identity']);
    await open(tester, profile);
    await tester.tap(find.byTooltip('Volver a conversaciones'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Nueva conversación'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('peer-routes')), 'route');
    await tester.tap(find.text('Preparar comparación'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('new-name-identity')), 'Marta');
    await tester.dragUntilVisible(
      find.byKey(const Key('compared-routes')),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.tap(find.byKey(const Key('compared-routes')));
    await tester.pump();
    await tester.dragUntilVisible(
      find.byKey(const Key('create-conversation')),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.tap(find.byKey(const Key('create-conversation')));
    await tester.pumpAndSettle();
    expect(profile.creates, 1);
    expect(profile.renames, [('identity', 'Marta')]);
    expect(find.text('Marta'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('saved contacts without a name read as unnamed', (tester) async {
    final profile = NamingProfile([lucia, pablo], names: {pablo: 'Pablo'});
    await tester.pumpWidget(MaterialApp(home: ContactsPage(profile: profile)));
    await tester.pumpAndSettle();
    expect(find.text('Sin nombre · a1b2c3d4'), findsOneWidget);
    expect(find.text('Pablo'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
