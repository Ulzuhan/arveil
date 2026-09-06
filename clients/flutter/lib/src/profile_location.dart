// Where the profile lives, and keeping it out of the platform's backups.
//
// Excluding it is not encryption and does not replace it: it keeps the
// encrypted database from travelling to a cloud account whose protection
// nobody here controls. The cost is stated plainly in the documentation:
// losing the device loses local history, and the identity kit brings back
// an identity, not conversations.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class ProfileLocation {
  static const _channel = MethodChannel('arveil/profile');

  /// The directory this device keeps its profile in, created if needed and
  /// excluded from backups where the platform lets us say so.
  static Future<Directory> ensure() async {
    final support = await getApplicationSupportDirectory();
    final profile = Directory('${support.path}/profile');
    if (!profile.existsSync()) {
      profile.createSync(recursive: true);
    }
    await excludeFromBackup(profile);
    return profile;
  }

  /// Ask the platform to keep this path out of its backups. Reapplied on
  /// every start: an attribute set once does not survive a directory being
  /// replaced. Android says nothing here because it is settled in the
  /// manifest instead.
  static Future<void> excludeFromBackup(Directory directory) async {
    if (!Platform.isMacOS && !Platform.isIOS) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('excludeFromBackup', directory.path);
    } on PlatformException {
      // Reported, not fatal: a profile that is backed up is worse than one
      // that is not, but refusing to start would be worse than both.
      // The caller decides what to tell the user.
      rethrow;
    }
  }
}
