import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'desktop_notifications.dart';

class NotificationSettings extends StatelessWidget {
  const NotificationSettings({super.key, required this.controller});
  final DesktopNotifications controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final s = context.l10n;
      return Scaffold(
        appBar: AppBar(title: Text(s.notificationsTitle)),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(s.notificationsExplanation),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    key: const Key('notifications-enabled'),
                    title: Text(s.notificationsEnable),
                    value: controller.enabled,
                    onChanged: controller.busy
                        ? null
                        : (v) => controller.configure(alerts: v),
                  ),
                  SwitchListTile(
                    key: const Key('notifications-background'),
                    title: Text(s.notificationsBackground),
                    subtitle: Text(s.notificationsBackgroundDetail),
                    value: controller.background,
                    onChanged: controller.busy
                        ? null
                        : (v) => controller.configure(keepRunning: v),
                  ),
                  const SizedBox(height: 16),
                  Text(s.notificationsLimits),
                  if (controller.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        controller.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
