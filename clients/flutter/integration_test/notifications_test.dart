import 'dart:convert';
import 'dart:io';
import 'package:arveil/src/profile_keys.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:arveil/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const bootstrap = String.fromEnvironment('ARVEIL_TEST_BOOTSTRAP');
  const inviteA = String.fromEnvironment('ARVEIL_TEST_INVITE_A');
  const inviteB = String.fromEnvironment('ARVEIL_TEST_INVITE_B');
  const control = String.fromEnvironment('ARVEIL_TEST_CONTROL');
  const token = String.fromEnvironment('ARVEIL_TEST_CONTROL_TOKEN');
  setUpAll(() async => ArveilRust.init());
  testWidgets('profile executor registers, rotates and clears generic hints', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('arveil-notifications-');
    final keys = [
      for (var n = 0; n < 2; n++)
        ProfileKeys(
          keyName: 'test-push-$n-${DateTime.now().microsecondsSinceEpoch}',
        ),
    ];
    Future<Profile> open(int n) async {
      final dir = await Directory('${root.path}/$n').create();
      final key = await keys[n].forProfile(
        profileExists: await hasProfile(dir: dir.path),
      );
      return openProfile(dir: dir.path, key: key.value!);
    }

    var alice = await open(0);
    final bob = await open(1);
    addTearDown(() async {
      await alice.close();
      await bob.close();
      for (final key in keys) {
        await key.forget();
      }
      await root.delete(recursive: true);
    });
    await alice.enroll(bootstrap: bootstrap, invite: inviteA);
    await bob.enroll(bootstrap: bootstrap, invite: inviteB);
    final conversation = await bob.createConversation(
      bootstrap: bootstrap,
      routes: [await alice.ownRoute()],
      safetyNumbers: [null],
    );
    await alice.sync_(bootstrap: bootstrap);
    Future<List<dynamic>> hints() async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse('$control/hints'));
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        final response = await request.close();
        expect(response.statusCode, 200);
        return jsonDecode(await utf8.decoder.bind(response).join())
            as List<dynamic>;
      } finally {
        client.close(force: true);
      }
    }

    Future<void> send(String text) async {
      await bob.queueMessage(groupId: conversation.groupId, text: text);
      await bob.sync_(bootstrap: bootstrap);
    }

    Future<List<dynamic>> count(int n) async {
      for (var i = 0; i < 50; i++) {
        final rows = await hints();
        if (rows.length == n) return rows;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError('Expected generic hint did not arrive');
    }

    await alice.setNotificationHint(endpoint: '$control/hint/$token');
    await send('synthetic one');
    expect((await count(1)).single['body'], 'arveil-hint/v1');
    await alice.close();
    alice = await open(0);
    await alice.sync_(bootstrap: bootstrap);
    await alice.setNotificationHint(endpoint: '$control/hint/$token/rotated');
    await send('synthetic two');
    expect((await count(2)).last['rotated'], true);
    await alice.setNotificationHint(endpoint: '');
    await alice.sync_(bootstrap: bootstrap);
    await send('synthetic three');
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(await hints(), hasLength(2));
  });
}
