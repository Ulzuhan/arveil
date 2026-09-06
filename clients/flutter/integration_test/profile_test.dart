// M3b.0 acceptance, run on the device: a profile opens with an explicit
// key, answers a query, refuses a second independent open with a typed
// error, and closes so the profile is free again.
import 'dart:io';

import 'package:arveil/src/rust/api/profile.dart';
import 'package:arveil/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => ArveilRust.init());

  test('a profile opens, answers, refuses a second session and closes',
      () async {
    final dir = Directory.systemTemp
        .createTempSync('arveil-m3b0')
        .path;
    const key =
        '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

    final profile = await openProfile(dir: dir, key: key);

    // A query answers across the bridge. A profile with no conversations
    // says so; reading local state does not wait for an enrolled realm.
    expect(await profile.conversations(), isEmpty);

    // History answers in pages, and an unknown conversation is simply
    // empty rather than an error.
    final page = await profile.historyPage(
      groupId: 'aa' * 16,
      before: null,
      limit: 10,
    );
    expect(page.events, isEmpty);
    expect(page.next, isNull);

    // A malformed identifier is a typed domain failure.
    await expectLater(
      profile.historyPage(groupId: 'zz', before: null, limit: 10),
      throwsA(isA<CommandError_Domain>()),
    );

    // A second independent open is a typed refusal, not a silent share.
    await expectLater(
      openProfile(dir: dir, key: key),
      throwsA(isA<ProfileError_AlreadyOpen>()),
    );

    // A key of the wrong shape never reaches storage.
    await expectLater(
      openProfile(dir: dir, key: 'not-hexadecimal'),
      throwsA(isA<ProfileError_BadKey>()),
    );

    // Progress arrives while the work runs, not only when it answers.
    final progress = <ProgressView>[];
    final watching = profile.watch().listen(progress.add);
    await profile.createIdentity();
    // Give the stream a moment to drain; the events were emitted before
    // createIdentity answered.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      progress.map((event) => event.kind).whereType<ProgressKindView_Onboarding>(),
      isNotEmpty,
      reason: 'creating an identity reports its steps',
    );
    expect(progress.first.operation, 'create-identity');
    // The stream is closed from the Rust side, so stop it before
    // cancelling; a cancel alone would wait for a producer that is still
    // waiting for events.
    profile.stopWatching();
    await watching.cancel();

    await profile.close();

    // Closing released it: the same directory opens again, and the wrong
    // key now fails at open rather than at the first command.
    await expectLater(
      openProfile(dir: dir, key: 'ff' * 32),
      throwsA(isA<ProfileError_Unusable>()),
    );
    final reopened = await openProfile(dir: dir, key: key);
    expect(await reopened.conversations(), isEmpty);
    await reopened.close();
  });
}
