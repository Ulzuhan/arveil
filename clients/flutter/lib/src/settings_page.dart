import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'archives_page.dart';
import 'design/design.dart';
import 'devices_page.dart';
import 'key_packages_panel.dart';
import 'kit_files.dart';
import 'own_route.dart';
import 'pairing_panel.dart';
import 'profile_session.dart';
import 'recovery_panel.dart';
import 'rust/api/profile.dart';

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
        StatusBanner(
          key: const Key('error'),
          title: message,
          icon: Icons.error_outline,
          tone: BannerTone.error,
        ),
      ],
    ],
  );
}

/// A settings screen of its own: a bar with its name, and content that
/// follows the profile's state.
class SessionScreen extends StatelessWidget {
  const SessionScreen({
    super.key,
    required this.session,
    required this.title,
    required this.builder,
  });
  final ProfileSession session;
  final String title;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: WindowSize.of(context).margin + 8,
                vertical: 16,
              ),
              children: [
                if (session.setup != null) builder(context),
                SessionActivity(session: session),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The identity kit screen: export, confirm the key was saved, or postpone.
Route<void> kitRoute(ProfileSession session, KitFiles files) =>
    MaterialPageRoute(
      builder: (context) => SessionScreen(
        session: session,
        title: context.l10n.kitTitle,
        builder: (context) => RecoveryPanel(
          key: const Key('export-panel'),
          session: session,
          files: files,
          export: true,
          heading: false,
        ),
      ),
    );

/// The profile's own screens and operations, in sections: security and
/// recovery, connection, the app, and closing the profile.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.session,
    required this.kitFiles,
    required this.onClose,
  });
  final ProfileSession session;
  final KitFiles kitFiles;
  final VoidCallback onClose;

  void _push(BuildContext context, Route<void> route) =>
      Navigator.of(context).push(route);

  String _kitState(AppLocalizations l10n, SetupView setup) {
    if (setup.kitSavedAt case final saved?) {
      if (setup.kitStale) return l10n.kitStateStale;
      final at = DateTime.fromMillisecondsSinceEpoch(saved * 1000);
      return l10n.kitStateSaved(numericDate(l10n, at));
    }
    return l10n.kitStateNever;
  }

  String _keysState(AppLocalizations l10n) =>
      switch (session.keyPackages?.level ?? KeyPackageLevelView.unknown) {
        KeyPackageLevelView.unknown => l10n.keyPackagesUnknown,
        KeyPackageLevelView.empty => l10n.keyPackagesEmpty,
        KeyPackageLevelView.low => l10n.keyPackagesLow,
        KeyPackageLevelView.ready => l10n.keyPackagesReady,
      };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final l10n = context.l10n;
      final setup = session.setup;
      final busy = session.busy || session.cancellingPairing;
      final kitAttention =
          setup != null &&
          setup.administrator &&
          (setup.kitSavedAt == null || setup.kitStale);
      return Scaffold(
        appBar: AppBar(title: Text(l10n.navSettings)),
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
                        vertical: 8,
                      ),
                      children: [
                        if (setup.recoveryWarning) ...[
                          const SizedBox(height: 8),
                          StatusBanner(
                            title: l10n.recoveryWarningTitle,
                            body: l10n.recoveryRollbackWarning,
                            icon: Icons.gpp_maybe_outlined,
                            tone: BannerTone.error,
                          ),
                        ],
                        SettingsGroup(
                          title: l10n.participantsYou,
                          children: [
                            SettingsRow(
                              icon: setup.administrator
                                  ? Icons.admin_panel_settings_outlined
                                  : Icons.link,
                              title: setup.administrator
                                  ? l10n.identityAdministrator
                                  : l10n.identityLinked,
                            ),
                            SettingsRow(
                              key: const Key('share-route'),
                              icon: Icons.share_outlined,
                              title: l10n.ownRouteTitle,
                              subtitle: l10n.shareMyRouteHelp,
                              onTap: () =>
                                  showOwnRoute(context, session.profile!),
                            ),
                          ],
                        ),
                        SettingsGroup(
                          title: l10n.settingsSecurity,
                          children: [
                            if (setup.administrator)
                              SettingsRow(
                                key: const Key('open-kit'),
                                icon: Icons.key_outlined,
                                title: l10n.kitTitle,
                                subtitle: _kitState(l10n, setup),
                                attention: kitAttention,
                                onTap: busy
                                    ? null
                                    : () => _push(
                                        context,
                                        kitRoute(session, kitFiles),
                                      ),
                              )
                            else
                              SettingsRow(
                                icon: Icons.key_outlined,
                                title: l10n.kitTitle,
                                subtitle: l10n.linkedDeviceKitNote,
                              ),
                            SettingsRow(
                              key: const Key('open-devices'),
                              icon: Icons.devices_outlined,
                              title: l10n.manageDevices,
                              onTap: busy
                                  ? null
                                  : () => _push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => DevicesPage(
                                          profile: session.profile!,
                                          bootstrap: setup.bootstrap!,
                                        ),
                                      ),
                                    ),
                            ),
                            if (setup.administrator)
                              SettingsRow(
                                key: const Key('open-pairing'),
                                icon: Icons.add_link,
                                title: l10n.pairingOtherTitle,
                                onTap: busy
                                    ? null
                                    : () => _push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => SessionScreen(
                                            session: session,
                                            title: l10n.pairingOtherTitle,
                                            builder: (context) => PairingPanel(
                                              key: const Key(
                                                'pair-administration',
                                              ),
                                              session: session,
                                              administration: true,
                                              heading: false,
                                            ),
                                          ),
                                        ),
                                      ),
                              ),
                            SettingsRow(
                              key: const Key('open-archives'),
                              icon: Icons.history,
                              title: l10n.encryptedHistory,
                              onTap: busy
                                  ? null
                                  : () => _push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ArchivesPage(
                                          profile: session.profile!,
                                        ),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                        SettingsGroup(
                          title: l10n.settingsConnection,
                          children: [
                            SettingsRow(
                              key: const Key('open-keys'),
                              icon: Icons.vpn_key_outlined,
                              title: l10n.keyPackagesTitle,
                              subtitle: _keysState(l10n),
                              attention:
                                  session.keyPackages?.level ==
                                  KeyPackageLevelView.empty,
                              onTap: () => _push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => SessionScreen(
                                    session: session,
                                    title: l10n.keyPackagesTitle,
                                    builder: (context) => KeyPackagesPanel(
                                      session: session,
                                      heading: false,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        SettingsGroup(
                          title: l10n.settingsApp,
                          children: [
                            SettingsRow(
                              icon: Icons.description_outlined,
                              title: l10n.licenses,
                              onTap: () => showLicensePage(
                                context: context,
                                applicationName: l10n.appTitle,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SettingsGroup(
                          children: [
                            SettingsRow(
                              key: const Key('close-profile'),
                              icon: Icons.lock_outline,
                              title: l10n.profileClose,
                              onTap: busy ? null : onClose,
                            ),
                          ],
                        ),
                        SessionActivity(session: session),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
      );
    },
  );
}
