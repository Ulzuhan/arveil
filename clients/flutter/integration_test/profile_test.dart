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

    // A query answers across the bridge, and a fresh profile has no device
    // yet, so it answers with a category rather than a message to parse.
    await expectLater(
      profile.conversations(),
      throwsA(isA<CommandError_Domain>()
          .having((e) => e.operation, 'operation', 'query-conversations')),
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

    await profile.close();

    // Closing released it: the same directory opens again, and the wrong
    // key now fails at open rather than at the first command.
    await expectLater(
      openProfile(dir: dir, key: 'ff' * 32),
      throwsA(isA<ProfileError_Unusable>()),
    );
    final reopened = await openProfile(dir: dir, key: key);
    await expectLater(
      reopened.conversations(),
      throwsA(isA<CommandError_Domain>()),
    );
    await reopened.close();
  });
}
