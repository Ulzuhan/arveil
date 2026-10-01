import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../l10n/l10n.dart';
import 'rust/api/profile.dart';

/// The native receiver only owns delivery preferences and a generic hint.
/// Registration and synchronization always use the already-open Rust profile.
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
  Future<void>? _work;
  Timer? _retry;
  VoidCallback? onOpen;
  bool get enabled => _state['enabled'] == true;
  bool get installed => _state['installed'] == true;
  bool get permission => _state['permission'] == true;
  String get server => _state['server'] as String? ?? '';
  bool get waiting => enabled && (_state['endpoint'] as String? ?? '').isEmpty;
  bool get relayPending => _state['revision'] != _state['applied'];
  String? get nativeError => switch (_state['error']) {
    'permission' => currentStrings.pushPermission,
    'endpoint' => currentStrings.pushEndpointMismatch,
    'registration' => currentStrings.pushRegistrationFailed,
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
      if (enabled) await _read('retry');
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

  Future<void> configure({required bool enable, String? server}) async {
    if (!supported || busy || _closed || _owner == null) return;
    busy = true;
    error = null;
    _changed();
    try {
      await _read(
        enable ? 'enable' : 'disable',
        enable ? {'server': server?.trim() ?? this.server} : null,
      );
      await reconcile();
    } catch (_) {
      error = currentStrings.pushUnavailable;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> retry() async {
    if (_closed || busy) return;
    try {
      await _read('retry');
      await reconcile();
    } catch (_) {
      error = currentStrings.pushUnavailable;
      _changed();
    }
  }

  /// A newer native revision cannot be acknowledged by an older network reply.
  /// Failed removal is retried on resume / while the profile remains open.
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
        var registered = false;
        if (relayPending) {
          final revision = _state['revision'];
          final endpoint = _state['endpoint'] as String? ?? '';
          await profile.setNotificationHint(endpoint: enabled ? endpoint : '');
          if (_closed) return;
          await _read('ack', {'owner': _owner, 'revision': revision});
          registered = true;
          if (relayPending) _again = true;
        }
        if (!_closed && _active && (registered || _state['pending'] == true)) {
          final hint = _state['hintRevision'];
          if (await sync() && !_closed) {
            await _read('synced', {'revision': hint, 'owner': _owner});
          }
        }
        error = null;
      } while (_again && !_closed && _active);
    } catch (_) {
      if (!_closed) error = currentStrings.pushRelayPending;
    }
    _changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) unawaited(retry());
  }

  @override
  void dispose() {
    _closed = true;
    _retry?.cancel();
    if (supported) {
      WidgetsBinding.instance.removeObserver(this);
      _channel.setMethodCallHandler(null);
    }
    // Opt-in survives process death. No native receiver ever unlocks a profile.
    super.dispose();
  }
}
