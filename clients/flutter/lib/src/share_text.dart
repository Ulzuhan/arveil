import 'package:flutter/services.dart';

const _share = MethodChannel('io.github.ulzuhan.arveil/share');

/// Hand text to the system's share sheet. Returns false when this platform
/// has none, so the caller can copy it instead.
Future<bool> shareText(String text) async {
  try {
    return await _share.invokeMethod<bool>('text', {'text': text}) ?? false;
  } catch (_) {
    return false;
  }
}
