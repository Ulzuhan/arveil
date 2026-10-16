import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'design/design.dart';
import 'design/qr_code.dart';
import 'own_route.dart';
import 'qr_scanner.dart';
import 'rust/api/profile.dart';
import 'share_text.dart';

String _date(BuildContext context, int seconds) => MaterialLocalizations.of(
  context,
).formatMediumDate(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));

/// This device's contact card (ADR-012 §4): a code to show in person, a
/// link to share, the name the card carries, and the links still valid.
class MyCardPage extends StatefulWidget {
  const MyCardPage({super.key, required this.profile});
  final Profile profile;

  @override
  State<MyCardPage> createState() => _MyCardPageState();
}

class _MyCardPageState extends State<MyCardPage> {
  final _name = TextEditingController();
  List<CardOfferView> _shared = [];
  bool _busy = false;

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
      final name = await widget.profile.cardName();
      final shared = await widget.profile.sharedCards();
      if (!mounted) return;
      setState(() {
        _name.text = name ?? '';
        _shared = shared;
      });
    } catch (_) {
      // The page still offers everything; the list stays empty.
    }
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _saveName() async {
    final l10n = context.l10n;
    try {
      final name = _name.text.trim();
      await widget.profile.setCardName(name: name.isEmpty ? null : name);
      _say(l10n.cardNameSaved);
    } catch (_) {
      _say(l10n.cardNameInvalid);
    }
  }

  Future<void> _share() async {
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      final card = await widget.profile.offerCard(inPerson: false);
      if (!await shareText(card.link)) {
        await Clipboard.setData(ClipboardData(text: card.link));
        _say(l10n.cardLinkCopied);
      }
      await _load();
    } catch (_) {
      _say(l10n.cardFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(CardOfferView card) async {
    final l10n = context.l10n;
    try {
      await widget.profile.closeCard(secret: card.secret);
      _say(l10n.cardRevoked);
      await _load();
    } catch (_) {
      _say(l10n.cardFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.cardMineTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: WindowSize.of(context).margin,
                vertical: 16,
              ),
              children: [
                Text(l10n.cardMineHelp),
                const SizedBox(height: 16),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      key: const Key('card-show-code'),
                      icon: Icons.qr_code_2,
                      title: l10n.cardShowCode,
                      subtitle: l10n.cardShowCodeHelp,
                      onTap: _busy
                          ? null
                          : () => Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) =>
                                    InPersonCodePage(profile: widget.profile),
                              ),
                            ),
                    ),
                    SettingsRow(
                      key: const Key('card-share-link'),
                      icon: Icons.share_outlined,
                      title: l10n.cardShareLink,
                      subtitle: l10n.cardShareLinkHelp,
                      onTap: _busy ? null : _share,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                TextField(
                  key: const Key('card-name'),
                  controller: _name,
                  maxLength: 64,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: InputDecoration(
                    labelText: l10n.cardNameLabel,
                    helperText: l10n.cardNameHelper,
                    helperMaxLines: 3,
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const Key('card-name-save'),
                    onPressed: _saveName,
                    child: Text(l10n.cardNameSave),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.cardSharedTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (_shared.isEmpty)
                  Text(
                    l10n.cardSharedEmpty,
                    key: const Key('card-shared-empty'),
                  )
                else
                  SettingsGroup(
                    children: [
                      for (final card in _shared)
                        ListTile(
                          key: Key('card-shared-${card.createdAt}'),
                          leading: const Icon(Icons.link),
                          title: Text(
                            l10n.cardSharedRow(
                              _date(context, card.createdAt),
                              _date(context, card.expiresAt),
                            ),
                          ),
                          trailing: TextButton(
                            onPressed: () => _revoke(card),
                            child: Text(l10n.cardRevoke),
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 20),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: const Key('share-route'),
                    onPressed: () => showOwnRoute(context, widget.profile),
                    child: Text(l10n.cardOlderRoute),
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

/// The in-person code: valid while this screen is open, ten minutes at
/// most, and once.
class InPersonCodePage extends StatefulWidget {
  const InPersonCodePage({super.key, required this.profile});
  final Profile profile;

  @override
  State<InPersonCodePage> createState() => _InPersonCodePageState();
}

class _InPersonCodePageState extends State<InPersonCodePage> {
  CardOfferView? _card;
  bool _failed = false;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    unawaited(() async {
      try {
        final card = await widget.profile.offerCard(inPerson: true);
        if (mounted) {
          setState(() => _card = card);
        } else {
          await widget.profile.closeCard(secret: card.secret);
        }
      } catch (_) {
        if (mounted) setState(() => _failed = true);
      }
    }());
  }

  @override
  void dispose() {
    _clock?.cancel();
    // Closing the screen ends the code.
    if (_card case final card?) {
      unawaited(
        widget.profile.closeCard(secret: card.secret).catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final card = _card;
    final remaining = card == null
        ? 0
        : card.expiresAt - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.cardCodeTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                children: [
                  if (_failed)
                    Text(l10n.cardFailed)
                  else if (card == null)
                    const CircularProgressIndicator()
                  else if (remaining <= 0)
                    Text(
                      l10n.cardCodeExpired,
                      key: const Key('card-code-expired'),
                    )
                  else ...[
                    Text(l10n.cardCodeHelp, textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    QrCodeView(
                      key: const Key('card-qr'),
                      profile: widget.profile,
                      text: card.link,
                      label: l10n.cardCodeQrLabel,
                    ),
                    const SizedBox(height: 16),
                    ExpiresIn(remaining, key: const Key('card-expires')),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Open a contact card: who it names, then start talking. Returns the
/// conversation it started, if any.
Future<String?> openContactCard(
  BuildContext context, {
  required Profile profile,
  required String bootstrap,
  required String text,
  required bool scanned,
}) async {
  final l10n = context.l10n;
  final CardPreviewView preview;
  try {
    preview = await profile.previewCard(text: text);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(l10n.cardOpenFailed)));
    }
    return null;
  }
  if (!context.mounted) return null;
  final start = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              preview.knownAs ??
                  (preview.name == null
                      ? l10n.cardPreviewUnnamed
                      : l10n.cardPreviewSays(preview.name!)),
              key: const Key('card-preview-name'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (preview.knownAs != null && preview.name != null) ...[
              const SizedBox(height: 4),
              Text(l10n.cardPreviewSays(preview.name!)),
            ],
            const SizedBox(height: 12),
            Text(
              scanned || preview.verified
                  ? l10n.cardPreviewScanned
                  : l10n.cardPreviewLinked,
            ),
            const SizedBox(height: 12),
            Text(l10n.safetyNumberTitle),
            SelectableText(preview.safetyNumber, style: ArveilType.identifier),
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('card-start'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.cardStart),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
          ],
        ),
      ),
    ),
  );
  if (start != true) return null;
  try {
    final result = await profile.startFromCard(
      bootstrap: bootstrap,
      text: text,
      scanned: scanned,
    );
    return result.groupId;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(l10n.cardStartFailed)));
    }
    return null;
  }
}

/// Scan someone's code in person (Android).
Future<String?> scanContactCard(BuildContext context, Profile profile) =>
    scanCode(
      context,
      profile: profile,
      accept: (card) => card is CardView_Contact || card is CardView_Invitation,
      wrongCode: context.l10n.scanNotContact,
    );
