import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'about_page.dart';
import 'design/design.dart';
import 'home_shell.dart';
import 'incoming_links.dart';
import 'kit_files.dart';
import 'pairing_panel.dart';
import 'profile_session.dart';
import 'recovery_panel.dart';
import 'rust/api/profile.dart';
import 'settings_page.dart';
import 'updates/page.dart';

/// How a profile without an identity gets one.
enum Entry { invitation, pairing, restore }

/// What one pasted message holds: the server details and, when the
/// administrator sent both together, the invitation. Labels and other text
/// around them are ignored, and two different invitations are not guessed
/// between.
({String? bootstrap, String? invite}) splitInvitation(String text) {
  final bootstrap = RegExp(
    r'arveil-bootstrap:v0:\S+',
  ).firstMatch(text)?.group(0);
  final rest = bootstrap == null ? text : text.replaceFirst(bootstrap, ' ');
  final invites = {
    for (final match in RegExp(
      r'(?<![0-9A-Fa-f:])[0-9A-Fa-f]{64}(?![0-9A-Fa-f:])',
    ).allMatches(rest))
      match.group(0)!.toLowerCase(),
  };
  return (
    bootstrap: bootstrap,
    invite: invites.length == 1 ? invites.single : null,
  );
}

/// Opens the profile and routes it: the welcome while closed, the three
/// ways to get an identity, enrollment until the identity is ready, an
/// offer to save the kit right after, and then the main navigation.
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, this.session, required this.kitFiles});
  final ProfileSession? session;
  final KitFiles kitFiles;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final ProfileSession _session = widget.session ?? ProfileSession();
  final _serverForm = GlobalKey<FormState>();
  final _form = GlobalKey<FormState>();
  final _bootstrap = TextEditingController();
  final _invite = TextEditingController();
  Entry? _entry;

  /// Second step of the invitation: the server details are in.
  bool _serverDone = false;

  /// The invitation came in the same message as the server details.
  bool _inviteFound = false;

  /// Why the pasted text is not an invitation link, when it looked like one.
  CardProblem? _cardProblem;
  bool _otherCard = false;

  /// An identity just became ready here without a current kit.
  bool _offerKit = false;
  SetupStage? _lastStage;

  /// A link to link this device, opened from outside (ADR-012 §5).
  String? _pairingLink;

  @override
  void initState() {
    super.initState();
    // Registered before the builder below, so the offer is decided before
    // the rebuild that shows the main navigation.
    _session.addListener(_onSession);
    incomingLinks.addListener(_onLink);
  }

  /// An invitation or a code to link this device, opened from outside,
  /// fills the matching screen; the person still presses its button. A
  /// contact card waits for the identity to be ready.
  Future<void> _onLink() async {
    final link = incomingLinks.pending;
    final profile = _session.profile;
    final setup = _session.setup;
    if (link == null ||
        profile == null ||
        setup == null ||
        setup.stage == SetupStage.ready) {
      return;
    }
    final CardView card;
    try {
      card = await profile.readCard(text: link);
    } catch (_) {
      incomingLinks.take();
      return;
    }
    if (!mounted || incomingLinks.pending != link) return;
    switch (card) {
      case CardView_Join():
        incomingLinks.take();
        _invite.clear();
        _bootstrap.text = link;
        setState(() {
          _entry = Entry.invitation;
          _serverDone = false;
          _inviteFound = false;
        });
      case CardView_Link():
        incomingLinks.take();
        setState(() {
          _entry = Entry.pairing;
          _pairingLink = link;
        });
      case CardView_Contact() || CardView_Other():
        break;
    }
  }

  void _onSession() {
    final setup = _session.setup;
    final stage = setup?.stage;
    if (_lastStage != null &&
        _lastStage != SetupStage.ready &&
        stage == SetupStage.ready &&
        setup!.administrator &&
        (setup.kitSavedAt == null || setup.kitStale)) {
      _offerKit = true;
    }
    _lastStage = stage;
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    incomingLinks.removeListener(_onLink);
    _bootstrap.dispose();
    _invite.dispose();
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    await _session.open();
    if (!mounted) return;
    _bootstrap.text = _session.setup?.bootstrap ?? '';
    setState(() {
      _entry = null;
      _serverDone = false;
    });
    await _onLink();
  }

  void _choose(Entry? entry) {
    _invite.clear();
    setState(() {
      _entry = entry;
      _serverDone = false;
      _inviteFound = false;
    });
  }

  /// Keeps only the server details in their field, and fills an empty
  /// invitation from the same message. An invitation link (ADR-012) gives
  /// both at once; the older strings are still found by their shape.
  Future<void> _split() async {
    _cardProblem = null;
    _otherCard = false;
    final text = _bootstrap.text;
    final profile = _session.profile;
    if (profile != null && !text.contains('arveil-bootstrap:v0:')) {
      try {
        final card = await profile.readCard(text: text);
        switch (card) {
          case CardView_Join(:final bootstrap, :final invitation):
            _bootstrap.text = bootstrap;
            if (_invite.text.trim().isEmpty) {
              _invite.text = invitation;
              _inviteFound = true;
            }
            return;
          case CardView_Link() || CardView_Contact() || CardView_Other():
            _otherCard = true;
            return;
        }
      } on CardProblem catch (problem) {
        // Plain text is not a link; anything else says what went wrong.
        if (problem != CardProblem.notALink) _cardProblem = problem;
      } catch (_) {
        // A reader that failed leaves the older shapes to be looked for.
      }
    }
    final found = splitInvitation(_bootstrap.text);
    if (found.bootstrap case final bootstrap?) _bootstrap.text = bootstrap;
    if (found.invite case final invite? when _invite.text.trim().isEmpty) {
      _invite.text = invite;
      _inviteFound = true;
    }
  }

  Future<void> _nextStep() async {
    await _split();
    if (!mounted) return;
    if (!(_serverForm.currentState?.validate() ?? false)) {
      setState(() {});
      return;
    }
    setState(() => _serverDone = true);
  }

  Future<void> _enroll() async {
    await _split();
    if (!mounted) return;
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
    _offerKit = false;
    if (await _session.close() && mounted) {
      _bootstrap.clear();
      setState(() {
        _entry = null;
        _serverDone = false;
      });
    }
  }

  bool get _ready =>
      _session.isOpen && _session.setup?.stage == SetupStage.ready;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      if (_ready && !_offerKit) {
        return HomeShell(
          session: _session,
          kitFiles: widget.kitFiles,
          onClose: _close,
        );
      }
      return _frame(context, _ready ? _kitOffer(context) : _steps(context));
    },
  );

  /// A centred column under a quiet bar that can close an open profile.
  Widget _frame(BuildContext context, List<Widget> children) => Scaffold(
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      actions: [
        IconButton(
          key: const Key('welcome-about'),
          onPressed: () => openAbout(context),
          tooltip: context.l10n.aboutTitle,
          icon: const Icon(Icons.info_outline),
        ),
        if (UpdateScope.maybeOf(context) case final updates?)
          IconButton(
            key: const Key('welcome-updates'),
            onPressed: () => openUpdates(context, updates),
            tooltip: context.l10n.updatesTitle,
            icon: const Icon(Icons.system_update_outlined),
          ),
        if (_session.isOpen)
          // With large text the label would not fit beside the title.
          MediaQuery.textScalerOf(context).scale(10) > 13
              ? IconButton(
                  onPressed: _session.busy || _session.cancellingPairing
                      ? null
                      : _close,
                  tooltip: context.l10n.profileClose,
                  icon: const Icon(Icons.lock_outline),
                )
              : TextButton.icon(
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
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            children: [
              ...children,
              SessionActivity(session: _session),
            ],
          ),
        ),
      ),
    ),
  );

  List<Widget> _steps(BuildContext context) {
    final l10n = context.l10n;
    if (!_session.isOpen) return _welcome(context);
    final setup = _session.setup;
    if (setup == null) {
      return [
        Text(l10n.profileStateUnreadable),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _session.busy ? null : _session.refresh,
          child: Text(l10n.profileReadAgain),
        ),
      ];
    }
    final fresh = setup.stage == SetupStage.new_;
    if (setup.stage == SetupStage.recovering) {
      return [RecoveryResumePanel(session: _session)];
    }
    if (setup.stage == SetupStage.linkedDevice ||
        setup.pairing != null ||
        _entry == Entry.pairing) {
      return [
        if (fresh && setup.pairing == null) _back(context),
        PairingPanel(
          key: const Key('pair-new-device'),
          session: _session,
          initialLink: _pairingLink,
        ),
      ];
    }
    if (_entry == Entry.restore) {
      return [
        _back(context),
        RecoveryPanel(
          key: const Key('restore-panel'),
          session: _session,
          files: widget.kitFiles,
        ),
      ];
    }
    if (fresh && _entry == null) return _choices(context);
    return _invitation(context, setup);
  }

  Widget _back(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: _session.busy ? null : () => _choose(null),
        icon: const Icon(Icons.arrow_back),
        label: Text(context.l10n.enrollBack),
      ),
    ),
  );

  Widget _title(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      style: ArveilType.screenTitle.copyWith(
        color: ArveilColors.of(context).ink,
      ),
    ),
  );

  List<Widget> _welcome(BuildContext context) {
    final l10n = context.l10n;
    final c = ArveilColors.of(context);
    return [
      const SizedBox(height: 24),
      const Align(alignment: Alignment.centerLeft, child: BrandMark(size: 64)),
      const SizedBox(height: 28),
      _title(context, l10n.welcomeTitle),
      Text(l10n.welcomeBody, style: ArveilType.preview.copyWith(color: c.ink)),
      const SizedBox(height: 20),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 18, color: c.inkMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.welcomeKeyNote,
              style: ArveilType.secondary.copyWith(color: c.inkMuted),
            ),
          ),
        ],
      ),
      const SizedBox(height: 32),
      FilledButton.icon(
        onPressed: _session.busy ? null : _open,
        icon: const Icon(Icons.arrow_forward),
        label: Text(l10n.profileOpen),
      ),
    ];
  }

  /// The three ways to get an identity on this device.
  List<Widget> _choices(BuildContext context) {
    final l10n = context.l10n;
    return [
      _title(context, l10n.startTitle),
      Text(
        l10n.startBody,
        style: ArveilType.preview.copyWith(color: ArveilColors.of(context).ink),
      ),
      const SizedBox(height: 8),
      SettingsGroup(
        children: [
          SettingsRow(
            key: const Key('entry-invitation'),
            icon: Icons.mail_outline,
            title: l10n.entryInvitation,
            subtitle: l10n.entryInvitationHelp,
            onTap: _session.busy ? null : () => _choose(Entry.invitation),
          ),
          SettingsRow(
            key: const Key('entry-pairing'),
            icon: Icons.add_link,
            title: l10n.enrollPair,
            subtitle: l10n.entryPairingHelp,
            onTap: _session.busy ? null : () => _choose(Entry.pairing),
          ),
          SettingsRow(
            key: const Key('entry-restore'),
            icon: Icons.restore,
            title: l10n.enrollRestore,
            subtitle: l10n.entryRestoreHelp,
            onTap: _session.busy ? null : () => _choose(Entry.restore),
          ),
        ],
      ),
    ];
  }

  Widget _stepLabel(BuildContext context, int step) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        for (var i = 1; i <= 2; i++) ...[
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: i <= step
                    ? ArveilColors.of(context).accent
                    : ArveilColors.of(context).lineStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (i < 2) const SizedBox(width: 6),
        ],
        const SizedBox(width: 12),
        Text(
          context.l10n.enrollStep(step, 2),
          style: ArveilType.label.copyWith(
            color: ArveilColors.of(context).inkMuted,
          ),
        ),
      ],
    ),
  );

  TextFormField _serverField(AppLocalizations l10n) => TextFormField(
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
      hintText: l10n.enrollRelayHint,
    ),
    validator: (value) {
      if ((value ?? '').trim().startsWith('arveil-bootstrap:v0:')) return null;
      if (_otherCard) return l10n.cardNotInvitation;
      return switch (_cardProblem) {
        CardProblem.newerVersion => l10n.cardNewerVersion,
        CardProblem.ambiguous => l10n.cardAmbiguous,
        CardProblem.wrongKind ||
        CardProblem.damaged ||
        CardProblem.tooLarge => l10n.cardDamaged,
        CardProblem.notALink || null => l10n.enrollRelayInvalid,
      };
    },
  );

  TextFormField _inviteField(AppLocalizations l10n) => TextFormField(
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
  );

  Widget _status(BuildContext context, SetupView setup) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SyncLine(
        key: const Key('setup-status'),
        reached: null,
        text: switch (setup.stage) {
          SetupStage.redeeming => l10n.setupRedeeming,
          SetupStage.redeemed => l10n.setupRedeemed,
          SetupStage.publishing => l10n.setupPublishing,
          SetupStage.identityReady => l10n.setupIdentityReady,
          _ => l10n.setupNew,
        },
      ),
    );
  }

  /// Joining with an invitation: the server, then the invitation. An
  /// enrollment already under way resumes with both on one screen.
  List<Widget> _invitation(BuildContext context, SetupView setup) {
    final l10n = context.l10n;
    final muted = ArveilType.preview.copyWith(
      color: ArveilColors.of(context).inkSoft,
    );
    final retry =
        setup.stage != SetupStage.new_ &&
        setup.stage != SetupStage.identityReady;
    if (retry) {
      return [
        _title(context, l10n.enrollTitleRetry),
        Text(l10n.enrollBodyRetry, style: muted),
        const SizedBox(height: 16),
        _status(context, setup),
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _serverField(l10n),
              const SizedBox(height: 20),
              _inviteField(l10n),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _session.busy ? null : _enroll,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.enrollRetry),
              ),
            ],
          ),
        ),
      ];
    }
    final fresh = setup.stage == SetupStage.new_;
    if (!_serverDone) {
      return [
        if (fresh) _back(context),
        _stepLabel(context, 1),
        _title(context, l10n.enrollServerTitle),
        Text(l10n.enrollBody, style: muted),
        const SizedBox(height: 20),
        if (!fresh) _status(context, setup),
        Form(
          key: _serverForm,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _serverField(l10n),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('enroll-next'),
                onPressed: _session.busy ? null : _nextStep,
                icon: const Icon(Icons.arrow_forward),
                label: Text(l10n.enrollNext),
              ),
            ],
          ),
        ),
      ];
    }
    return [
      _stepLabel(context, 2),
      _title(context, l10n.enrollInviteTitle),
      Text(
        _inviteFound ? l10n.enrollInviteFound : l10n.enrollInviteBody,
        key: const Key('invite-body'),
        style: muted,
      ),
      const SizedBox(height: 20),
      if (!fresh) _status(context, setup),
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _inviteField(l10n),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _session.busy ? null : _enroll,
              icon: const Icon(Icons.arrow_forward),
              label: Text(l10n.enrollSubmit),
            ),
          ],
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _session.busy
              ? null
              : () => setState(() => _serverDone = false),
          icon: const Icon(Icons.arrow_back),
          label: Text(l10n.enrollPrevious),
        ),
      ),
    ];
  }

  /// Right after an identity is ready: save its kit now, or later with the
  /// risk in view.
  List<Widget> _kitOffer(BuildContext context) {
    final l10n = context.l10n;
    final c = ArveilColors.of(context);
    return [
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: c.attention,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(Icons.key_outlined, color: c.onAttention, size: 30),
        ),
      ),
      const SizedBox(height: 24),
      _title(context, l10n.kitOfferTitle),
      Text(
        l10n.kitExplanation,
        style: ArveilType.preview.copyWith(color: c.inkSoft),
      ),
      const SizedBox(height: 20),
      StatusBanner(
        key: const Key('kit-offer-risk'),
        title: l10n.kitOfferRiskTitle,
        body: l10n.kitReminderNever,
        icon: Icons.warning_amber_outlined,
      ),
      const SizedBox(height: 28),
      FilledButton.icon(
        key: const Key('kit-offer-save'),
        onPressed: () {
          setState(() => _offerKit = false);
          Navigator.of(context).push(kitRoute(_session, widget.kitFiles));
        },
        icon: const Icon(Icons.key_outlined),
        label: Text(l10n.kitSave),
      ),
      const SizedBox(height: 8),
      TextButton(
        key: const Key('kit-offer-later'),
        onPressed: () => setState(() => _offerKit = false),
        child: Text(l10n.later),
      ),
    ];
  }
}
