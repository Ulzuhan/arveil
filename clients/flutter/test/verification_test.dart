import 'package:arveil/src/design/design.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'conversations_test.dart' show ChatProfile;
import 'names_test.dart' show lucia, open, pablo;

const number = '12345 67890 13579 24680 11223 34455 66778 89900';

/// A conversation whose people can be verified from its details.
class VerifyingProfile extends ChatProfile {
  VerifyingProfile(this.people, {Set<String>? verified})
    : verified = {...?verified};
  final List<String> people;
  final Set<String> verified;
  final verifications = <(String, String)>[];
  bool failVerify = false;

  @override
  Future<List<ConversationView>> conversations() async => [
    ConversationView(
      groupId: 'group-a',
      creator: false,
      peerDevices: people.length,
      peers: [
        for (final p in people)
          PeerView(
            identityId: p,
            deviceId: 'device-$p',
            label: p.substring(0, 8),
            named: false,
            own: false,
            verified: verified.contains(p),
            safetyNumber: number,
            revoked: false,
          ),
      ],
      eventCount: 1,
      unread: 0,
      lastActivity: 0,
    ),
  ];

  @override
  Future<ContactView> verifyContact({
    required String identityId,
    required String safetyNumber,
  }) async {
    if (failVerify) {
      throw const CommandError.storage(
        operation: 'verify-contact',
        reason: 'PRIVATE_DIAGNOSTIC',
      );
    }
    verifications.add((identityId, safetyNumber));
    verified.add(identityId);
    return ContactView(
      accepted: true,
      identityId: identityId,
      label: identityId.substring(0, 8),
      verified: true,
      safetyNumber: safetyNumber,
      devices: const [],
    );
  }
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'someone unverified is pointed out without blocking, and verified from the details',
    (tester) async {
      final profile = VerifyingProfile([lucia]);
      await open(tester, profile);
      // A line under the name, not a dialog: the composer stays usable.
      expect(find.text('Sin verificar · Verificar'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message-draft')))
            .enabled,
        isNot(false),
      );
      // The name prompt is still there, once.
      expect(find.byKey(const Key('conversation-unnamed')), findsOneWidget);

      await tap(tester, find.byKey(const Key('conversation-header')));
      expect(find.byKey(const Key('conversation-details')), findsOneWidget);
      expect(
        tester
            .widget<SafetyNumberGrid>(find.byKey(const Key('safety-$lucia')))
            .number,
        number,
      );
      await tap(tester, find.byKey(const Key('verify-$lucia')));
      expect(profile.verifications, [(lucia, number)]);
      expect(find.byKey(const Key('compare-$lucia')), findsNothing);
      expect(find.text('Verificado · 1 dispositivo'), findsOneWidget);

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.text('Verificado'), findsOneWidget);
      expect(find.textContaining('Verificar'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('numbers that differ verify nothing and say what to do', (
    tester,
  ) async {
    final profile = VerifyingProfile([lucia]);
    await open(tester, profile);
    await tap(tester, find.byTooltip('Detalles de la conversación'));
    await tap(tester, find.byKey(const Key('differ-$lucia')));
    expect(find.byKey(const Key('mismatch-$lucia')), findsOneWidget);
    expect(
      find.textContaining('No verifiques a esta persona.'),
      findsOneWidget,
    );
    expect(profile.verifications, isEmpty);
    expect(find.byKey(const Key('compare-$lucia')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a verification that fails says so and leaves them unverified', (
    tester,
  ) async {
    final profile = VerifyingProfile([lucia])..failVerify = true;
    await open(tester, profile);
    await tap(tester, find.byKey(const Key('conversation-header')));
    await tap(tester, find.byKey(const Key('verify-$lucia')));
    expect(
      find.text('No se pudo guardar la verificación. Vuelve a intentarlo.'),
      findsOneWidget,
    );
    expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
    expect(find.byKey(const Key('compare-$lucia')), findsOneWidget);
    expect(find.text('Sin verificar · 1 dispositivo'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a group counts who is unverified and compares only with them', (
    tester,
  ) async {
    final profile = VerifyingProfile([lucia, pablo], verified: {pablo});
    await open(tester, profile);
    expect(find.text('1 sin verificar · Verificar'), findsOneWidget);
    await tap(tester, find.byKey(const Key('conversation-header')));
    expect(find.byKey(const Key('compare-$lucia')), findsOneWidget);
    expect(find.byKey(const Key('compare-$pablo')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('everyone verified reads as before, with no prompt', (
    tester,
  ) async {
    final profile = VerifyingProfile([lucia, pablo], verified: {lucia, pablo});
    await open(tester, profile);
    expect(find.text('2 personas'), findsOneWidget);
    expect(find.textContaining('Verificar'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('beside a wide conversation the header opens the details once', (
    tester,
  ) async {
    final profile = VerifyingProfile([lucia]);
    await open(tester, profile, size: const Size(1280, 800));
    final header = find.byKey(const Key('conversation-header'));
    await tap(tester, header);
    expect(find.byKey(const Key('conversation-details')), findsOneWidget);
    await tap(tester, header);
    expect(find.byKey(const Key('conversation-details')), findsOneWidget);
    await tap(tester, find.byKey(const Key('verify-$lucia')));
    expect(profile.verifications, [(lucia, number)]);
    expect(find.text('Verificado · 1 dispositivo'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
