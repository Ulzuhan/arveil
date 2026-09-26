import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'kit_files.dart';
import 'export_secret.dart';
import 'profile_session.dart';

class RecoveryPanel extends StatefulWidget {
  const RecoveryPanel({
    super.key,
    required this.session,
    required this.files,
    this.export = false,
  });
  final ProfileSession session;
  final KitFiles files;
  final bool export;

  @override
  State<RecoveryPanel> createState() => _RecoveryPanelState();
}

class _RecoveryPanelState extends State<RecoveryPanel>
    with WidgetsBindingObserver {
  final _relay = TextEditingController();
  final _secretInput = TextEditingController();
  List<int>? _encrypted;
  final _exportedSecret = ExportSecret();
  bool _confirmed = false;
  bool _picking = false;
  bool _deferred = false;
  bool _saved = false;
  ProfileSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _relay.text = session.setup?.bootstrap ?? '';
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _secretInput.clear();
    }
    setState(() => _exportedSecret.lifecycle(state));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _relay.dispose();
    _secretInput.dispose();
    _exportedSecret.clear();
    _encrypted = null;
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _exportedSecret.clear();
      _saved = false;
    });
    final secret = await session.saveKit(widget.files.save);
    if (mounted && secret != null) {
      setState(() {
        _exportedSecret.saved(secret, WidgetsBinding.instance.lifecycleState);
        _deferred = false;
      });
    }
  }

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final bytes = await widget.files.open();
      if (mounted && bytes != null) setState(() => _encrypted = bytes);
    } catch (error) {
      session.reportFailure(error);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _restore() async {
    if (!_confirmed ||
        _encrypted == null ||
        _secretInput.text.trim().isEmpty ||
        !_relay.text.trim().startsWith('arveil-bootstrap:v0:')) {
      session.reportFailure(
        ProfileAccessException(context.l10n.recoveryIncomplete),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    final secret = _secretInput.text.trim();
    final encrypted = _encrypted!;
    _secretInput.clear();
    setState(() {
      _encrypted = null;
      _confirmed = false;
    });
    await session.restoreKit(_relay.text.trim(), encrypted, secret);
  }

  @override
  Widget build(BuildContext context) =>
      widget.export ? _export(context) : _import(context);

  Widget _export(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        context.l10n.kitTitle,
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      Text(context.l10n.kitExplanation),
      const SizedBox(height: 12),
      if (_exportedSecret.pending)
        OutlinedButton(
          onPressed: () => setState(
            () =>
                _exportedSecret.reveal(WidgetsBinding.instance.lifecycleState),
          ),
          child: Text(context.l10n.kitRevealSavedKey),
        ),
      if (_exportedSecret.visible case final secret?) ...[
        Text(context.l10n.kitSavedKeyNow),
        const SizedBox(height: 12),
        SelectableText(secret, key: const Key('kit-export-secret')),
        const SizedBox(height: 12),
        Text(context.l10n.kitKeyDisappears),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () {
            setState(() {
              _exportedSecret.clear();
              _saved = true;
            });
            session.confirmKitSaved();
          },
          child: Text(context.l10n.kitKeySavedConfirm),
        ),
      ] else ...[
        if (_saved) Text(context.l10n.kitSavedByConfirmation),
        if (_deferred)
          Text(
            context.l10n.kitDeferredWarning,
            key: Key('kit-deferred-warning'),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: session.busy ? null : _save,
          icon: const Icon(Icons.save_alt),
          label: Text(context.l10n.kitSaveEncrypted),
        ),
        if (!_saved && !_deferred)
          TextButton(
            onPressed: session.busy
                ? null
                : () => setState(() => _deferred = true),
            child: Text(context.l10n.kitPostpone),
          ),
      ],
    ],
  );

  Widget _import(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        context.l10n.recoveryTitle,
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 16),
      Text(context.l10n.recoveryExplanation),
      const SizedBox(height: 20),
      TextFormField(
        key: const Key('recovery-bootstrap'),
        controller: _relay,
        enabled: !session.busy && !_picking,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        minLines: 2,
        maxLines: 4,
        decoration: InputDecoration(labelText: context.l10n.recoveryRelayLabel),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: session.busy || _picking ? null : _pick,
        icon: const Icon(Icons.folder_open),
        label: Text(
          _encrypted == null
              ? context.l10n.recoveryChooseKit
              : context.l10n.recoveryKitChosen,
        ),
      ),
      const SizedBox(height: 16),
      TextFormField(
        key: const Key('recovery-secret'),
        controller: _secretInput,
        enabled: !session.busy && !_picking,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        decoration: InputDecoration(labelText: context.l10n.recoveryKitKey),
      ),
      const SizedBox(height: 12),
      CheckboxListTile(
        key: const Key('recovery-confirm'),
        contentPadding: EdgeInsets.zero,
        value: _confirmed,
        onChanged: session.busy || _picking
            ? null
            : (value) => setState(() => _confirmed = value ?? false),
        title: Text(context.l10n.recoveryConsent),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: session.busy || _picking || !_confirmed ? null : _restore,
        child: Text(context.l10n.recoveryRestore),
      ),
    ],
  );
}

class RecoveryResumePanel extends StatelessWidget {
  const RecoveryResumePanel({super.key, required this.session});
  final ProfileSession session;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        context.l10n.recoveryResumeTitle,
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 16),
      Text(context.l10n.recoveryResumeBody),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: session.busy ? null : session.resumeRecovery,
        child: Text(context.l10n.recoveryResume),
      ),
    ],
  );
}
