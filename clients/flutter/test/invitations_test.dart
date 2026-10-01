import 'dart:async';
import 'dart:typed_data';
import 'package:arveil/main.dart';
import 'package:arveil/src/invitations_page.dart';
import 'package:arveil/src/incoming_links.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' show FakeProfile;

const personalLink = 'https://arveil.example/join#PRIVATE_FIXTURE_TOKEN';
InvitationView row(String state, {String? link}) => InvitationView(
  id: Uint8List.fromList([1, 2]),
  state: state,
  createdAt: 1800000000,
  expiresAt: 1800604800,
  checkedAt: 1800000000,
  groupId: state == 'complete' ? 'chat-one' : '',
  link: link,
  name: 'Ana',
);

class InvitingProfile extends FakeProfile {
  bool owner = false;
  InvitationView? pendingInvite;
  List<InvitationView> rows = [];
  int accepts = 0, creates = 0;
  bool fail = false;
  Completer<void>? accepting;
  @override
  Future<String?> cardName() async => null;
  @override
  Future<InvitationView?> pendingInvitation() async => pendingInvite;
  @override
  Future<CardView> readCard({required String text}) async =>
      CardView.invitation(
        name: 'Ana',
        server: 'wss://relay.example',
        expiresAt: BigInt.from(1800604800),
      );
  @override
  Future<bool> invitationPolicy() async => owner;
  @override
  Future<List<InvitationView>> invitations({required bool refresh}) async =>
      rows;
  @override
  Future<InvitationView> createInvitation({Uint8List? id}) async {
    creates++;
    return row('pending', link: personalLink);
  }

  @override
  Future<InvitationView> acceptInvitation({String? text, String? name}) async {
    accepts++;
    pendingInvite = row('enrolled');
    await accepting?.future;
    if (fail) throw InvitationProblem.offline;
    pendingInvite = null;
    return row('complete');
  }
}

void main() {
  test(
    'a finished preview can reopen while duplicate active links coalesce',
    () {
      final links = IncomingLinks();
      var notices = 0;
      links.addListener(() => notices++);
      links.receive(personalLink);
      expect(links.take(), personalLink);
      links.receive(personalLink); // duplicate callback from a cold start
      expect(links.pending, isNull);
      expect(notices, 1);
      links.finished(personalLink);
      links.receive(personalLink); // an explicit retry after closing preview
      expect(links.take(), personalLink);
      const next = 'https://arveil.example/join#SECOND_PRIVATE_FIXTURE';
      links.receive(next);
      links.finished(
        personalLink,
      ); // finishing the old screen keeps the new link
      expect(links.take(), next);
      links.dispose();
    },
  );
  testWidgets(
    'preview is local, explicit consent disables duplicate taps, errors reveal no link',
    (t) async {
      final p = InvitingProfile()
        ..fail = true
        ..accepting = Completer<void>();
      await t.pumpWidget(
        MaterialApp(
          home: AcceptInvitationPage(profile: p, text: personalLink),
        ),
      );
      await t.pumpAndSettle();
      expect(p.accepts, 0);
      expect(find.textContaining('Ana te invita'), findsOneWidget);
      expect(find.textContaining('Escanearlo no verifica'), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('invite-accept')));
      await t.pumpAndSettle();
      await t.drag(find.byType(ListView), const Offset(0, -200));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('invite-accept')));
      await t.pump();
      expect(
        t
            .widget<FilledButton>(find.byKey(const Key('invite-accept')))
            .onPressed,
        isNull,
      );
      p.accepting!.complete();
      await t.pumpAndSettle();
      expect(p.accepts, 1);
      expect(find.textContaining('No se pudo conectar'), findsOneWidget);
      expect(find.textContaining('PRIVATE_FIXTURE'), findsNothing);
      expect(find.text('Continuar invitación'), findsOneWidget);
    },
  );
  testWidgets(
    'reopen finds a saved operation without pasting its token again',
    (t) async {
      final p = InvitingProfile()..pendingInvite = row('enrolled');
      final s = ProfileSession(opener: () async => p);
      addTearDown(s.dispose);
      await t.pumpWidget(ArveilApp(session: s));
      await t.tap(find.text('Abrir perfil'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('invite-resume')), findsOneWidget);
      expect(p.accepts, 0);
      await t.tap(find.byKey(const Key('invite-resume')));
      await t.pumpAndSettle();
      expect(find.textContaining('El progreso está guardado'), findsOneWidget);
      expect(p.accepts, 0, reason: 'resuming still requires a tap');
    },
  );
  testWidgets('a member sees the permission explanation and cannot issue', (
    t,
  ) async {
    final p = InvitingProfile();
    await t.pumpWidget(MaterialApp(home: InvitationsPage(profile: p)));
    await t.pumpAndSettle();
    expect(find.textContaining('no tiene permiso'), findsOneWidget);
    expect(
      t.widget<FilledButton>(find.byKey(const Key('invite-create'))).onPressed,
      isNull,
    );
    expect(p.creates, 0);
  });
  testWidgets('other device metadata cannot share a missing secret', (t) async {
    final p = InvitingProfile()
      ..owner = true
      ..rows = [row('pending')];
    await t.pumpWidget(MaterialApp(home: InvitationsPage(profile: p)));
    await t.pumpAndSettle();
    await t.ensureVisible(find.textContaining('otro dispositivo tuyo'));
    expect(find.textContaining('otro dispositivo tuyo'), findsOneWidget);
    expect(find.text('Mostrar código o compartir'), findsNothing);
    expect(find.text('Revocar'), findsOneWidget);
  });
}
