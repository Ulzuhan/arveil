import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'archives_page.dart';
import 'design/layout.dart';
import 'devices_page.dart';
import 'key_packages_panel.dart';
import 'kit_files.dart';
import 'pairing_panel.dart';
import 'profile_session.dart';
import 'recovery_panel.dart';

/// What the profile is doing now and the last failure, in words.
class SessionActivity extends StatelessWidget {
  const SessionActivity({super.key, required this.session});
  final ProfileSession session;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (session.busy) ...[
        const SizedBox(height: 24),
        LinearProgressIndicator(
          semanticsLabel: context.l10n.operationInProgress,
        ),
        const SizedBox(height: 12),
        Text(context.l10n.operationInProgressDetail),
      ],
      if (session.error case final message?) ...[
        const SizedBox(height: 24),
        Semantics(
          liveRegion: true,
          child: Container(
            key: const Key('error'),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(message),
          ),
        ),
      ],
    ],
  );
}

/// The profile's own screens and operations: devices, encrypted history,
/// keys for new groups, the identity kit and linking, and closing it.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.session,
    required this.kitFiles,
    required this.onClose,
    this.kitPanel,
  });
  final ProfileSession session;
  final KitFiles kitFiles;
  final VoidCallback onClose;

  /// Lets the kit reminder bring the kit panel into view.
  final GlobalKey? kitPanel;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final setup = session.setup;
      return Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.navSettings),
          actions: [
            TextButton.icon(
              onPressed: session.busy || session.cancellingPairing
                  ? null
                  : onClose,
              icon: const Icon(Icons.lock_outline),
              label: Text(context.l10n.profileClose),
            ),
          ],
        ),
        body: setup == null
            ? const SizedBox.shrink()
            : SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: EdgeInsets.symmetric(
                        horizontal: WindowSize.of(context).margin + 8,
                        vertical: 24,
                      ),
                      children: [
                        if (setup.recoveryWarning) ...[
                          Text(context.l10n.recoveryRollbackWarning),
                          const SizedBox(height: 24),
                        ],
                        OutlinedButton.icon(
                          key: const Key('open-devices'),
                          onPressed: session.busy
                              ? null
                              : () => Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                    builder: (_) => DevicesPage(
                                      profile: session.profile!,
                                      bootstrap: setup.bootstrap!,
                                    ),
                                  ),
                                ),
                          icon: const Icon(Icons.devices),
                          label: Text(context.l10n.manageDevices),
                        ),
                        const SizedBox(height: 24),
                        OutlinedButton.icon(
                          key: const Key('open-archives'),
                          onPressed: session.busy
                              ? null
                              : () => Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ArchivesPage(profile: session.profile!),
                                  ),
                                ),
                          icon: const Icon(Icons.history),
                          label: Text(context.l10n.encryptedHistory),
                        ),
                        const SizedBox(height: 24),
                        KeyPackagesPanel(session: session),
                        const Divider(height: 48),
                        if (setup.administrator) ...[
                          KeyedSubtree(
                            key: kitPanel,
                            child: RecoveryPanel(
                              key: const Key('export-panel'),
                              session: session,
                              files: kitFiles,
                              export: true,
                            ),
                          ),
                          const Divider(height: 48),
                          PairingPanel(
                            key: const Key('pair-administration'),
                            session: session,
                            administration: true,
                          ),
                          const Divider(height: 48),
                        ] else ...[
                          Text(context.l10n.linkedDeviceKitNote),
                          const SizedBox(height: 24),
                        ],
                        SessionActivity(session: session),
                      ],
                    ),
                  ),
                ),
              ),
      );
    },
  );
}
