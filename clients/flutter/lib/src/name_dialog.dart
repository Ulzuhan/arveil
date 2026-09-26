import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'rust/api/profile.dart';

/// Asks what to call [identityId] and saves it as a local name in this
/// profile only: it is never sent to anyone and authenticates nothing.
/// [current] is the name it has, if any; an empty field removes it.
/// Returns whether a name was saved.
Future<bool> askLocalName(
  BuildContext context, {
  required Profile profile,
  required String identityId,
  String? current,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) =>
        _NameDialog(profile: profile, identityId: identityId, current: current),
  );
  if (saved == true && context.mounted) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(context.l10n.nameSaved)));
  }
  return saved == true;
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.profile,
    required this.identityId,
    required this.current,
  });
  final Profile profile;
  final String identityId;
  final String? current;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.current ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.profile.renameContact(
        identityId: widget.identityId,
        name: _name.text,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = context.l10n.nameSaveFailed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.nameDialogTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('local-name'),
              controller: _name,
              autofocus: true,
              enabled: !_busy,
              maxLength: 128,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _busy ? null : _save(),
              decoration: InputDecoration(
                labelText: l10n.nameDialogLabel,
                helperText: l10n.nameDialogHelper,
                helperMaxLines: 4,
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('save-local-name'),
          onPressed: _busy ? null : _save,
          child: Text(l10n.contactSaveName),
        ),
      ],
    );
  }
}
