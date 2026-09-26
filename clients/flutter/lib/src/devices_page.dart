import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'design/design.dart';
import 'rust/api/profile.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.profile,
    required this.bootstrap,
    this.onChanged,
  });
  final Profile profile;
  final String bootstrap;

  /// Reload shared profile state after a mutation or sync, including when
  /// a lost response follows a durable local device change.
  final Future<void> Function()? onChanged;

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
    if (action != null) await widget.onChanged?.call();
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
    final c = ArveilColors.of(context);
    final muted = ArveilType.secondary.copyWith(color: c.inkMuted);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.devicesTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: WindowSize.of(context).margin + 8,
                vertical: 16,
              ),
              children: [
                if (_busy) const LinearProgressIndicator(),
                Text(context.l10n.devicesKnownState, style: muted),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('sync-devices'),
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await widget.profile.sync_(
                              bootstrap: widget.bootstrap,
                            );
                          }),
                    icon: const Icon(Icons.sync),
                    label: Text(context.l10n.devicesSync),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  StatusBanner(
                    key: const Key('devices-error'),
                    title: _error!,
                    icon: Icons.error_outline,
                    tone: BannerTone.error,
                    actions: [
                      TextButton(
                        onPressed: _busy ? null : () => _run(),
                        child: Text(context.l10n.devicesReadLocal),
                      ),
                    ],
                  ),
                ],
                if (inventory != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    inventory.administrator
                        ? context.l10n.devicesAdministrator
                        : context.l10n.devicesLinked,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.l10n.devicesManifestVersion(
                      '${inventory.manifestSequence}',
                    ),
                    style: muted,
                  ),
                  if (inventory.unknownActive + inventory.unknownRevoked > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: StatusBanner(
                        key: const Key('partial-device-inventory'),
                        title: context.l10n.devicesPartialInventory(
                          inventory.unknownActive,
                          inventory.unknownRevoked,
                        ),
                        icon: Icons.info_outline,
                        tone: BannerTone.info,
                      ),
                    ),
                  const SizedBox(height: 8),
                  for (final device
                      in [...inventory.devices]..sort(
                        (a, b) => a.current == b.current
                            ? a.deviceId.compareTo(b.deviceId)
                            : a.current
                            ? -1
                            : 1,
                      ))
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _device(context, inventory, device),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _device(
    BuildContext context,
    DeviceInventoryView inventory,
    ManagedDeviceView device,
  ) {
    final c = ArveilColors.of(context);
    final muted = ArveilType.secondary.copyWith(color: c.inkMuted);
    return Container(
      key: Key('device-${device.deviceId}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(ArveilShape.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                device.current
                    ? Icons.smartphone_outlined
                    : Icons.devices_other_outlined,
                color: device.revoked ? c.danger : c.accent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  device.current
                      ? context.l10n.devicesThis
                      : context.l10n.devicesLinkedDevice,
                  style: ArveilType.rowName.copyWith(color: c.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            device.deviceId,
            style: ArveilType.identifier.copyWith(color: c.inkSoft),
          ),
          const SizedBox(height: 8),
          Text(
            device.revoked
                ? context.l10n.devicesRevokedLocally
                : context.l10n.devicesNotRevoked,
            style: muted,
          ),
          if (device.revocation case final progress?) ...[
            const SizedBox(height: 8),
            Text(
              progress.relayPublished
                  ? context.l10n.devicesRevocationAccepted
                  : context.l10n.devicesRevocationPending,
            ),
            Text(
              context.l10n.devicesGroupsWaiting(progress.groupsWaiting),
              style: muted,
            ),
            if (progress.groupsWaiting > 0)
              Text(context.l10n.devicesGroupsWaitingHelp, style: muted),
            Text(
              context.l10n.devicesNoticesPending(progress.notificationsPending),
              style: muted,
            ),
            if (progress.notificationsUnconfirmed > 0)
              Text(
                context.l10n.devicesNoticesUnconfirmed(
                  progress.notificationsUnconfirmed,
                ),
                style: muted,
              ),
            if (progress.withoutRoute > 0)
              Text(
                context.l10n.devicesNoticesWithoutRoute(progress.withoutRoute),
                style: muted,
              ),
            Text(context.l10n.devicesAcceptanceCaveat, style: muted),
          ],
          if (inventory.administrator &&
              !device.current &&
              !device.revoked) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: Key('revoke-${device.deviceId}'),
                style: OutlinedButton.styleFrom(foregroundColor: c.danger),
                onPressed: _busy ? null : () => _revoke(device),
                child: Text(context.l10n.devicesRevoke),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
