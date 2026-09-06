// A deliberately small surface for M3b.1: the profile opens with a key the
// platform keeps, answers a query, and closes. Screens belong to M3b.2 and
// later.
import 'package:flutter/material.dart';

import 'src/profile_keys.dart';
import 'src/profile_location.dart';
import 'src/rust/api/profile.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  await ArveilRust.init();
  runApp(const ArveilApp());
}

class ArveilApp extends StatelessWidget {
  const ArveilApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Arveil',
        theme: ThemeData(colorSchemeSeed: Colors.teal),
        home: const ProfilePage(),
      );
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  Profile? _profile;
  String _status = 'no profile open';

  Future<void> _open() async {
    try {
      final directory = await ProfileLocation.ensure();
      final key = await ProfileKeys().forProfile(
        profileExists: await hasProfile(dir: directory.path),
      );
      if (key.state == KeyState.unavailable) {
        setState(() => _status =
            'this build cannot keep a key: it needs a signing identity');
        return;
      }
      if (key.value == null) {
        // The profile is there and its key is not. Saying so is the whole
        // job: a new key here would answer "no conversations" to someone
        // whose history is on disk, unreadable.
        setState(() => _status =
            'the key for this profile is gone; its history cannot be read');
        return;
      }
      final profile = await openProfile(dir: directory.path, key: key.value!);
      setState(() {
        _profile = profile;
        _status = switch (key.state) {
          KeyState.fresh => 'new profile, key stored by the system',
          KeyState.present => 'open',
          KeyState.missing => 'open',
          KeyState.unavailable => 'open',
        };
      });
    } on ProfileError catch (error) {
      setState(() => _status = describe(error));
    }
  }

  Future<void> _list() async {
    final profile = _profile;
    if (profile == null) return;
    try {
      final conversations = await profile.conversations();
      setState(() => _status = '${conversations.length} conversations');
    } on CommandError catch (error) {
      setState(() => _status = 'query failed: $error');
    }
  }

  Future<void> _close() async {
    await _profile?.close();
    setState(() {
      _profile = null;
      _status = 'closed';
    });
  }

  /// The category comes from the sealed type, never from the message.
  static String describe(ProfileError error) => switch (error) {
        ProfileError_BadKey() => 'the key is not 64 hexadecimal characters',
        ProfileError_NoRandomness() => 'the system would not produce a key',
        ProfileError_AlreadyOpen(:final path) => 'already open here: $path',
        ProfileError_Closing(:final path) => 'still closing: $path',
        ProfileError_InUse(:final path) => 'another process holds it: $path',
        ProfileError_Unusable(:final reason) => 'did not open: $reason',
        ProfileError_Io(:final reason) => 'directory problem: $reason',
      };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Arveil')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 12,
            children: [
              Text(_status, key: const Key('status')),
              FilledButton(onPressed: _open, child: const Text('Open')),
              FilledButton(onPressed: _list, child: const Text('Conversations')),
              FilledButton(onPressed: _close, child: const Text('Close')),
            ],
          ),
        ),
      );
}
