import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../l10n/l10n.dart';
import 'rust/api/profile.dart';

abstract interface class NotificationReceipts {
  Future<List<String>> read();
  Future<void> write(List<String> hashes);
}

/// Presentation receipts, not message/read state: only opaque hashes. Keep
/// them in the nonsynchronizing login Keychain, away from plaintext preferences.
class KeychainNotificationReceipts implements NotificationReceipts {
  static const _store = FlutterSecureStorage(
    mOptions: MacOsOptions(
      usesDataProtectionKeychain: false,
      accountName: 'io.github.ulzuhan.arveil.notification-receipts',
      synchronizable: false,
    ),
  );
  static const _key = 'presented-v1';
  @override
  Future<List<String>> read() async {
    final value = await _store.read(key: _key);
    if (value == null) return [];
    final decoded = jsonDecode(value);
    if (decoded is! List ||
        decoded.length > 512 ||
        decoded.any(
          (v) => v is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(v),
        )) {
      throw const FormatException('Invalid notification receipts.');
    }
    return decoded.cast<String>();
  }

  @override
  Future<void> write(List<String> hashes) =>
      _store.write(key: _key, value: jsonEncode(hashes));
}

/// Local Mac alerts for live incoming activity. The first local snapshot is a
/// baseline, so opening a profile never replays its history as notifications.
/// The Rust profile remains the sole owner of messages, unread markers and sync.
class DesktopNotifications extends ChangeNotifier {
  DesktopNotifications({
    NotificationReceipts? receipts,
    MethodChannel? channel,
    bool? supported,
  }) : _receipts = receipts ?? KeychainNotificationReceipts(),
       _channel =
           channel ??
           const MethodChannel('io.github.ulzuhan.arveil/notifications'),
       supported = supported ?? defaultTargetPlatform == TargetPlatform.macOS;
  final NotificationReceipts _receipts;
  final MethodChannel _channel;
  final bool supported;
  bool enabled = false;
  bool background = false;
  bool busy = false;
  String? error;
  bool _closed = false;
  bool _ready = false;
  bool _receiptsLoaded = false;
  Future<void>? _receiptsLoading;
  bool _baseline = false;
  final Map<String, ({int cursor, int unread})> _last = {};
  final List<String> _seen = [];
  final Map<String, String> _targets = {};
  Future<void> _work = Future.value();
  void Function(String? group)? onOpen;
  void Function(bool visible)? onWindowVisibility;
  String? Function()? visibleGroup;
  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() async {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'visibility' && !_closed) {
        onWindowVisibility?.call(call.arguments == true);
      }
      if (call.method == 'opened' && !_closed) {
        onOpen?.call(_targets[call.arguments]);
      }
    });
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      if (_closed) return;
      enabled = status?['enabled'] == true;
      background = status?['background'] == true;
      if (_closed) return;
      await _channel.invokeMethod<void>('profile', {
        'open': true,
        'openLabel': currentStrings.notificationsOpenApp,
        'quitLabel': currentStrings.notificationsQuitApp,
      });
      if (enabled) await _loadReceipts();
      if (_closed) return;
      final pending = await _channel.invokeMethod<String>('takeOpen');
      if (!_closed && pending != null) onOpen?.call(_targets[pending]);
      _ready = true;
    } catch (_) {
      enabled = false;
      error = currentStrings.notificationsUnavailable;
    }
    _changed();
  }

  Future<void> _loadReceipts() async {
    if (_receiptsLoaded) return;
    if (_receiptsLoading case final pending?) return pending;
    final pending = () async {
      final hashes = await _receipts.read();
      if (_closed) return;
      _seen.addAll(hashes);
      _receiptsLoaded = true;
    }();
    _receiptsLoading = pending;
    try {
      await pending;
    } finally {
      _receiptsLoading = null;
    }
  }

  Future<void> configure({bool? alerts, bool? keepRunning}) async {
    if (!supported || busy || _closed) return;
    busy = true;
    error = null;
    _changed();
    try {
      if (alerts == true) await _loadReceipts();
      if (_closed) return;
      final status = await _channel.invokeMapMethod<String, Object?>(
        'configure',
        {'enabled': alerts ?? enabled, 'background': keepRunning ?? background},
      );
      if (_closed) return;
      enabled = status?['enabled'] == true;
      background = status?['background'] == true;
      if (alerts == true && !enabled) {
        error = currentStrings.notificationsDenied;
      }
      _ready = true;
    } catch (_) {
      error = currentStrings.notificationsUnavailable;
    } finally {
      busy = false;
      _changed();
    }
  }

  /// Called after successful local queries, including while hidden. Serial
  /// receipt writes prevent duplicate concurrent presentations.
  Future<void> observe(List<ConversationView> rows) {
    if (!supported || _closed) return Future.value();
    final snapshot = List<ConversationView>.of(rows);
    final eligible = _ready && enabled;
    _work = _work
        .then((_) async {
          if (_closed) return;
          final candidates = <(String, String)>[];
          for (final row in snapshot) {
            final old = _last[row.groupId];
            final cursor = row.lastEvent?.cursor ?? 0;
            _last[row.groupId] = (cursor: cursor, unread: row.unread);
            // Unread excludes our linked devices and imports. Compare the cursor
            // too: transfer progress must not produce new alerts.
            if (_baseline &&
                eligible &&
                _ready &&
                enabled &&
                cursor > (old?.cursor ?? 0) &&
                row.unread > (old?.unread ?? 0) &&
                row.groupId != visibleGroup?.call()) {
              final hash = sha256
                  .convert(utf8.encode('${row.groupId}:$cursor'))
                  .toString();
              if (!_seen.contains(hash)) candidates.add((hash, row.groupId));
            }
          }
          _last.removeWhere((key, _) => !snapshot.any((r) => r.groupId == key));
          _baseline = true;
          if (candidates.isEmpty || _closed) return;
          final next = [..._seen, ...candidates.map((c) => c.$1)];
          if (next.length > 512) next.removeRange(0, next.length - 512);
          // At-most-once: a crash after this receipt may miss a banner, but never
          // changes unread messages or replays the history as banners.
          await _receipts.write(next);
          if (_closed || !enabled) return;
          _seen
            ..clear()
            ..addAll(next);
          final remaining = candidates.where(
            (c) => c.$2 != visibleGroup?.call(),
          );
          if (remaining.isEmpty) return;
          final target = remaining.first;
          _targets[target.$1] = target.$2;
          while (_targets.length > 32) {
            _targets.remove(_targets.keys.first);
          }
          if (visibleGroup?.call() == target.$2) return;
          await _channel.invokeMethod<bool>('show', {
            'token': target.$1,
            'title': currentStrings.appTitle,
            'body': currentStrings.notificationsNewActivity,
          });
        })
        .catchError((Object _) {
          error = currentStrings.notificationsUnavailable;
          _changed();
        });
    return _work;
  }

  @override
  void dispose() {
    _closed = true;
    if (supported) {
      _channel.setMethodCallHandler(null);
      unawaited(
        _channel
            .invokeMethod<void>('profile', {'open': false})
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }
}
