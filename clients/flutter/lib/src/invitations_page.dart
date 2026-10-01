import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/l10n.dart';
import 'design/design.dart';
import 'design/qr_code.dart';
import 'qr_scanner.dart';
import 'rust/api/profile.dart';
import 'share_text.dart';

String invitationFailure(AppLocalizations l, Object error) => switch (error) {
  InvitationProblem.offline => l.inviteOffline,
  InvitationProblem.notAllowed => l.inviteNotAllowed,
  InvitationProblem.unavailable => l.inviteUnavailable,
  InvitationProblem.alreadyUsed => l.inviteAlreadyUsed,
  InvitationProblem.otherServer => l.inviteOtherServer,
  InvitationProblem.ownInvitation => l.inviteOwn,
  InvitationProblem.pendingOperation => l.inviteAnotherPending,
  InvitationProblem.oldServer => l.inviteOldServer,
  InvitationProblem.noKeys => l.inviteNoKeys,
  InvitationProblem.busy => l.inviteBusy,
  InvitationProblem.storage => l.inviteStorage,
  _ => l.inviteFailed,
};

String invitationState(AppLocalizations l, String state) => switch (state) {
  'pending' => l.inviteWaiting,
  'used' => l.inviteUsed,
  'connected' || 'complete' => l.inviteConnected,
  'expired' => l.inviteExpired,
  'revoked' => l.inviteRevoked,
  'revoke-pending' => l.inviteRevoking,
  'issuing' => l.inviteIssuing,
  'enrolled' || 'prepared' => l.inviteConnecting,
  _ => l.inviteAccepting,
};

String _date(BuildContext context, int seconds) {
  // Imported codes may contain any u64. Never let a date crash the preview.
  if (seconds < 0 || seconds > 8640000000000) return '—';
  return MaterialLocalizations.of(
    context,
  ).formatMediumDate(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
}

/// Invitations issued here can be shared again without extending expiry.
/// Other linked devices can list/revoke them, but never recover their secrets.
class InvitationsPage extends StatefulWidget {
  const InvitationsPage({super.key, required this.profile});
  final Profile profile;
  @override
  State<InvitationsPage> createState() => _InvitationsPageState();
}

class _InvitationsPageState extends State<InvitationsPage> {
  List<InvitationView> _rows = [];
  bool _busy = true;
  bool? _allowed;
  String? _identity;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final cached = await widget.profile.invitations(refresh: false);
      if (mounted) setState(() => _rows = cached);
      final setup = await widget.profile.setup();
      if (mounted) setState(() => _identity = setup.identityId);
      final allowed = await widget.profile.invitationPolicy();
      if (mounted) setState(() => _allowed = allowed);
      final rows = await widget.profile.invitations(refresh: true);
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = invitationFailure(context.l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change(Future<InvitationView> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final row = await action();
      final rows = await widget.profile.invitations(refresh: false);
      if (!mounted) return;
      setState(() => _rows = rows);
      if (row.link != null) await _show(row);
    } catch (e) {
      if (mounted) setState(() => _error = invitationFailure(context.l10n, e));
      try {
        final rows = await widget.profile.invitations(refresh: false);
        if (mounted) setState(() => _rows = rows);
      } catch (_) {
        /* Preserve the last view if local storage is unavailable. */
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _show(InvitationView row) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          InvitationCodePage(profile: widget.profile, invitation: row),
    ),
  );

  Future<void> _shareApp() async {
    const link = 'https://arveil.kaicorplabs.com';
    if (!await shareText(link)) {
      await Clipboard.setData(const ClipboardData(text: link));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.cardLinkCopied)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.inviteTitle),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: l.retry,
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(l.inviteHelp),
                const SizedBox(height: 16),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: StatusBanner(
                      title: _error!,
                      icon: Icons.error_outline,
                      tone: BannerTone.error,
                    ),
                  ),
                if (_allowed == false)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(l.inviteNotAllowed),
                  ),
                FilledButton.icon(
                  key: const Key('invite-create'),
                  onPressed: _busy || _allowed != true
                      ? null
                      : () => _change(() => widget.profile.createInvitation()),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: Text(l.inviteCreate),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _shareApp,
                  icon: const Icon(Icons.share_outlined),
                  label: Text(l.inviteShareApp),
                ),
                const SizedBox(height: 24),
                Text(
                  l.inviteListTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(l.inviteLocalList),
                if (_identity != null)
                  ExpansionTile(
                    title: Text(l.invitePermissionDetails),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.invitePermissionHelp),
                            const SizedBox(height: 8),
                            SelectableText(
                              _identity!,
                              key: const Key('invite-owner-identity'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                if (_rows.isEmpty && !_busy)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(l.inviteEmpty),
                  ),
                for (final row in _rows)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            invitationState(l, row.state),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(l.inviteExpires(_date(context, row.expiresAt))),
                          if (row.checkedAt > 0)
                            Text(
                              l.inviteChecked(_date(context, row.checkedAt)),
                            ),
                          if (row.state == 'pending' && row.link == null)
                            Text(l.inviteOtherDevice),
                          Wrap(
                            spacing: 8,
                            children: [
                              if (row.link != null)
                                TextButton(
                                  onPressed: _busy ? null : () => _show(row),
                                  child: Text(l.inviteShow),
                                ),
                              if (row.state == 'issuing')
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _change(
                                          () => widget.profile.createInvitation(
                                            id: row.id,
                                          ),
                                        ),
                                  child: Text(l.retry),
                                ),
                              if (_allowed == true &&
                                  [
                                    'pending',
                                    'revoke-pending',
                                    'issuing',
                                  ].contains(row.state))
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _change(
                                          () => widget.profile.revokeInvitation(
                                            id: row.id,
                                          ),
                                        ),
                                  child: Text(l.cardRevoke),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class InvitationCodePage extends StatefulWidget {
  const InvitationCodePage({
    super.key,
    required this.profile,
    required this.invitation,
  });
  final Profile profile;
  final InvitationView invitation;
  @override
  State<InvitationCodePage> createState() => _InvitationCodePageState();
}

class _InvitationCodePageState extends State<InvitationCodePage> {
  Timer? _expiry;
  bool get _expired =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 >=
      widget.invitation.expiresAt;
  @override
  void initState() {
    super.initState();
    _expiry = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_expired && mounted) {
        _expiry?.cancel();
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  Future<void> _share() async {
    if (_expired) return;
    final text =
        '${context.l10n.inviteShareMessage}\n${widget.invitation.link!}';
    if (!await shareText(text)) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.cardLinkCopied)));
      }
    }
  }

  Future<void> _copy() async {
    if (_expired) return;
    await Clipboard.setData(ClipboardData(text: widget.invitation.link!));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.cardLinkCopied)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.inviteShow)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(l.invitePrivate),
                const SizedBox(height: 16),
                if (_expired)
                  Text(l.inviteExpired)
                else
                  LayoutBuilder(
                    builder: (context, bounds) => Center(
                      child: QrCodeView(
                        profile: widget.profile,
                        text: widget.invitation.link!,
                        label: l.inviteShow,
                        size: bounds.maxWidth.clamp(0, 400).toDouble(),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  l.inviteExpires(_date(context, widget.invitation.expiresAt)),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('invite-share'),
                  onPressed: _expired ? null : _share,
                  icon: const Icon(Icons.share_outlined),
                  label: Text(l.inviteShare),
                ),
                TextButton.icon(
                  key: const Key('invite-copy'),
                  onPressed: _expired ? null : _copy,
                  icon: const Icon(Icons.copy_outlined),
                  label: Text(l.pairingCopyLink),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<String?> openPersonalInvitation(
  BuildContext context, {
  required Profile profile,
  String? text,
  Future<void> Function()? onChanged,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    builder: (_) => AcceptInvitationPage(
      profile: profile,
      text: text,
      onChanged: onChanged,
    ),
  ),
);

/// Parsing is local. No server request or identity creation happens before
/// the explicit consent button. A pending operation lives in the core.
class AcceptInvitationPage extends StatefulWidget {
  const AcceptInvitationPage({
    super.key,
    required this.profile,
    this.text,
    this.onChanged,
  });
  final Profile profile;
  final String? text;
  final Future<void> Function()? onChanged;
  @override
  State<AcceptInvitationPage> createState() => _AcceptInvitationPageState();
}

class _AcceptInvitationPageState extends State<AcceptInvitationPage> {
  final _name = TextEditingController();
  CardView_Invitation? _card;
  InvitationView? _pending;
  bool _loading = true, _busy = false, _valid = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final pending = await widget.profile.pendingInvitation();
      final card = widget.text == null
          ? null
          : await widget.profile.readCard(text: widget.text!);
      final name = await widget.profile.cardName();
      if (!mounted) return;
      setState(() {
        _card = card is CardView_Invitation ? card : null;
        _pending = pending;
        _name.text = name ?? '';
        _valid = _card != null || (widget.text == null && _pending != null);
        if (!_valid) _error = context.l10n.inviteFailed;
      });
    } catch (e) {
      if (mounted) setState(() => _error = invitationFailure(context.l10n, e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    InvitationView? result;
    try {
      result = await widget.profile.acceptInvitation(
        text: widget.text,
        name: _name.text.trim().isEmpty ? null : _name.text.trim(),
      );
    } catch (e) {
      if (mounted) setState(() => _error = invitationFailure(context.l10n, e));
    } finally {
      try {
        final pending = await widget.profile.pendingInvitation();
        if (mounted) setState(() => _pending = pending);
      } catch (_) {}
      await widget.onChanged?.call();
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && result?.state == 'complete') {
      Navigator.of(context).pop(result!.groupId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final name = _card?.name ?? _pending?.name;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(l.inviteAcceptTitle)),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  if (_loading || _busy) const LinearProgressIndicator(),
                  if (!_loading && _valid) ...[
                    Text(
                      name == null ? l.inviteUnnamed : l.inviteFrom(name),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    Text(l.inviteConsent),
                    if (_card case final card?) ...[
                      const SizedBox(height: 12),
                      Text(l.inviteServer(card.server)),
                      Text(
                        l.inviteExpires(_date(context, card.expiresAt.toInt())),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(l.inviteUnverified),
                    if (_pending == null) ...[
                      const SizedBox(height: 20),
                      TextField(
                        key: const Key('invite-name'),
                        controller: _name,
                        maxLength: 64,
                        enabled: !_busy,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        decoration: InputDecoration(
                          labelText: l.cardNameLabel,
                          helperText: l.inviteNameHelp,
                          helperMaxLines: 3,
                        ),
                      ),
                    ],
                    if (_pending != null) ...[
                      const SizedBox(height: 16),
                      Text(invitationState(l, _pending!.state)),
                      Text(l.inviteResumeHelp),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('invite-accept'),
                      onPressed: _busy ? null : _accept,
                      child: Text(
                        _pending == null ? l.inviteAccept : l.inviteResume,
                      ),
                    ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: StatusBanner(
                        title: _error!,
                        icon: Icons.error_outline,
                        tone: BannerTone.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The normal first-run input. Legacy server/token entry is a separate link.
class InvitationInput extends StatefulWidget {
  const InvitationInput({
    super.key,
    required this.profile,
    required this.onOpen,
    required this.onLegacy,
  });
  final Profile profile;
  final Future<void> Function(String) onOpen;
  final VoidCallback onLegacy;
  @override
  State<InvitationInput> createState() => _InvitationInputState();
}

class _InvitationInputState extends State<InvitationInput> {
  final _text = TextEditingController();
  bool _busy = false;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _open(String text) async {
    if (_busy || text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.onOpen(text.trim());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final text = await scanCode(
      context,
      profile: widget.profile,
      accept: (c) => c is CardView_Invitation || c is CardView_Join,
      wrongCode: context.l10n.inviteWrongCode,
    );
    if (text != null && mounted) await _open(text);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.inviteInputHelp),
        const SizedBox(height: 20),
        if (canScan)
          FilledButton.icon(
            key: const Key('invite-scan'),
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(l.inviteScan),
          ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('invite-input'),
          controller: _text,
          minLines: 2,
          maxLines: 4,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          decoration: InputDecoration(labelText: l.inviteLinkLabel),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('invite-open'),
          onPressed: _busy ? null : () => _open(_text.text),
          child: Text(l.inviteOpen),
        ),
        TextButton(
          onPressed: _busy ? null : widget.onLegacy,
          child: Text(l.inviteLegacy),
        ),
      ],
    );
  }
}
