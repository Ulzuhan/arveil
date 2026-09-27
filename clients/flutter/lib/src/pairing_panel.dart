import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'profile_session.dart';
import 'design/qr_code.dart';
import 'qr_scanner.dart';
import 'rust/api/profile.dart';

/// Linking a device (ADR-012 §3). The device that holds the root shows a
/// code; the new device scans it (Android) or opens its link, both screens
/// show the same number, and nothing is authorized until the person confirms
/// on the device that holds the root. The older flow, where the new device
/// shows a code, stays available for a device on an earlier version.
class PairingPanel extends StatefulWidget {
  const PairingPanel({
    super.key,
    required this.session,
    this.administration = false,
    this.heading = true,
    this.initialLink,
  });
  final ProfileSession session;

  /// A link opened from outside, placed in the field for the person to use.
  final String? initialLink;
  final bool administration;

  /// Shows the panel's own title; off on a screen whose bar names it.
  final bool heading;

  @override
  State<PairingPanel> createState() => _PairingPanelState();
}

class _PairingPanelState extends State<PairingPanel> {
  final _form = GlobalKey<FormState>();
  final _linkForm = GlobalKey<FormState>();
  final _relay = TextEditingController();
  final _code = TextEditingController();
  final _link = TextEditingController();
  final _comparison = TextEditingController();
  Timer? _clock;
  late final AppLifecycleListener _lifecycle;

  /// The flow for a device on an earlier version, where the new device
  /// shows the code.
  bool _older = false;
  bool _linkRefused = false;
  ProfileSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _relay.text = session.setup?.bootstrap ?? '';
    _link.text = widget.initialLink ?? '';
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted &&
          (session.setup?.pairing != null || session.linkOffer != null)) {
        setState(() {});
      }
    });
    _lifecycle = AppLifecycleListener(onResume: _listen);
    WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
  }

  static int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Leaving the app is a normal part of linking, and the system may stop a
  /// wait meanwhile. A code that is still valid is listened for again when
  /// this screen opens and when the app comes back.
  void _listen() {
    if (!mounted || session.busy || session.cancellingPairing) return;
    if (widget.administration) {
      final offer = session.linkOffer;
      if (offer != null &&
          session.linkRequest == null &&
          offer.expiresAt.toInt() > _now) {
        unawaited(session.waitForLink());
      }
      return;
    }
    final pairing = session.setup?.pairing;
    if (pairing == null ||
        pairing.link ||
        pairing.committing ||
        pairing.expired ||
        pairing.verificationCode != null ||
        pairing.expiresAt.toInt() <= _now) {
      return;
    }
    unawaited(session.waitForPairing());
  }

  Future<void> _copy(String text, String done) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(done)));
  }

  @override
  void didUpdateWidget(PairingPanel old) {
    super.didUpdateWidget(old);
    if (widget.initialLink != null && widget.initialLink != old.initialLink) {
      _link.text = widget.initialLink!;
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _clock?.cancel();
    // Leaving the screen withdraws a code nobody confirmed.
    if (widget.administration &&
        (session.linkOffer != null || session.linkRequest != null)) {
      unawaited(session.closeLink());
    }
    _relay.dispose();
    _code.dispose();
    _link.dispose();
    _comparison.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    if (await session.beginPairing(_relay.text.trim()) && mounted) {
      unawaited(session.waitForPairing());
    }
  }

  Future<void> _approve() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    if (await session.approvePairing(_code.text.trim()) && mounted) {
      _code.clear();
    }
  }

  Future<void> _offer() async {
    if (await session.offerLink() && mounted) unawaited(session.waitForLink());
  }

  Future<void> _scan() async {
    final profile = session.profile;
    if (profile == null) return;
    final text = await scanCode(
      context,
      profile: profile,
      accept: (card) => card is CardView_Link,
      wrongCode: context.l10n.scanNotLink,
    );
    if (text != null && mounted) {
      await session.joinLink(text, scanned: true);
    }
  }

  Future<void> _useLink() async {
    final profile = session.profile;
    final text = _link.text.trim();
    var usable = false;
    if (profile != null && text.isNotEmpty) {
      try {
        usable = await profile.readCard(text: text) is CardView_Link;
      } catch (_) {
        usable = false;
      }
    }
    if (!mounted) return;
    setState(() => _linkRefused = !usable);
    if (!(_linkForm.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    if (await session.joinLink(text, scanned: false) && mounted) {
      _link.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.administration) return _administration(context);
    final l10n = context.l10n;
    final pairing = session.setup?.pairing;
    final remaining = pairing == null ? 0 : pairing.expiresAt.toInt() - _now;
    final expired =
        pairing != null &&
        !pairing.committing &&
        (pairing.expired || remaining <= 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.pairingTitle,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 16),
        if (session.joiningLink)
          ..._joining(context)
        else if (pairing == null)
          ...(_older ? _olderStart(context) : _linkStart(context))
        else ...[
          if (pairing.committing) ...[
            Text(l10n.pairingConfirmationSaved),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: session.busy
                  ? null
                  : () => session.confirmPairing(pairing.verificationCode!),
              child: Text(l10n.pairingResumeFinish),
            ),
          ] else if (expired) ...[
            Text(l10n.pairingExpired),
          ] else if (pairing.verificationCode case final verification?) ...[
            Text(
              l10n.pairingComparisonCode,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            SelectableText(
              verification,
              key: const Key('pair-verification'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            Text(l10n.pairingCompareHelp),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('pair-comparison'),
              controller: _comparison,
              enabled: !session.busy,
              keyboardType: TextInputType.number,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(labelText: l10n.pairingOtherCode),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: session.busy
                  ? null
                  : () async {
                      FocusScope.of(context).unfocus();
                      await session.confirmPairing(_comparison.text.trim());
                      if (mounted) _comparison.clear();
                    },
              child: Text(l10n.pairingConfirmComparison),
            ),
          ] else if (pairing.link) ...[
            Text(
              l10n.pairingLinkInterrupted,
              key: const Key('pair-interrupted'),
            ),
          ] else ...[
            Text(l10n.pairingShareCode),
            const SizedBox(height: 12),
            SelectableText(pairing.code, key: const Key('pair-code')),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                key: const Key('pair-copy-code'),
                onPressed: () => _copy(pairing.code, l10n.pairingCodeCopied),
                icon: const Icon(Icons.copy_outlined),
                label: Text(l10n.pairingCopyCode),
              ),
            ),
            const SizedBox(height: 12),
            Text(l10n.pairingExpiresIn(remaining > 0 ? remaining : 0)),
            const SizedBox(height: 12),
            Text(
              session.waitingForPairing
                  ? l10n.pairingWaiting
                  : l10n.pairingWaitInterrupted,
            ),
            if (!session.waitingForPairing) ...[
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('pair-resume-wait'),
                onPressed: session.busy || session.cancellingPairing
                    ? null
                    : session.waitForPairing,
                child: Text(l10n.pairingResumeWait),
              ),
            ],
          ],
          if (!pairing.committing) _cancel(context),
        ],
      ],
    );
  }

  /// Scan the other device's code, or paste its link.
  List<Widget> _linkStart(BuildContext context) {
    final l10n = context.l10n;
    return [
      Text(l10n.pairingLinkExplanation),
      const SizedBox(height: 20),
      if (canScan) ...[
        FilledButton.icon(
          key: const Key('pair-scan'),
          onPressed: session.busy ? null : _scan,
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(l10n.pairingScan),
        ),
        const SizedBox(height: 20),
      ],
      Form(
        key: _linkForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('pair-link'),
              controller: _link,
              enabled: !session.busy,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(labelText: l10n.pairingLinkLabel),
              onChanged: (_) {
                if (_linkRefused) setState(() => _linkRefused = false);
              },
              validator: (_) => _linkRefused ? l10n.pairingLinkInvalid : null,
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              key: const Key('pair-use-link'),
              onPressed: session.busy ? null : _useLink,
              child: Text(l10n.pairingUseLink),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          key: const Key('pair-older'),
          onPressed: session.busy ? null : () => setState(() => _older = true),
          child: Text(l10n.pairingOlderDevice),
        ),
      ),
    ];
  }

  /// The earlier flow: this device shows a code for the other one.
  List<Widget> _olderStart(BuildContext context) {
    final l10n = context.l10n;
    return [
      Text(l10n.pairingExplanation),
      const SizedBox(height: 20),
      Form(
        key: _form,
        child: Column(
          children: [
            TextFormField(
              key: const Key('pair-bootstrap'),
              controller: _relay,
              enabled: !session.busy,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(labelText: l10n.pairingRelayLabel),
              validator: (text) =>
                  (text ?? '').trim().startsWith('arveil-bootstrap:v0:')
                  ? null
                  : l10n.pairingRelayInvalid,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: session.busy ? null : _begin,
              child: Text(l10n.pairingGenerate),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          key: const Key('pair-newer'),
          onPressed: session.busy ? null : () => setState(() => _older = false),
          child: Text(l10n.pairingNewerFlow),
        ),
      ),
    ];
  }

  /// Waiting for the other device, with the number as soon as it exists.
  List<Widget> _joining(BuildContext context) {
    final l10n = context.l10n;
    return [
      Text(l10n.pairingJoining),
      if (session.joiningCode case final code?) ...[
        const SizedBox(height: 16),
        Text(
          l10n.pairingJoinCompare,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        SelectableText(
          code,
          key: const Key('pair-join-code'),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        Text(l10n.pairingJoinConfirmThere),
      ],
      _cancel(context),
    ];
  }

  Widget _cancel(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 16),
      OutlinedButton(
        key: const Key('pair-cancel'),
        onPressed:
            session.cancellingPairing ||
                (session.busy && !session.waitingForPairing)
            ? null
            : () async {
                await session.cancelPairing();
                if (mounted) _comparison.clear();
              },
        child: Text(context.l10n.pairingCancel),
      ),
      const SizedBox(height: 8),
      Text(context.l10n.pairingCancelNote),
    ],
  );

  Widget _administration(BuildContext context) {
    final l10n = context.l10n;
    final children = <Widget>[
      if (widget.heading) ...[
        Text(
          l10n.pairingOtherTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
      ],
    ];
    if (session.linkApproved case final approved?) {
      children.addAll([
        Text(
          approved ? l10n.pairingLinkedDone : l10n.pairingDeclinedDone,
          key: const Key('link-result'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: session.closeLink,
          child: Text(l10n.pairingDone),
        ),
      ]);
    } else if (session.linkRequest case final request?) {
      children.addAll(_request(context, request));
    } else if (session.linkOffer case final offer?) {
      children.addAll(_offerShown(context, offer));
    } else if (_older) {
      children.addAll(_olderAdministration(context));
    } else {
      children.addAll([
        Text(l10n.pairingOfferExplanation),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('link-offer'),
          onPressed: session.busy ? null : _offer,
          icon: const Icon(Icons.qr_code_2),
          label: Text(l10n.pairingShowCode),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const Key('pair-older-admin'),
            onPressed: session.busy
                ? null
                : () => setState(() => _older = true),
            child: Text(l10n.pairingOlderDeviceAdmin),
          ),
        ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  List<Widget> _offerShown(BuildContext context, LinkOfferView offer) {
    final l10n = context.l10n;
    final remaining = offer.expiresAt.toInt() - _now;
    final profile = session.profile;
    return [
      Text(l10n.pairingOfferHelp),
      const SizedBox(height: 16),
      if (profile != null)
        Center(
          child: QrCodeView(
            key: const Key('link-qr'),
            profile: profile,
            text: offer.link,
            label: l10n.pairingQrLabel,
          ),
        ),
      const SizedBox(height: 12),
      Text(l10n.pairingExpiresIn(remaining > 0 ? remaining : 0)),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          key: const Key('link-copy'),
          onPressed: () => _copy(offer.link, l10n.pairingLinkCopied),
          icon: const Icon(Icons.copy_outlined),
          label: Text(l10n.pairingCopyLink),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        session.waitingForLink
            ? l10n.pairingOfferWaiting
            : l10n.pairingOfferInterrupted,
      ),
      if (!session.waitingForLink && remaining > 0) ...[
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('link-resume-wait'),
          onPressed: session.busy ? null : session.waitForLink,
          child: Text(l10n.pairingResumeWait),
        ),
      ],
      const SizedBox(height: 12),
      OutlinedButton(
        key: const Key('link-close'),
        onPressed: session.closeLink,
        child: Text(l10n.pairingOfferClose),
      ),
    ];
  }

  /// A device answered: the person compares and decides here.
  List<Widget> _request(BuildContext context, LinkRequestView request) {
    final l10n = context.l10n;
    final name = request.description;
    return [
      Text(
        name == null ? l10n.pairingAdminAskUnnamed : l10n.pairingAdminAsk(name),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 12),
      Text(l10n.pairingAdminCompareNumber),
      const SizedBox(height: 12),
      SelectableText(
        request.verificationCode,
        key: const Key('approval-verification'),
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 12),
      Text(l10n.pairingApproveNote),
      const SizedBox(height: 16),
      FilledButton(
        key: const Key('link-approve'),
        onPressed: session.busy
            ? null
            : () => session.answerLink(approve: true),
        child: Text(l10n.pairingApprove),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        key: const Key('link-decline'),
        onPressed: session.busy
            ? null
            : () => session.answerLink(approve: false),
        child: Text(l10n.pairingDecline),
      ),
    ];
  }

  List<Widget> _olderAdministration(BuildContext context) {
    final l10n = context.l10n;
    return [
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (session.setup?.bootstrap case final bootstrap?) ...[
              Text(l10n.pairingServerDetailsStep),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  key: const Key('pair-copy-bootstrap'),
                  onPressed: () =>
                      _copy(bootstrap, l10n.pairingServerDetailsCopied),
                  icon: const Icon(Icons.copy_outlined),
                  label: Text(l10n.pairingCopyServerDetails),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(l10n.pairingPasteOwnCode),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('pair-approval-code'),
              controller: _code,
              enabled: !session.busy,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(labelText: l10n.pairingCodeLabel),
              validator: (text) =>
                  (text ?? '').trim().startsWith('arveil-pair:')
                  ? null
                  : l10n.pairingCodeInvalid,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: session.busy ? null : _approve,
              child: Text(l10n.pairingAuthorize),
            ),
            const SizedBox(height: 8),
            Text(l10n.pairingKeepOpen),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          onPressed: session.busy ? null : () => setState(() => _older = false),
          child: Text(l10n.pairingNewerFlow),
        ),
      ),
    ];
  }
}
