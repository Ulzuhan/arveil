import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'diagnostics.dart';
import 'profile_keys.dart';
import 'profile_location.dart';
import 'rust/api/profile.dart';

class ProfileAccessException implements Exception {
  const ProfileAccessException(this.message);
  final String message;
}

Future<Profile> openDeviceProfile() async {
  final directory = await ProfileLocation.ensure();
  final key = await ProfileKeys().forProfile(
    profileExists: await hasProfile(dir: directory.path),
  );
  if (key.state == KeyState.unavailable) {
    throw ProfileAccessException(currentStrings.errorSecureStorageUnavailable);
  }
  if (key.state == KeyState.missing) {
    throw ProfileAccessException(currentStrings.errorProfileKeyMissing);
  }
  return openProfile(dir: directory.path, key: key.value!);
}

// Only presentation state lives here. Rust owns identity, enrollment progress
// and the database. Neither invitation tokens nor profile keys are retained.
class ProfileSession extends ChangeNotifier {
  ProfileSession({Future<Profile> Function()? opener})
    : _opener = opener ?? openDeviceProfile;

  final Future<Profile> Function() _opener;
  Profile? _profile;
  SetupView? setup;
  List<ConversationView>? conversations;
  bool busy = false;
  bool _disposed = false;
  String? error;
  bool waitingForPairing = false;

  /// "Más tarde" on the kit reminder hides it until this profile is opened
  /// again; nothing about it is stored.
  bool kitReminderDismissed = false;
  bool cancellingPairing = false;
  bool _cancelledWait = false;
  String? approvalCode;
  KeyPackageSupplyView? keyPackages;
  bool keyPackagesUnavailable = false;

  Profile? get profile => _profile;

  /// Keeps the failure's code for diagnostics and says what happened.
  String _failed(Object failure) {
    FailureLog.record(failure);
    return describeFailure(failure);
  }

  bool get isOpen => _profile != null;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (busy || _disposed) return false;
    busy = true;
    error = null;
    _changed();
    try {
      await action();
      return true;
    } catch (failure) {
      if (!_cancelledWait) error = _failed(failure);
      return false;
    } finally {
      _cancelledWait = false;
      busy = false;
      _changed();
    }
  }

  Future<bool> open() => _run(() async {
    if (_profile != null) return;
    final profile = await _opener();
    var adopted = false;
    try {
      final state = await profile.setup();
      if (_disposed) return;
      _profile = profile;
      setup = state;
      adopted = true;
      await _loadKeyPackages();
    } finally {
      if (!adopted) await profile.close();
    }
  });

  Future<bool> enroll(String bootstrap, String invite) => _run(() async {
    final profile = _profile!;
    try {
      await profile.enroll(bootstrap: bootstrap, invite: invite);
    } finally {
      // Refresh even on a lost reply. Never infer durable progress from a
      // widget or roll it back because the last network request failed.
      try {
        setup = await profile.setup();
        await _loadKeyPackages();
      } catch (_) {
        // A failed query must not hide the original command failure.
        setup = null;
      }
    }
    if (setup == null) {
      throw ProfileAccessException(currentStrings.errorEnrollmentUnreadable);
    }
  });

  Future<void> _reloadAfter(Future<void> Function(Profile) command) async {
    final profile = _profile!;
    try {
      await command(profile);
    } finally {
      try {
        setup = await profile.setup();
        await _loadKeyPackages();
      } catch (_) {
        setup = null;
      }
    }
    if (setup == null) {
      throw ProfileAccessException(currentStrings.errorOperationUnreadable);
    }
  }

  Future<void> _loadKeyPackages() async {
    if (setup?.stage != SetupStage.ready || _profile == null) {
      keyPackages = null;
      return;
    }
    try {
      keyPackages = await _profile!.keyPackageSupply();
    } catch (_) {
      keyPackages = null;
    }
  }

  Future<bool> checkKeyPackages({bool replenish = false}) => _run(() async {
    keyPackagesUnavailable = false;
    try {
      keyPackages = replenish
          ? await _profile!.replenishKeyPackages()
          : await _profile!.checkKeyPackages();
    } catch (_) {
      // Persisted pending publication and the last dated report survive a
      // failed request. Never replace an unknown count with zero.
      keyPackagesUnavailable = true;
      await _loadKeyPackages();
      rethrow;
    }
  });

  Future<bool> beginPairing(String bootstrap) => _run(() async {
    _cancelledWait = false;
    await _reloadAfter((p) => p.beginPairing(bootstrap: bootstrap));
  });

  Future<bool> waitForPairing() => _run(() async {
    final state = setup!;
    waitingForPairing = true;
    _changed();
    try {
      await _reloadAfter(
        (p) => p.awaitPairing(
          bootstrap: state.bootstrap!,
          session: state.pairing!,
        ),
      );
    } finally {
      waitingForPairing = false;
    }
  });

  Future<bool> confirmPairing(String code) => _run(() async {
    _cancelledWait = false;
    final state = setup!;
    await _reloadAfter(
      (p) => p.confirmPairing(
        bootstrap: state.bootstrap!,
        sessionId: state.pairing!.sessionId,
        verificationCode: code,
      ),
    );
  });

  // Cancellation must be able to enter Rust while the rendezvous wait is
  // suspended. It does not promise to undo a confirmation that committed.
  Future<bool> cancelPairing() async {
    final state = setup;
    if (_disposed ||
        cancellingPairing ||
        state?.pairing == null ||
        (busy && !waitingForPairing)) {
      return false;
    }
    cancellingPairing = true;
    _changed();
    try {
      final cancelled = await _profile!.cancelPairing(
        sessionId: state!.pairing!.sessionId,
      );
      _cancelledWait = cancelled && waitingForPairing;
      setup = await _profile!.setup();
      error = cancelled ? null : currentStrings.pairingConfirmationStarted;
      return cancelled;
    } catch (failure) {
      error = _failed(failure);
      return false;
    } finally {
      cancellingPairing = false;
      _changed();
    }
  }

  Future<bool> approvePairing(String code) => _run(() async {
    _cancelledWait = false;
    approvalCode = await _profile!.approvePairing(
      bootstrap: setup!.bootstrap!,
      code: code,
    );
  });

  void dismissApproval() {
    approvalCode = null;
    _changed();
  }

  Future<String?> saveKit(Future<bool> Function(List<int>) save) async {
    String? secret;
    await _run(() async {
      _cancelledWait = false;
      final kit = await _profile!.exportKit();
      if (await save(kit.encrypted) && !_disposed) secret = kit.secret;
    });
    return secret;
  }

  /// Record that the user saved the last kit and keeps its key apart, then
  /// read the setup again so the kit reminder reflects it.
  Future<bool> confirmKitSaved() =>
      _run(() => _reloadAfter((p) => p.confirmKitSaved()));

  Future<bool> restoreKit(
    String bootstrap,
    List<int> encrypted,
    String secret,
  ) => _run(() async {
    _cancelledWait = false;
    await _reloadAfter(
      (p) => p.restoreKit(
        bootstrap: bootstrap,
        encrypted: encrypted,
        secret: secret,
      ),
    );
  });

  Future<bool> resumeRecovery() => _run(() async {
    _cancelledWait = false;
    await _reloadAfter((p) => p.resumeRecovery());
  });

  void reportFailure(Object failure) {
    error = _failed(failure);
    _changed();
  }

  Future<bool> refresh() => _run(() async {
    _cancelledWait = false;
    setup = await _profile!.setup();
    if (setup!.stage == SetupStage.ready) {
      conversations = await _profile!.conversations();
    }
  });

  Future<bool> close() => _run(() async {
    await _profile?.close();
    _profile = null;
    setup = null;
    conversations = null;
    keyPackages = null;
    keyPackagesUnavailable = false;
    approvalCode = null;
    _cancelledWait = false;
  });

  @override
  void dispose() {
    _disposed = true;
    final profile = _profile;
    _profile = null;
    if (profile != null) unawaited(profile.close().catchError((Object _) {}));
    super.dispose();
  }
}

// Public-facing messages never interpolate paths, tokens, SQL or remote text.
String describeFailure(Object failure) {
  final s = currentStrings;
  return switch (failure) {
    ProfileAccessException(:final message) => message,
    ProfileError_BadKey() => s.errorBadKey,
    ProfileError_NoRandomness() => s.errorNoRandomness,
    ProfileError_AlreadyOpen() || ProfileError_InUse() => s.errorProfileInUse,
    ProfileError_Closing() => s.errorProfileClosing,
    ProfileError_TooNew() => s.errorProfileTooNew,
    ProfileError_Unusable() => s.errorProfileUnusable,
    ProfileError_Io() || FileSystemException() => s.errorProfileIo,
    PlatformException() => s.errorSecureStoragePrepare,
    CommandError_Transport() => s.errorTransport,
    // Pairing refusals mostly mean the other device was not listening or
    // the code ran out; the generic advice is about enrollment.
    CommandError_Domain(operation: 'approve-pairing') => s.errorPairingNoAnswer,
    CommandError_Domain(operation: 'await-pairing') => s.errorPairingExpired,
    CommandError_Domain() => s.errorDomain,
    CommandError_Protocol() => s.errorProtocol,
    // Only pairing has a limit an address can hit on its own, and it clears
    // within the relay's pairing window.
    CommandError_Quota(operation: 'begin-pairing') => s.errorPairingQuota,
    CommandError_Quota() => s.errorQuota,
    CommandError_Busy() => s.errorBusy,
    CommandError_Storage() || CommandError_FileSystem() => s.errorStorage,
    CommandError_Interrupted() => s.errorInterrupted,
    _ => s.errorUnknown,
  };
}
