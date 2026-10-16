import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../l10n/l10n.dart';
import 'rust/api/profile.dart';

/// Activity notices on Android (ADR-014). The open Rust profile registers
/// and removes the watch key; the native side only keeps the credentials it
/// is handed, encrypted, and runs the service that waits on the relay. The
/// service never opens the profile: a notice is generic, and the app syncs
/// when it opens.
class AndroidNotifications extends ChangeNotifier with WidgetsBindingObserver {
  AndroidNotifications({
    required this.profile,
    required this.sync,
    bool? supported,
    MethodChannel? channel,
    this.testOwner,
  }) : supported = supported ?? defaultTargetPlatform == TargetPlatform.android,
       _channel =
           channel ?? const MethodChannel('io.github.ulzuhan.arveil/push');
  final Profile profile;
  final Future<bool> Function() sync;
  final bool supported;
  final MethodChannel _channel;
  @visibleForTesting
  final String? testOwner;
  Map<String, Object?> _state = {};
  String? _owner;
  String? error;
  bool busy = false;
  bool _closed = false;
  bool _active = true;
  bool _again = false;
  bool _renewed = false;
  Future<void>? _work;
  Timer? _retry;
  VoidCallback? onOpen;
  bool get enabled => _state['enabled'] == true;
  bool get listening => _state['listening'] == true;
  bool get permission => _state['permission'] == true;
  bool get batteryExempt => _state['battery'] == true;
  bool get refused => _state['error'] == 'refused';
  String? get nativeError => switch (_state['error']) {
    'permission' => currentStrings.pushPermission,
    'refused' => currentStrings.pushRefused,
    _ => null,
  };
  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() async {
    if (!supported) return;
    WidgetsBinding.instance.addObserver(this);
    _active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _channel.setMethodCallHandler((call) async {
      if (_closed) return;
      if (call.method == 'changed') unawaited(reconcile());
      if (call.method == 'opened') {
        await _channel.invokeMethod<bool>('takeOpen');
        if (!_closed) onOpen?.call();
        unawaited(reconcile());
      }
    });
    try {
      final devices = testOwner == null ? await profile.devices() : null;
      if (_closed) return;
      _owner =
          testOwner ??
          sha256
              .convert(
                utf8.encode(
                  devices!.devices.singleWhere((d) => d.current).deviceId,
                ),
              )
              .toString();
      await _read('bind', {'owner': _owner});
      if (_closed) return;
      if (await _channel.invokeMethod<bool>('takeOpen') == true && !_closed) {
        onOpen?.call();
      }
      await reconcile();
    } catch (_) {
      error = currentStrings.pushUnavailable;
      _changed();
    }
    if (!_closed) {
      _retry = Timer.periodic(const Duration(seconds: 30), (_) {
        if (_active) unawaited(reconcile());
      });
    }
  }

  Future<void> _read(String method, [Map<String, Object?>? arguments]) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      method,
      arguments,
    );
    if (!_closed && value != null) {
      _state = value;
      _changed();
    }
  }

  /// Turn notices on (register a watch key, hand it to the service) or off
  /// (stop the service, then remove the key from the realm). Turning off
  /// stops local notices at once, even when the realm cannot be reached.
  Future<void> configure({required bool enable}) async {
    if (!supported || busy || _closed || _owner == null) return;
    busy = true;
    error = null;
    _changed();
    try {
      if (enable) {
        await _enable();
      } else {
        await _read('disable');
        await profile.clearWatchKey();
        await _read('removed');
      }
      await reconcile();
    } catch (_) {
      // Off is already off on this phone; only the realm may still hold
      // the key, which no session uses and the next "on" replaces.
      error = enable
          ? currentStrings.pushUnavailable
          : currentStrings.pushRemovalPending;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> _enable() async {
    final credentials = await profile.registerWatchKey();
    if (_closed) return;
    await _read('enable', {'credentials': credentials});
  }

  /// Open the system page that lets Arveil run without battery limits.
  Future<void> allowBackground() async {
    if (!supported || _closed) return;
    try {
      await _read('battery');
    } catch (_) {
      error = currentStrings.pushUnavailable;
      _changed();
    }
  }

  Future<void> reconcile() {
    if (!supported || _closed || !_active || _owner == null) {
      return Future.value();
    }
    if (_work case final pending?) {
      _again = true;
      return pending;
    }
    return _work = _reconcile().whenComplete(() {
      _work = null;
    });
  }

  Future<void> _reconcile() async {
    try {
      do {
        _again = false;
        await _read('status');
        if (_closed || !_active || _state['owner'] != _owner) return;
        // Betas 5 and 6 registered an ntfy endpoint with the relay. Remove
        // it, and carry an enabled choice over to the relay's own notices.
        if (_state['legacy'] == true) {
          final wasEnabled = _state['legacyEnabled'] == true;
          await profile.setNotificationHint(endpoint: '');
          if (_closed) return;
          await _read('legacyCleared');
          if (wasEnabled && !enabled) await _enable();
        }
        // Turned off while the realm was out of reach: tell it now.
        if (!enabled && _state['removal'] == true) {
          await profile.clearWatchKey();
          if (_closed) return;
          await _read('removed');
        }
        // A rotated, revoked or removed key: renew it once per foreground.
        if (enabled && refused && !_renewed) {
          _renewed = true;
          await _enable();
        }
        if (!_closed && _active && _state['pending'] == true) {
          final hint = _state['hintRevision'];
          if (await sync() && !_closed) {
            await _read('synced', {'revision': hint, 'owner': _owner});
          }
        }
        error = null;
      } while (_again && !_closed && _active);
    } catch (_) {
      if (!_closed) error = currentStrings.pushUnavailable;
    }
    _changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) {
      _renewed = false;
      unawaited(reconcile());
    }
  }

  @override
  void dispose() {
    _closed = true;
    _retry?.cancel();
    if (supported) {
      WidgetsBinding.instance.removeObserver(this);
      _channel.setMethodCallHandler(null);
    }
    // The choice survives process death; the service never unlocks a profile.
    super.dispose();
  }
}
