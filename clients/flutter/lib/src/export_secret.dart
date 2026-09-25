import 'package:flutter/widgets.dart';

/// A native save dialog can complete before the app resumes. Keep that result
/// hidden until the user explicitly reveals it in the foreground. Once back in
/// the app, any further loss of focus discards both hidden and visible keys.
class ExportSecret {
  String? visible;
  String? _pending;
  bool _awaitingResume = false;

  bool get pending => _pending != null;

  void saved(String secret, AppLifecycleState? state) {
    clear();
    if (state == AppLifecycleState.resumed) {
      visible = secret;
    } else {
      _pending = secret;
      _awaitingResume = true;
    }
  }

  void lifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _awaitingResume = false;
    } else if (state == AppLifecycleState.detached || !_awaitingResume) {
      clear();
    }
  }

  void reveal(AppLifecycleState? state) {
    if (state != AppLifecycleState.resumed) return;
    visible = _pending;
    _pending = null;
  }

  void clear() {
    visible = null;
    _pending = null;
    _awaitingResume = false;
  }
}
