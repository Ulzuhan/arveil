import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'android_notifications.dart';

class AndroidNotificationSettings extends StatefulWidget {
  const AndroidNotificationSettings({super.key, required this.controller});
  final AndroidNotifications controller;
  @override
  State<AndroidNotificationSettings> createState() =>
      _AndroidNotificationSettingsState();
}

class _AndroidNotificationSettingsState
    extends State<AndroidNotificationSettings> {
  late final _server = TextEditingController(text: widget.controller.server);
  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
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
                  if (!c.installed) Text(s.pushInstall),
                  TextField(
                    controller: _server,
                    enabled: !c.enabled && !c.busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: s.pushServer,
                      hintText: s.pushServerHint,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    key: const Key('android-notifications-enabled'),
                    title: Text(s.pushEnable),
                    value: c.enabled,
                    onChanged: c.busy || (!c.installed && !c.enabled)
                        ? null
                        : (v) => c.configure(enable: v, server: _server.text),
                  ),
                  if (c.enabled)
                    Text(
                      c.waiting
                          ? s.pushWaiting
                          : c.relayPending
                          ? s.pushRelayPending
                          : s.pushReady,
                    ),
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
                  if (c.enabled || c.relayPending)
                    TextButton(
                      onPressed: c.busy ? null : c.retry,
                      child: Text(s.pushRetry),
                    ),
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
