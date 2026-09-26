import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'manifest.dart';
import 'transport.dart';

abstract interface class UpdateStore {
  Future<String?> read();
  Future<void> write(String data);
}

class FileUpdateStore implements UpdateStore {
  FileUpdateStore(this.directory);
  final Directory directory;
  File get _file => File('${directory.path}/updates.json');
  @override
  Future<String?> read() async {
    try {
      return await _file.readAsString();
    } on FileSystemException catch (error) {
      // Only ENOENT means a first installation. Permission/I/O errors must
      // never be interpreted as an empty rollback history.
      if (error.osError?.errorCode == 2) return null;
      rethrow;
    }
  }

  @override
  Future<void> write(String data) async {
    await directory.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(data, flush: true);
    await temporary.rename(_file.path);
  }
}

abstract interface class UpdateInstaller {
  Future<UpdateDevice> device();
  Future<bool> allowed();
  Future<void> requestPermission();
  Future<void> install(File apk, AndroidUpdate update);

  /// Opens the signed release notes link in the browser.
  Future<void> open(Uri url);
}

class AndroidUpdateInstaller implements UpdateInstaller {
  static const _channel = MethodChannel('io.github.ulzuhan.arveil/updates');
  @override
  Future<UpdateDevice> device() async {
    final data = (await _channel.invokeMapMethod<String, dynamic>('device'))!;
    return UpdateDevice(
      build: data['build'] as int,
      sdk: data['sdk'] as int,
      applicationId: data['applicationId'] as String,
      arm64: data['arm64'] as bool,
    );
  }

  @override
  Future<bool> allowed() async =>
      (await _channel.invokeMethod<bool>('allowed'))!;
  @override
  Future<void> requestPermission() => _channel.invokeMethod('permission');
  @override
  Future<void> install(File apk, AndroidUpdate update) =>
      _channel.invokeMethod('install', {
        'path': apk.path,
        'build': update.build,
        'size': update.size,
        'sha256': update.sha256,
      });
  @override
  Future<void> open(Uri url) =>
      _channel.invokeMethod('open', {'url': url.toString()});
}

/// The Mac app's side: it reads its build and opens links, and never
/// installs; the person downloads the new version and replaces the app.
class MacUpdateNotifier implements UpdateInstaller {
  static const _channel = MethodChannel('io.github.ulzuhan.arveil/updates');
  @override
  Future<UpdateDevice> device() async {
    final data = (await _channel.invokeMapMethod<String, dynamic>('device'))!;
    return UpdateDevice(
      build: data['build'] as int,
      sdk: 0,
      applicationId: data['applicationId'] as String,
      arm64: data['arm64'] as bool,
      osVersion: data['osVersion'] as String,
    );
  }

  @override
  Future<bool> allowed() async => false;
  @override
  Future<void> requestPermission() async {}
  @override
  Future<void> install(File apk, AndroidUpdate update) =>
      throw UnsupportedError('The Mac app does not install updates');
  @override
  Future<void> open(Uri url) =>
      _channel.invokeMethod('open', {'url': url.toString()});
}

enum UpdatePhase {
  idle,
  checking,
  current,
  available,
  downloading,
  ready,
  installing,
  incompatible,
}

/// Global to this installation; never depends on the relay or profile keys.
class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.config,
    required this.store,
    required this.transport,
    required this.installer,
    required this.verifier,
    this.notifyOnly = false,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final UpdateConfig? config;

  /// On the Mac the controller checks, verifies and offers, and the offer
  /// opens the download in the browser; it never downloads or installs.
  final bool notifyOnly;
  final UpdateSignatureVerifier verifier;
  final UpdateStore store;
  final UpdateTransport transport;
  final UpdateInstaller installer;
  final DateTime Function() now;
  bool automatic = false;
  DateTime? lastAttempt;

  /// Rollback history per update identity: the public key and the channel.
  /// A build with another key or channel starts its own history at zero
  /// instead of treating the other one as damage. Sequences under another
  /// key or channel are not comparable, and changing either already takes a
  /// build signed with the Android key; blocking there only left the person
  /// with clearing the app's data, which deletes the encrypted profile.
  final Map<String, ({int sequence, String? digest})> _histories = {};
  bool _stateFailed = false;
  bool _busy = false;
  bool _disposed = false;
  bool _cancelled = false;
  String? error;
  UpdatePhase phase = UpdatePhase.idle;
  UpdateDevice? device;
  UpdateManifest? manifest;
  File? _apk;
  int received = 0;
  int _percent = -1;
  bool needsPermission = false;

  bool get configured => config != null;
  bool get busy => _busy;
  bool get available =>
      manifest != null &&
      [
        UpdatePhase.available,
        UpdatePhase.downloading,
        UpdatePhase.ready,
        UpdatePhase.installing,
      ].contains(phase);
  String get _identity => sha256.convert([
    ...config!.publicKey,
    ...utf8.encode(config!.channel),
  ]).toString();
  int get _sequence => _histories[_identity]?.sequence ?? 0;
  String? get _digest => _histories[_identity]?.digest;

  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  Future<void> load() async {
    // Nothing is downloading yet in a new process, so a package still here
    // was installed already or is from a run that ended before installing.
    try {
      await transport.discard();
    } catch (_) {
      // The cache may be cleared by Android as well; never block startup.
    }
    if (!configured) return;
    try {
      final raw = await store.read();
      if (raw != null) _restore(jsonDecode(raw));
    } catch (_) {
      // Do not silently erase rollback protection after a damaged/failed read.
      _stateFailed = true;
      error = 'state';
    }
  }

  void _restore(Object? data) {
    if (data is! Map || data['automatic'] is! bool) {
      throw const UpdateFailure('state');
    }
    final histories = <String, ({int sequence, String? digest})>{};
    switch (data['schema']) {
      case 1:
        // Builds up to 0.1.0+18 kept a single history at the top level.
        final identity = data['identity'];
        if (identity is! String || !_hex64.hasMatch(identity)) {
          throw const UpdateFailure('state');
        }
        histories[identity] = _history(data['sequence'], data['digest']);
      case 2:
        final stored = data['feeds'];
        if (stored is! Map) throw const UpdateFailure('state');
        for (final MapEntry(:key, :value) in stored.entries) {
          if (key is! String || !_hex64.hasMatch(key) || value is! Map) {
            throw const UpdateFailure('state');
          }
          histories[key] = _history(value['sequence'], value['digest']);
        }
      default:
        throw const UpdateFailure('state');
    }
    DateTime? attempt;
    final stamp = data['lastAttempt'];
    if (stamp != null) {
      if (stamp is! String) throw const UpdateFailure('state');
      attempt = DateTime.parse(stamp);
      if (!attempt.isUtc) throw const UpdateFailure('state');
    }
    automatic = data['automatic'] as bool;
    lastAttempt = attempt;
    _histories
      ..clear()
      ..addAll(histories);
  }

  static ({int sequence, String? digest}) _history(
    Object? sequence,
    Object? digest,
  ) {
    if (sequence is! int ||
        sequence < 0 ||
        sequence > 9007199254740991 ||
        (sequence == 0
            ? digest != null
            : digest is! String || !_hex64.hasMatch(digest))) {
      throw const UpdateFailure('state');
    }
    return (sequence: sequence, digest: digest as String?);
  }

  Future<void> _save({
    bool? enabled,
    DateTime? attempt,
    UpdateManifest? accepted,
  }) async {
    final histories = {
      ..._histories,
      if (accepted != null)
        _identity: (sequence: accepted.sequence, digest: accepted.digest),
    };
    try {
      await store.write(
        jsonEncode({
          'schema': 2,
          'automatic': enabled ?? automatic,
          'lastAttempt': (attempt ?? lastAttempt)?.toUtc().toIso8601String(),
          'feeds': {
            for (final MapEntry(:key, :value) in histories.entries)
              key: {'sequence': value.sequence, 'digest': value.digest},
          },
        }),
      );
    } catch (_) {
      _stateFailed = true;
      throw const UpdateFailure('state');
    }
    if (enabled != null) automatic = enabled;
    if (attempt != null) lastAttempt = attempt;
    if (accepted != null) {
      _histories[_identity] = (
        sequence: accepted.sequence,
        digest: accepted.digest,
      );
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy || !configured || _disposed) return;
    if (_stateFailed) {
      error = 'state';
      _notify();
      return;
    }
    _busy = true;
    _cancelled = false;
    error = null;
    _notify();
    try {
      await operation();
    } on UpdateFailure catch (e) {
      error = _cancelled ? null : e.code;
    } on PlatformException catch (e) {
      error = ['permission', 'package', 'storage', 'cancelled'].contains(e.code)
          ? e.code
          : 'install';
    } catch (_) {
      error = 'network';
    } finally {
      _busy = false;
      if (phase == UpdatePhase.checking) phase = UpdatePhase.idle;
      if (phase == UpdatePhase.downloading) phase = UpdatePhase.available;
      if (phase == UpdatePhase.installing) phase = UpdatePhase.ready;
      _notify();
    }
  }

  Future<void> setAutomatic(bool enabled) => _run(() async {
    await _save(enabled: enabled);
  });

  Future<void> checkAutomatically() async {
    if (!automatic || _busy || !configured || _stateFailed || _disposed) return;
    // An attempt dated in the future was made with a wrong clock; waiting for
    // that date could stop checks for years, so it counts as due.
    final last = lastAttempt;
    if (last != null &&
        !last.isAfter(now()) &&
        now().difference(last) < const Duration(days: 1)) {
      return;
    }
    // Keep a downloaded package until the person installs or explicitly checks.
    if (phase == UpdatePhase.ready) return;
    await check();
  }

  Future<void> check() => _run(() async {
    final previous = phase;
    phase = UpdatePhase.checking;
    _notify();
    try {
      // Persist the attempt before networking, so failures/restarts do not
      // poll.
      await _save(attempt: now().toUtc());
      device = await installer.device();
      final wire = await transport.manifest(config!.feed);
      final candidate = await UpdateManifest.verify(
        wire,
        config!,
        verifier: verifier,
      );
      candidate.checkFreshness(
        now(),
        lastSequence: _sequence,
        lastDigest: _digest,
      );
      await _save(
        accepted: candidate,
      ); // Persistence must succeed before offering.
      if (_disposed || _cancelled) return;
      await _removeApk();
      manifest = candidate;
      final target = _target(candidate);
      phase = target == null || !target.newerThan(device!)
          ? UpdatePhase.current
          : target.compatibleWith(device!)
          ? UpdatePhase.available
          : UpdatePhase.incompatible;
    } catch (_) {
      await _keepOffer(previous);
      rethrow;
    }
  });

  /// After a failed check, an offer that is still valid stays, with its
  /// package if one was downloaded: a dropped connection or a bad reply from
  /// the service says nothing against an announcement already verified.
  Future<void> _keepOffer(UpdatePhase previous) async {
    final offered = manifest;
    if (offered != null &&
        [UpdatePhase.available, UpdatePhase.ready].contains(previous)) {
      try {
        offered.checkFreshness(
          now(),
          lastSequence: _sequence,
          lastDigest: _digest,
        );
        phase = previous;
        return;
      } on UpdateFailure {
        // Expired meanwhile: dropped below.
      }
    }
    await _dropOffer();
  }

  /// An offer that expired or was overtaken can never be downloaded or
  /// installed, so it leaves the screen instead of failing on every tap.
  Future<void> _dropOffer() async {
    manifest = null;
    await _removeApk();
    phase = UpdatePhase.idle;
  }

  /// The freshness test [check] made, repeated before each use of an offer;
  /// an offer that fails it is dropped.
  Future<void> _fresh(UpdateManifest selected) async {
    try {
      selected.checkFreshness(
        now(),
        lastSequence: _sequence,
        lastDigest: _digest,
      );
    } on UpdateFailure {
      await _dropOffer();
      rethrow;
    }
  }

  Future<void> download() => _run(() async {
    if (notifyOnly) return;
    final selected = manifest;
    if (selected == null || !available) return;
    await _fresh(selected);
    phase = UpdatePhase.downloading;
    received = 0;
    _percent = 0;
    _notify();
    final file = await transport.download(selected.android, (count) {
      received = count;
      // Once per percentage point, not for every piece of the download.
      final percent = count * 100 ~/ selected.android.size;
      if (percent != _percent) {
        _percent = percent;
        _notify();
      }
    });
    _apk = file;
    if (_disposed || _cancelled) {
      await _removeApk();
      return;
    }
    try {
      await _fresh(selected);
      needsPermission = !await installer.allowed();
      phase = UpdatePhase.ready;
    } catch (_) {
      await _removeApk();
      rethrow;
    }
  });

  Future<void> permission() => _run(() async {
    await installer.requestPermission();
  });

  /// Back in the app, perhaps from Android's settings: the hint to allow
  /// installation goes once the permission is there.
  Future<void> refreshPermission() async {
    if (_busy || _disposed || phase != UpdatePhase.ready || !needsPermission) {
      return;
    }
    try {
      needsPermission = !await installer.allowed();
    } catch (_) {
      return; // The install button asks again anyway.
    }
    _notify();
  }

  PlatformUpdate? _target(UpdateManifest manifest) =>
      notifyOnly ? manifest.macos : manifest.android;

  /// What the announcement offers this platform.
  PlatformUpdate? get offer => manifest == null ? null : _target(manifest!);

  Future<void> openNotes() => _open(offer?.notesUrl);

  /// On the Mac: opens the new version's download in the browser, after
  /// checking the offer is still fresh.
  Future<void> openDownload() async {
    final selected = manifest;
    if (!notifyOnly || selected == null || _disposed) return;
    try {
      await _fresh(selected);
    } on UpdateFailure catch (e) {
      error = e.code;
      _notify();
      return;
    }
    await _open(offer?.url);
  }

  Future<void> _open(Uri? link) async {
    if (link == null || _disposed) return;
    try {
      await installer.open(link);
    } catch (_) {
      error = 'browser';
      _notify();
    }
  }

  Future<void> install() => _run(() async {
    if (notifyOnly) return;
    final selected = manifest;
    if (selected == null || _apk == null || phase != UpdatePhase.ready) return;
    await _fresh(selected);
    device = await installer.device();
    // The installed build may have caught up meanwhile, for example from a
    // package installed by hand; that is not a problem with this one.
    if (!selected.android.newerThan(device!)) {
      await _removeApk();
      phase = UpdatePhase.current;
      return;
    }
    if (!selected.android.compatibleWith(device!)) {
      await _removeApk();
      phase = UpdatePhase.incompatible;
      return;
    }
    needsPermission = !await installer.allowed();
    if (needsPermission) throw const UpdateFailure('permission');
    phase = UpdatePhase.installing;
    _notify();
    try {
      await installer.install(_apk!, selected.android);
    } on PlatformException catch (e) {
      // 'storage' means Android could not take the package, not that it is
      // wrong: it stays for another attempt once there is room.
      if (e.code == 'package') {
        await _removeApk();
        phase = UpdatePhase.available;
      }
      rethrow;
    }
    // Usually Android replaces the app before this point.
    await _removeApk();
    phase = UpdatePhase.current;
  });

  void cancelDownload() {
    _cancelled = true;
    transport.cancel();
  }

  Future<void> _removeApk() async {
    final file = _apk;
    _apk = null;
    if (file != null && await file.exists()) await file.delete();
  }

  @override
  void dispose() {
    _disposed = true;
    transport.cancel();
    super.dispose();
  }
}
