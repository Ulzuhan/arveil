// M3b.1 acceptance for the profile key, on the device.
//
// Three of the four situations can be checked here: a first install, a
// second start, and a key that has gone missing. The fourth — reinstalling
// and restoring — cannot be staged from inside the application, and is
// written down as a manual check in docs/PLATFORMS.md instead of being
// assumed.
import 'dart:io';

import 'package:arveil/src/profile_keys.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:arveil/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => ArveilRust.init());

  test('the platform keeps the key, and its absence is said out loud',
      () async {
    final dir = Directory.systemTemp.createTempSync('arveil-key').path;
    final keys = ProfileKeys(keyName: 'test-profile-key');
    addTearDown(keys.forget);

    // A first install: no key, no profile, so one is made and kept.
    await keys.forget();
    final probe = await keys.forProfile(profileExists: false);
    if (probe.state == KeyState.unavailable) {
      // macOS without a signing identity cannot reach the Keychain at all.
      // That is a packaging decision, recorded in docs/PLATFORMS.md; there
      // is nothing to test here until it is made.
      markTestSkipped('this platform has no key store for an unsigned build');
      return;
    }
    await keys.forget();
    expect(await hasProfile(dir: dir), isFalse);
    final first = await keys.forProfile(profileExists: false);
    expect(first.state, KeyState.fresh);
    expect(first.value, hasLength(64));

    final profile = await openProfile(dir: dir, key: first.value!);
    await profile.close();
    expect(await hasProfile(dir: dir), isTrue);

    // A second start: the same key comes back, and nothing is generated.
    final second = await keys.forProfile(profileExists: true);
    expect(second.state, KeyState.present);
    expect(second.value, first.value);
    final reopened = await openProfile(dir: dir, key: second.value!);
    await reopened.close();

    // The key is gone but the profile is not. This must be said, not
    // papered over with a new key that would answer "nothing here" to
    // someone whose history is on disk.
    await keys.forget();
    final gone = await keys.forProfile(profileExists: true);
    expect(gone.state, KeyState.missing);
    expect(gone.value, isNull);

    // And the profile really is unreadable without it.
    final other = await generateProfileKey();
    await expectLater(
      openProfile(dir: dir, key: other),
      throwsA(isA<ProfileError_Unusable>()),
    );

    // Put it back and the profile opens again: the data was never the
    // problem, only the key.
    final restored = ProfileKeys(keyName: 'test-profile-key');
    final rewritten = await restored.forProfile(profileExists: false);
    expect(rewritten.state, KeyState.fresh);
    await expectLater(
      openProfile(dir: dir, key: rewritten.value!),
      throwsA(isA<ProfileError_Unusable>()),
      reason: 'a different key does not open an existing profile',
    );
  });
}
