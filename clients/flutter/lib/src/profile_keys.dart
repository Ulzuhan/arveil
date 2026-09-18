// The key that opens a profile: random, kept by the platform, and never
// derived from anything the user types.
//
// Three different things are deliberately kept apart here:
//
//  * this file protects the *local profile* — losing the key loses local
//    history, and nothing here recovers it;
//  * the identity kit recovers an *identity*, not conversations and not MLS
//    state;
//  * recovering *history* will be an explicit encrypted export, imported
//    into a new profile under a new local key. That is a later milestone,
//    and it needs nothing from this file, which is why the profile key is
//    free to be unrecoverable.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'rust/api/profile.dart';

/// What the store had to say about a profile's key.
enum KeyState {
  /// A key was there and the profile can be opened.
  present,

  /// No key, and no profile either: this device is starting fresh.
  fresh,

  /// A profile exists but its key is gone. Nothing here can open it, and
  /// nothing here will quietly replace it with a new one.
  missing,

  /// The platform refused access. Never falls back to a plaintext key.
  unavailable,
}

class ProfileKey {
  const ProfileKey(this.state, this.value);

  final KeyState state;

  /// Present exactly when the profile can be opened.
  final String? value;
}

class ProfileKeys {
  ProfileKeys({FlutterSecureStorage? storage, String? keyName})
    : _keyName = keyName ?? _defaultKeyName,
      _storage =
          storage ??
          const FlutterSecureStorage(
            // iOS uses the device-bound Data Protection Keychain.
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
            mOptions: MacOsOptions(
              // The login Keychain works with ad-hoc macOS builds. Its
              // access-control prompts apply; it does not provide iOS's
              // device-bound protection. This is an explicit backend,
              // never a fallback after a Data Protection access failure.
              usesDataProtectionKeychain: false,
              accountName: 'io.github.ulzuhan.arveil.profile-keys',
              synchronizable: false,
            ),
            // The Android entry is wrapped by a Keystore key, which is
            // what keeps it out of a copied file, and it is not carried
            // into a backup: uninstalling takes the key with it, which is
            // the behaviour this design wants.
            aOptions: AndroidOptions(migrateWithBackup: false),
          );

  final FlutterSecureStorage _storage;

  /// Named so a test can keep its own entry out of the real one.
  final String _keyName;

  static const _defaultKeyName = 'profile-key-v1';

  // Every caller in the UI isolate shares this queue, including callers
  // that construct separate ProfileKeys objects. Protect read/generate/write
  // as one operation: the secure store's individual calls are not a lock.
  static final Map<String, Future<void>> _pending = {};

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    final previous = _pending[_keyName] ?? Future<void>.value();
    final done = Completer<void>();
    _pending[_keyName] = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
      if (identical(_pending[_keyName], done.future)) {
        _pending.remove(_keyName);
      }
    }
  }

  /// Read the key for a profile that already exists, or make one for a
  /// profile that does not. Never invents a key for a profile that has one
  /// on disk: that would answer "empty" to someone whose history is right
  /// there, unreadable.
  Future<ProfileKey> forProfile({required bool profileExists}) =>
      _exclusive(() => _forProfile(profileExists: profileExists));

  Future<ProfileKey> _forProfile({required bool profileExists}) async {
    final String? stored;
    try {
      stored = await _storage.read(key: _keyName);
    } on PlatformException {
      return const ProfileKey(KeyState.unavailable, null);
    }
    if (stored != null) {
      return ProfileKey(KeyState.present, stored);
    }
    if (profileExists) {
      return const ProfileKey(KeyState.missing, null);
    }
    // Generated in Rust: same generator as the rest of the client, and a
    // failure there is a failure here rather than something weaker.
    final fresh = await generateProfileKey();
    try {
      await _storage.write(key: _keyName, value: fresh);
      // Do not create an encrypted profile until its key can be retrieved.
      if (await _storage.read(key: _keyName) != fresh) {
        return const ProfileKey(KeyState.unavailable, null);
      }
    } on PlatformException {
      return const ProfileKey(KeyState.unavailable, null);
    }
    return ProfileKey(KeyState.fresh, fresh);
  }

  /// Forget the key. The profile stays on disk and stays unreadable, which
  /// is the point: this is not a delete.
  Future<void> forget() => _exclusive(_forget);

  Future<void> _forget() async {
    try {
      await _storage.delete(key: _keyName);
    } on PlatformException {
      // Nothing was ever stored on a platform that refuses to store.
    }
  }
}
