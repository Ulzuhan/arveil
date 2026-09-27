import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Links that open the app (ADR-012 §5): an invitation, a code to link this
/// device, or someone's contact card, from a web page, another app or the
/// `arveil:` scheme. Only the text arrives. The screen that takes it reads it
/// and asks the person before anything happens; nothing is fetched.
class IncomingLinks extends ChangeNotifier {
  IncomingLinks({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('io.github.ulzuhan.arveil/links');

  final MethodChannel _channel;
  String? _pending;
  String? _last;
  bool _started = false;

  /// The newest link nobody took yet.
  String? get pending => _pending;

  /// Listen for links, and ask for the one that opened the app.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) {
        receive(call.arguments as String);
      }
    });
    try {
      receive(await _channel.invokeMethod<String>('initial'));
    } catch (_) {
      // A platform without links has nothing pending.
    }
  }

  /// A link arrived. The same link twice (the platform may say it again on
  /// a cold start) counts once.
  void receive(String? link) {
    if (link == null || link.isEmpty || link.length > 4096 || link == _last) {
      return;
    }
    _last = link;
    _pending = link;
    notifyListeners();
  }

  /// Take the pending link: the screen that takes it handles it.
  String? take() {
    final link = _pending;
    _pending = null;
    return link;
  }
}

/// The app's inbox for links.
final incomingLinks = IncomingLinks();
