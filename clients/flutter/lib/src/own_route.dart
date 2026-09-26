import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'rust/api/profile.dart';

/// Shows this device's contact route so it can be shared privately, with
/// a way to copy it.
Future<void> showOwnRoute(BuildContext context, Profile profile) async {
  final String route;
  try {
    route = await profile.ownRoute();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.ownRouteFailed)));
    }
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.ownRouteTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.ownRouteShare),
            const SizedBox(height: 16),
            SelectableText(route, key: const Key('own-route')),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.close),
        ),
        FilledButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: route));
            if (context.mounted) Navigator.pop(context);
          },
          child: Text(context.l10n.ownRouteCopy),
        ),
      ],
    ),
  );
}
