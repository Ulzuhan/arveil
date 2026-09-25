import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'rust/api/profile.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.profile,
    required this.bootstrap,
  });
  final Profile profile;
  final String bootstrap;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  DeviceInventoryView? _inventory;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  // Always reload the durable snapshot, including after a lost network reply.
  Future<void> _run([Future<void> Function()? action]) async {
    if (_busy) return;
    // Runs from initState too, before the widget may read inherited state.
    final l10n = currentStrings;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await action?.call();
    } catch (_) {
      error = l10n.devicesOperationFailed;
    }
    try {
      final inventory = await widget.profile.devices();
      if (mounted) setState(() => _inventory = inventory);
    } catch (_) {
      error = l10n.devicesReadFailed;
    }
    if (mounted) {
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  Future<void> _revoke(ManagedDeviceView device) async {
    if (_busy ||
        device.current ||
        device.revoked ||
        !(_inventory?.administrator ?? false)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.devicesRevokeTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.devicesRevokeCheckId),
              const SizedBox(height: 12),
              SelectableText(device.deviceId),
              const SizedBox(height: 12),
              Text(context.l10n.devicesRevokeConsequences),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            key: const Key('confirm-device-revocation'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.devicesRevokeConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      () => widget.profile.revokeDevice(
        bootstrap: widget.bootstrap,
        deviceId: device.deviceId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inventory = _inventory;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.devicesTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_busy) const LinearProgressIndicator(),
            Text(context.l10n.devicesKnownState),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('sync-devices'),
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await widget.profile.sync_(bootstrap: widget.bootstrap);
                    }),
              icon: const Icon(Icons.sync),
              label: Text(context.l10n.devicesSync),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, key: const Key('devices-error')),
              TextButton(
                onPressed: _busy ? null : () => _run(),
                child: Text(context.l10n.devicesReadLocal),
              ),
            ],
            if (inventory != null) ...[
              const SizedBox(height: 12),
              Text(
                inventory.administrator
                    ? context.l10n.devicesAdministrator
                    : context.l10n.devicesLinked,
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.devicesManifestVersion(
                  '${inventory.manifestSequence}',
                ),
              ),
              if (inventory.unknownActive + inventory.unknownRevoked > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    context.l10n.devicesPartialInventory(
                      inventory.unknownActive,
                      inventory.unknownRevoked,
                    ),
                    key: const Key('partial-device-inventory'),
                  ),
                ),
              for (final device
                  in [...inventory.devices]..sort(
                    (a, b) => a.current == b.current
                        ? a.deviceId.compareTo(b.deviceId)
                        : a.current
                        ? -1
                        : 1,
                  ))
                Card(
                  key: Key('device-${device.deviceId}'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          device.current
                              ? context.l10n.devicesThis
                              : context.l10n.devicesLinkedDevice,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        SelectableText(device.deviceId),
                        const SizedBox(height: 8),
                        Text(
                          device.revoked
                              ? context.l10n.devicesRevokedLocally
                              : context.l10n.devicesNotRevoked,
                        ),
                        if (device.revocation case final progress?) ...[
                          const SizedBox(height: 8),
                          Text(
                            progress.relayPublished
                                ? context.l10n.devicesRevocationAccepted
                                : context.l10n.devicesRevocationPending,
                          ),
                          Text(
                            context.l10n.devicesGroupsWaiting(
                              progress.groupsWaiting,
                            ),
                          ),
                          if (progress.groupsWaiting > 0)
                            Text(context.l10n.devicesGroupsWaitingHelp),
                          Text(
                            context.l10n.devicesNoticesPending(
                              progress.notificationsPending,
                            ),
                          ),
                          if (progress.notificationsUnconfirmed > 0)
                            Text(
                              context.l10n.devicesNoticesUnconfirmed(
                                progress.notificationsUnconfirmed,
                              ),
                            ),
                          if (progress.withoutRoute > 0)
                            Text(
                              context.l10n.devicesNoticesWithoutRoute(
                                progress.withoutRoute,
                              ),
                            ),
                          Text(context.l10n.devicesAcceptanceCaveat),
                        ],
                        if (inventory.administrator &&
                            !device.current &&
                            !device.revoked) ...[
                          const SizedBox(height: 12),
                          OutlinedButton(
                            key: Key('revoke-${device.deviceId}'),
                            onPressed: _busy ? null : () => _revoke(device),
                            child: Text(context.l10n.devicesRevoke),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
