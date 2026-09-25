import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'profile_session.dart';

class PairingPanel extends StatefulWidget {
  const PairingPanel({
    super.key,
    required this.session,
    this.administration = false,
    this.heading = true,
  });
  final ProfileSession session;
  final bool administration;

  /// Shows the panel's own title; off on a screen whose bar names it.
  final bool heading;

  @override
  State<PairingPanel> createState() => _PairingPanelState();
}

class _PairingPanelState extends State<PairingPanel> {
  final _form = GlobalKey<FormState>();
  final _relay = TextEditingController();
  final _code = TextEditingController();
  final _comparison = TextEditingController();
  Timer? _clock;
  ProfileSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _relay.text = session.setup?.bootstrap ?? '';
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && session.setup?.pairing != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _relay.dispose();
    _code.dispose();
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

  @override
  Widget build(BuildContext context) {
    if (widget.administration) return _administration(context);
    final pairing = session.setup?.pairing;
    final remaining = pairing == null
        ? 0
        : pairing.expiresAt.toInt() -
              DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expired =
        pairing != null &&
        !pairing.committing &&
        (pairing.expired || remaining <= 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.pairingTitle,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 16),
        Text(context.l10n.pairingExplanation),
        const SizedBox(height: 20),
        if (pairing == null)
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
                  decoration: InputDecoration(
                    labelText: context.l10n.pairingRelayLabel,
                  ),
                  validator: (text) =>
                      (text ?? '').trim().startsWith('arveil-bootstrap:v0:')
                      ? null
                      : context.l10n.pairingRelayInvalid,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: session.busy ? null : _begin,
                  child: Text(context.l10n.pairingGenerate),
                ),
              ],
            ),
          )
        else ...[
          if (pairing.committing) ...[
            Text(context.l10n.pairingConfirmationSaved),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: session.busy
                  ? null
                  : () => session.confirmPairing(pairing.verificationCode!),
              child: Text(context.l10n.pairingResumeFinish),
            ),
          ] else if (expired) ...[
            Text(context.l10n.pairingExpired),
          ] else if (pairing.verificationCode case final verification?) ...[
            Text(
              context.l10n.pairingComparisonCode,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            SelectableText(
              verification,
              key: const Key('pair-verification'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            Text(context.l10n.pairingCompareHelp),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('pair-comparison'),
              controller: _comparison,
              enabled: !session.busy,
              keyboardType: TextInputType.number,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(
                labelText: context.l10n.pairingOtherCode,
              ),
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
              child: Text(context.l10n.pairingConfirmComparison),
            ),
          ] else ...[
            Text(context.l10n.pairingShareCode),
            const SizedBox(height: 12),
            SelectableText(pairing.code, key: const Key('pair-code')),
            const SizedBox(height: 12),
            Text(context.l10n.pairingExpiresIn(remaining > 0 ? remaining : 0)),
            const SizedBox(height: 12),
            Text(
              session.waitingForPairing
                  ? context.l10n.pairingWaiting
                  : context.l10n.pairingWaitInterrupted,
            ),
          ],
          if (!pairing.committing) ...[
            const SizedBox(height: 16),
            OutlinedButton(
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
        ],
      ],
    );
  }

  Widget _administration(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.heading) ...[
        Text(
          context.l10n.pairingOtherTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
      ],
      if (session.approvalCode case final verification?) ...[
        Text(context.l10n.pairingAdminCompare),
        const SizedBox(height: 12),
        SelectableText(
          verification,
          key: const Key('approval-verification'),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        Text(context.l10n.pairingAuthorizationIssued),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: session.dismissApproval,
          child: Text(context.l10n.pairingCloseComparison),
        ),
      ] else
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.l10n.pairingPasteOwnCode),
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
                decoration: InputDecoration(
                  labelText: context.l10n.pairingCodeLabel,
                ),
                validator: (text) =>
                    (text ?? '').trim().startsWith('arveil-pair:')
                    ? null
                    : context.l10n.pairingCodeInvalid,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: session.busy ? null : _approve,
                child: Text(context.l10n.pairingAuthorize),
              ),
              const SizedBox(height: 8),
              Text(context.l10n.pairingKeepOpen),
            ],
          ),
        ),
    ],
  );
}
