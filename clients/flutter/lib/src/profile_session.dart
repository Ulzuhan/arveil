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
  KeyPackageSupplyView? keyPackages;

  /// Linking from the device that holds the root (ADR-012 §3): the code it
  /// shows, the device that answered and waits for a yes, and how it ended.
  LinkOfferView? linkOffer;
  LinkRequestView? linkRequest;
  bool waitingForLink = false;
  bool? linkApproved;

  /// Linking from a new device: the number both screens show, as soon as it
  /// exists, while the other device still has to confirm.
  bool joiningLink = false;
  String? joiningCode;
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
    // A link answered from this screen starts its session inside the wait.
    if (joiningLink && setup?.pairing == null && _profile != null) {
      try {
        setup = await _profile!.setup();
      } catch (_) {}
    }
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

  /// Answer the code an older device shows. Nothing is signed until the
  /// person confirms the number with [answerLink].
  Future<bool> approvePairing(String code) => _run(() async {
    _cancelledWait = false;
    linkApproved = null;
    linkRequest = await _profile!.approvePairing(
      bootstrap: setup!.bootstrap!,
      code: code,
    );
  });

  /// Show a code for a new device to scan or open.
  Future<bool> offerLink() => _run(() async {
    linkApproved = null;
    linkRequest = null;
    linkOffer = await _profile!.offerLink();
  });

  /// Wait for the new device. Leaving the screen or the app may stop the
  /// wait; the offer stays valid and the wait can resume.
  Future<bool> waitForLink() {
    final offer = linkOffer;
    if (offer == null) return Future.value(false);
    return _run(() async {
      waitingForLink = true;
      _changed();
      try {
        linkRequest = await _profile!.awaitLinkRequest(pairId: offer.pairId);
      } finally {
        waitingForLink = false;
      }
    });
  }

  /// The person's answer to the device that asked. Only a yes signs.
  Future<bool> answerLink({required bool approve}) {
    final request = linkRequest;
    if (request == null) return Future.value(false);
    return _run(() async {
      await _profile!.answerLink(pairId: request.pairId, approve: approve);
      linkOffer = null;
      linkRequest = null;
      linkApproved = approve;
    });
  }

  /// Leave linking: an offer nobody answered is withdrawn, a device that
  /// asked and was not confirmed is declined.
  Future<void> closeLink() async {
    final pending = linkRequest?.pairId ?? linkOffer?.pairId;
    linkOffer = null;
    linkRequest = null;
    linkApproved = null;
    _changed();
    if (pending != null && _profile != null) {
      try {
        await _profile!.answerLink(pairId: pending, approve: false);
      } catch (_) {
        // Nothing was signed either way; the other device stops on its own.
      }
    }
  }

  /// On a new device: answer a code the other device shows. [scanned] means
  /// it was read from that screen; a code that crossed another app is also
  /// confirmed here before anything is applied.
  Future<bool> joinLink(String text, {required bool scanned}) => _run(() async {
    final profile = _profile!;
    joiningLink = true;
    joiningCode = null;
    waitingForPairing = true;
    _changed();
    final generation = profile.startWatching();
    final progress = profile.watch(generation: generation).listen((event) {
      if (event.kind case ProgressKindView_PairingVerification(
        :final verificationCode,
      )) {
        joiningCode = verificationCode;
        _changed();
      }
    }, onError: (Object _) {});
    try {
      final description = await describeDevice();
      await _reloadAfter(
        (p) =>
            p.joinLink(text: text, description: description, scanned: scanned),
      );
    } finally {
      profile.stopWatching(generation: generation);
      // The stream ends from the Rust side; nothing here waits for it.
      unawaited(progress.cancel());
      joiningLink = false;
      joiningCode = null;
      waitingForPairing = false;
    }
  });

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
    linkOffer = null;
    linkRequest = null;
    linkApproved = null;
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

/// How this device describes itself to the device that links it, such as
/// "Pixel 8 · Android 15". Shown there, never trusted; absent if unknown.
Future<String?> describeDevice() async {
  const channel = MethodChannel('io.github.ulzuhan.arveil/updates');
  try {
    final data = await channel.invokeMapMethod<String, dynamic>('device');
    if (data == null) return null;
    if (Platform.isAndroid) {
      final model = '${data['model'] ?? ''}'.trim();
      final release = '${data['release'] ?? ''}'.trim();
      if (model.isEmpty) return null;
      return release.isEmpty ? model : '$model · Android $release';
    }
    if (Platform.isMacOS) {
      final version = '${data['osVersion'] ?? ''}'.trim();
      return version.isEmpty ? 'Mac' : 'Mac · macOS $version';
    }
  } catch (_) {
    // A build without the channel describes nothing.
  }
  return null;
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
    CommandError_Domain(operation: 'join-link') => s.errorLinkJoin,
    CommandError_Domain(operation: 'await-link-request') => s.errorLinkExpired,
    CommandError_Domain(operation: 'answer-link') => s.errorLinkExpired,
    CommandError_Domain() => s.errorDomain,
    CommandError_Protocol() => s.errorProtocol,
    // Only pairing has a limit an address can hit on its own, and it clears
    // within the relay's pairing window.
    CommandError_Quota(operation: 'begin-pairing') => s.errorPairingQuota,
    CommandError_Quota(operation: 'offer-link') => s.errorPairingQuota,
    CommandError_Quota() => s.errorQuota,
    CommandError_Busy() => s.errorBusy,
    CommandError_Storage() || CommandError_FileSystem() => s.errorStorage,
    CommandError_Interrupted() => s.errorInterrupted,
    _ => s.errorUnknown,
  };
}
