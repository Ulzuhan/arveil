import 'package:flutter/material.dart';

import 'l10n/l10n.dart';
import 'src/design/theme.dart';
import 'src/devices_page.dart';
import 'src/archives_page.dart';
import 'src/profile_session.dart';
import 'src/conversation_controller.dart';
import 'src/conversations_page.dart';
import 'src/kit_files.dart';
import 'src/key_packages_panel.dart';
import 'src/pairing_panel.dart';
import 'src/recovery_panel.dart';
import 'src/rust/api/profile.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  await ArveilRust.init();
  runApp(const ArveilApp());
}

class ArveilApp extends StatelessWidget {
  const ArveilApp({super.key, this.session, this.kitFiles = const KitFiles()});
  final ProfileSession? session;
  final KitFiles kitFiles;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Arveil',
    debugShowCheckedModeBanner: false,
    theme: ArveilTheme.light(),
    darkTheme: ArveilTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    localeListResolutionCallback: resolveLocale,
    builder: (context, child) {
      useStrings(context.l10n);
      return child!;
    },
    home: ProfilePage(session: session, kitFiles: kitFiles),
  );
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, this.session, required this.kitFiles});
  final ProfileSession? session;
  final KitFiles kitFiles;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final ProfileSession _session = widget.session ?? ProfileSession();
  final _form = GlobalKey<FormState>();
  final _kitPanel = GlobalKey();
  String _entry = 'enroll';
  final _bootstrap = TextEditingController();
  final _invite = TextEditingController();

  @override
  void dispose() {
    _bootstrap.dispose();
    _invite.dispose();
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    await _session.open();
    if (!mounted) return;
    _bootstrap.text = _session.setup?.bootstrap ?? '';
    setState(() => _entry = 'enroll');
  }

  Future<void> _enroll() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    final success = await _session.enroll(
      _bootstrap.text.trim(),
      _invite.text.trim(),
    );
    if (!mounted) return;
    if (success || _session.setup?.stage == SetupStage.ready) _invite.clear();
  }

  Future<void> _close() async {
    _invite.clear();
    if (await _session.close() && mounted) _bootstrap.clear();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Arveil'),
        actions: [
          if (_session.isOpen)
            TextButton.icon(
              onPressed: _session.busy || _session.cancellingPairing
                  ? null
                  : _close,
              icon: const Icon(Icons.lock_outline),
              label: Text(context.l10n.profileClose),
            ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (!_session.isOpen)
                  ..._welcome(context)
                else if (_session.setup == null) ...[
                  Text(context.l10n.profileStateUnreadable),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _session.busy ? null : _session.refresh,
                    child: Text(context.l10n.profileReadAgain),
                  ),
                ] else if (_session.setup!.stage == SetupStage.ready)
                  ..._ready(context)
                else if (_session.setup!.stage == SetupStage.recovering)
                  RecoveryResumePanel(session: _session)
                else if (_session.setup!.stage == SetupStage.linkedDevice ||
                    _session.setup!.pairing != null ||
                    _entry == 'pair') ...[
                  PairingPanel(
                    key: const Key('pair-new-device'),
                    session: _session,
                  ),
                  if (_session.setup!.stage == SetupStage.new_ &&
                      _session.setup!.pairing == null)
                    TextButton(
                      onPressed: _session.busy
                          ? null
                          : () => setState(() => _entry = 'enroll'),
                      child: Text(context.l10n.enrollBack),
                    ),
                ] else if (_entry == 'restore') ...[
                  RecoveryPanel(
                    key: const Key('restore-panel'),
                    session: _session,
                    files: widget.kitFiles,
                  ),
                  TextButton(
                    onPressed: _session.busy
                        ? null
                        : () => setState(() => _entry = 'enroll'),
                    child: Text(context.l10n.enrollBack),
                  ),
                ] else
                  ..._onboarding(context),
                if (_session.busy) ...[
                  const SizedBox(height: 24),
                  LinearProgressIndicator(
                    semanticsLabel: context.l10n.operationInProgress,
                  ),
                  const SizedBox(height: 12),
                  Text(context.l10n.operationInProgressDetail),
                ],
                if (_session.error case final message?) ...[
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
            ),
          ),
        ),
      ),
    ),
  );

  List<Widget> _welcome(BuildContext context) => [
    const SizedBox(height: 36),
    const Align(
      alignment: Alignment.centerLeft,
      child: Icon(Icons.shield_outlined, size: 44),
    ),
    const SizedBox(height: 24),
    Text(
      context.l10n.welcomeTitle,
      style: Theme.of(context).textTheme.headlineLarge,
    ),
    const SizedBox(height: 16),
    Text(context.l10n.welcomeBody),
    const SizedBox(height: 16),
    Text(context.l10n.welcomeKeyNote),
    const SizedBox(height: 28),
    FilledButton.icon(
      onPressed: _session.busy ? null : _open,
      icon: const Icon(Icons.arrow_forward),
      label: Text(context.l10n.profileOpen),
    ),
  ];

  List<Widget> _onboarding(BuildContext context) {
    final l10n = context.l10n;
    final state = _session.setup!;
    final retry =
        state.stage != SetupStage.new_ &&
        state.stage != SetupStage.identityReady;
    return [
      Text(
        retry ? l10n.enrollTitleRetry : l10n.enrollTitle,
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 16),
      Text(retry ? l10n.enrollBodyRetry : l10n.enrollBody),
      const SizedBox(height: 20),
      Text(switch (state.stage) {
        SetupStage.redeeming => l10n.setupRedeeming,
        SetupStage.redeemed => l10n.setupRedeemed,
        SetupStage.publishing => l10n.setupPublishing,
        SetupStage.identityReady => l10n.setupIdentityReady,
        _ => l10n.setupNew,
      }, key: const Key('setup-status')),
      const SizedBox(height: 24),
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('bootstrap'),
              controller: _bootstrap,
              enabled: !_session.busy,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: l10n.enrollRelayLabel,
                hintText: 'arveil-bootstrap:v0:…',
              ),
              validator: (value) =>
                  (value ?? '').trim().startsWith('arveil-bootstrap:v0:')
                  ? null
                  : l10n.enrollRelayInvalid,
            ),
            const SizedBox(height: 20),
            TextFormField(
              key: const Key('invite'),
              controller: _invite,
              enabled: !_session.busy,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l10n.enrollInviteLabel,
                helperText: l10n.enrollInviteHelper,
              ),
              validator: (value) =>
                  RegExp(r'^[0-9a-fA-F]{64}$').hasMatch((value ?? '').trim())
                  ? null
                  : l10n.enrollInviteInvalid,
              onFieldSubmitted: (_) {
                if (!_session.busy) _enroll();
              },
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _session.busy ? null : _enroll,
              icon: const Icon(Icons.arrow_forward),
              label: Text(retry ? l10n.enrollRetry : l10n.enrollSubmit),
            ),
          ],
        ),
      ),
      if (state.stage == SetupStage.new_) ...[
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: _session.busy
              ? null
              : () {
                  _invite.clear();
                  setState(() => _entry = 'pair');
                },
          child: Text(l10n.enrollPair),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _session.busy
              ? null
              : () {
                  _invite.clear();
                  setState(() => _entry = 'restore');
                },
          child: Text(l10n.enrollRestore),
        ),
      ],
    ];
  }

  /// Why the administration device should save a kit now, or nothing.
  String? _kitReminder(AppLocalizations l10n) {
    final setup = _session.setup!;
    if (!setup.administrator || _session.kitReminderDismissed) return null;
    if (setup.kitSavedAt == null) {
      return l10n.kitReminderNever;
    }
    if (setup.kitStale) {
      return l10n.kitReminderStale;
    }
    return null;
  }

  List<Widget> _ready(BuildContext context) => [
    const Icon(Icons.check_circle_outline, size: 48),
    const SizedBox(height: 20),
    Text(
      context.l10n.readyTitle,
      style: Theme.of(context).textTheme.headlineLarge,
    ),
    const SizedBox(height: 16),
    Text(context.l10n.readyBody),
    const SizedBox(height: 24),
    if (_kitReminder(context.l10n) case final message?) ...[
      Card(
        key: const Key('kit-reminder'),
        color: Theme.of(context).colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: () {
                      final panel = _kitPanel.currentContext;
                      if (panel != null) Scrollable.ensureVisible(panel);
                    },
                    child: Text(context.l10n.kitSave),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => _session.kitReminderDismissed = true),
                    child: Text(context.l10n.later),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
    ],
    if (_session.setup!.recoveryWarning) ...[
      Text(context.l10n.recoveryRollbackWarning),
      const SizedBox(height: 24),
    ],
    FilledButton.icon(
      onPressed: _session.busy
          ? null
          : () {
              final controller = ConversationController(
                _session.profile!,
                _session.setup!.bootstrap!,
              );
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ConversationsPage(controller: controller),
                ),
              );
            },
      icon: const Icon(Icons.forum_outlined),
      label: Text(context.l10n.openConversations),
    ),

    const SizedBox(height: 24),
    OutlinedButton.icon(
      key: const Key('open-devices'),
      onPressed: _session.busy
          ? null
          : () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => DevicesPage(
                  profile: _session.profile!,
                  bootstrap: _session.setup!.bootstrap!,
                ),
              ),
            ),
      icon: const Icon(Icons.devices),
      label: Text(context.l10n.manageDevices),
    ),
    const SizedBox(height: 24),
    OutlinedButton.icon(
      key: const Key('open-archives'),
      onPressed: _session.busy
          ? null
          : () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => ArchivesPage(profile: _session.profile!),
              ),
            ),
      icon: const Icon(Icons.history),
      label: Text(context.l10n.encryptedHistory),
    ),
    const SizedBox(height: 24),
    KeyPackagesPanel(session: _session),
    const Divider(height: 48),
    if (_session.setup!.administrator) ...[
      KeyedSubtree(
        key: _kitPanel,
        child: RecoveryPanel(
          key: const Key('export-panel'),
          session: _session,
          files: widget.kitFiles,
          export: true,
        ),
      ),
      const Divider(height: 48),
      PairingPanel(
        key: const Key('pair-administration'),
        session: _session,
        administration: true,
      ),
      const Divider(height: 48),
    ] else ...[
      Text(context.l10n.linkedDeviceKitNote),
      const SizedBox(height: 24),
    ],
  ];
}
