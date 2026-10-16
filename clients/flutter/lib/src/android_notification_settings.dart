import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'android_notifications.dart';

/// Activity notices on Android (ADR-014): one switch, what it costs, and
/// what the phone may still do to it.
class AndroidNotificationSettings extends StatelessWidget {
  const AndroidNotificationSettings({super.key, required this.controller});
  final AndroidNotifications controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
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
                  Text(s.pushExplanation),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    key: const Key('android-notifications-enabled'),
                    title: Text(s.pushEnable),
                    value: c.enabled,
                    onChanged: c.busy ? null : (v) => c.configure(enable: v),
                  ),
                  if (c.enabled)
                    Text(c.listening ? s.pushReady : s.pushConnecting),
                  if (c.enabled && !c.permission) Text(s.pushPermission),
                  if (c.nativeError ?? c.error case final error?)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (c.enabled && !c.batteryExempt) ...[
                    const SizedBox(height: 16),
                    Text(s.pushBattery),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        key: const Key('android-notifications-battery'),
                        onPressed: c.busy ? null : c.allowBackground,
                        child: Text(s.pushBatteryAction),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(s.pushPrivacy),
                  const SizedBox(height: 16),
                  Text(s.pushLimits),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
