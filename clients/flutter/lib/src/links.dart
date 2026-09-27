import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';

/// Opens an HTTPS link in the system browser.
typedef OpenLink = Future<void> Function(Uri url);

// Android and macOS register this handler at start for the update notice;
// it opens only HTTPS links.
const _channel = MethodChannel('io.github.ulzuhan.arveil/updates');

Future<void> openInBrowser(Uri url) =>
    _channel.invokeMethod('open', {'url': url.toString()});

/// Opens [url], or copies it when there is no browser to open it with, so
/// the person can still paste it somewhere.
Future<void> followLink(
  BuildContext context,
  Uri url, {
  OpenLink open = openInBrowser,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final copied = context.l10n.linkCopied;
  try {
    await open(url);
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: url.toString()));
    messenger.showSnackBar(SnackBar(content: Text(copied)));
  }
}
