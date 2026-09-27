import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'attachment_card.dart';
import 'conversation_text.dart';
import 'design/design.dart';
import 'rust/api/profile.dart';

/// What sits under a conversation's name: whether the one other person
/// was verified, how many people a group has, or how many of them nobody
/// compared a safety number with yet.
String conversationSubtitle(AppLocalizations l10n, ConversationView row) {
  final people = otherPeople(row);
  final unverified = unverifiedPeople(row).length;
  if (people.length == 1) {
    return unverified == 0 ? l10n.verified : l10n.unverified;
  }
  return unverified == 0
      ? l10n.conversationPeople(people.length)
      : l10n.peopleUnverified(unverified);
}

/// A conversation's avatar, name and subtitle, for the top of its pane.
/// With [onTap] it opens the details, and says so while someone there is
/// not verified: talking never waits for the comparison.
class ConversationHeader extends StatelessWidget {
  const ConversationHeader({
    super.key,
    required this.title,
    this.row,
    this.onTap,
  });
  final String title;

  /// Null while the list has not caught up with a new conversation.
  final ConversationView? row;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    final row = this.row;
    final muted = ArveilType.secondary.copyWith(color: c.inkMuted);
    final header = Row(
      children: [
        ArveilAvatar(
          identity: row == null ? title : rowIdentity(row),
          label: row == null ? title : rowAvatarLabel(row),
          size: 40,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ArveilType.barTitle.copyWith(color: c.ink),
              ),
              if (row != null)
                Text.rich(
                  TextSpan(
                    text: conversationSubtitle(context.l10n, row),
                    children: [
                      if (onTap != null && unverifiedPeople(row).isNotEmpty)
                        TextSpan(
                          text: ' · ${context.l10n.verifyAction}',
                          style: muted.copyWith(
                            color: c.accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                  key: const Key('conversation-verification'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
            ],
          ),
        ),
      ],
    );
    final open = onTap;
    if (open == null || row == null) return header;
    // One button that reads as the name and its state; the details button
    // beside it keeps the tooltip.
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: InkWell(
          key: const Key('conversation-header'),
          onTap: open,
          borderRadius: BorderRadius.circular(ArveilShape.buttonSmall),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: header,
          ),
        ),
      ),
    );
  }
}

/// Who is in a conversation, whether each was verified and with how many
/// devices, and the files in the history loaded so far. Anyone not yet
/// verified shows the safety number to compare, and is verified here once
/// both people say it matches.
class ConversationDetails extends StatefulWidget {
  const ConversationDetails({
    super.key,
    required this.row,
    required this.events,
    this.onName,
    this.onVerify,
  });
  final ConversationView row;
  final List<HistoryEventView> events;

  /// Names another person locally; given the identity and the name it has,
  /// if any. Without it the people are listed read-only.
  final void Function(String identity, String? current)? onName;

  /// Verifies another person after the two compared [safetyNumber] and saw
  /// it match; whether that was saved. Without it the numbers are not
  /// offered for comparison.
  final Future<bool> Function(String identity, String safetyNumber)? onVerify;

  @override
  State<ConversationDetails> createState() => _ConversationDetailsState();
}

class _ConversationDetailsState extends State<ConversationDetails> {
  /// People whose number the user said differs: nothing is verified.
  final Set<String> _differ = {};
  final Set<String> _failed = {};
  final Set<String> _busy = {};

  Future<void> _verify(String identity, String number) async {
    setState(() {
      _busy.add(identity);
      _differ.remove(identity);
      _failed.remove(identity);
    });
    final saved = await widget.onVerify!(identity, number);
    if (!mounted) return;
    setState(() {
      _busy.remove(identity);
      if (!saved) _failed.add(identity);
    });
  }

  /// The number to compare with someone not verified yet, and what the
  /// comparison gave.
  Widget _comparison(String identity, String number) {
    final l10n = context.l10n;
    final busy = _busy.contains(identity);
    return Padding(
      key: Key('compare-$identity'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SafetyNumberGrid(
            key: Key('safety-$identity'),
            number: number,
            caption: l10n.contactCompareHelp,
          ),
          if (_differ.contains(identity)) ...[
            const SizedBox(height: 12),
            StatusBanner(
              key: Key('mismatch-$identity'),
              title: l10n.mismatchTitle,
              body: l10n.detailsMismatchBody,
              icon: Icons.gpp_bad_outlined,
              tone: BannerTone.error,
            ),
          ] else if (_failed.contains(identity)) ...[
            const SizedBox(height: 12),
            StatusBanner(
              title: l10n.detailsVerifyFailed,
              icon: Icons.error_outline,
              tone: BannerTone.error,
            ),
          ],
          const SizedBox(height: 12),
          // Side by side when they fit, one above the other in a narrow
          // panel or with large text.
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 12,
            overflowSpacing: 8,
            overflowAlignment: OverflowBarAlignment.end,
            children: [
              OutlinedButton(
                key: Key('differ-$identity'),
                onPressed: busy
                    ? null
                    : () => setState(() {
                        _differ.add(identity);
                        _failed.remove(identity);
                      }),
                child: Text(l10n.numbersDiffer),
              ),
              FilledButton(
                key: Key('verify-$identity'),
                onPressed: busy ? null : () => _verify(identity, number),
                child: Text(l10n.numbersMatch),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = ArveilColors.of(context);
    final row = widget.row;
    final people = <String, List<PeerView>>{};
    for (final peer in row.peers.where((p) => !p.own)) {
      people.putIfAbsent(peer.identityId, () => []).add(peer);
    }
    final ownDevices = row.peers.where((p) => p.own && !p.revoked).length;
    final files = [for (final event in widget.events) ?event.attachment];
    Widget person(String identity, List<PeerView> devices) {
      final peer = devices.first;
      final verified = peer.verified;
      final active = devices.where((d) => !d.revoked).length;
      final onName = widget.onName;
      final number = peer.safetyNumber;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: Key('participant-$identity'),
            contentPadding: EdgeInsets.zero,
            leading: ArveilAvatar(
              identity: identity,
              label: peer.named ? peer.label : '',
              size: 40,
            ),
            title: Text(
              peerName(peer),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${verified ? (peer.verifiedHow == 'in-person' ? l10n.verifiedInPerson : l10n.verified) : l10n.unverified} · '
              '${l10n.devicesCount(active)}',
            ),
            trailing: onName == null
                ? null
                : peer.named
                ? IconButton(
                    key: Key('rename-$identity'),
                    tooltip: l10n.renamePerson,
                    onPressed: () => onName(identity, peer.label),
                    icon: const Icon(Icons.edit_outlined),
                  )
                : TextButton(
                    key: Key('name-$identity'),
                    onPressed: () => onName(identity, null),
                    child: Text(l10n.nameThisPerson),
                  ),
          ),
          if (!verified && number != null && widget.onVerify != null)
            _comparison(identity, number),
        ],
      );
    }

    return Column(
      key: const Key('conversation-details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionTitle(l10n.participants),
        for (final MapEntry(key: identity, value: devices) in people.entries)
          person(identity, devices),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            radius: 20,
            backgroundColor: c.accentSoft,
            child: Icon(Icons.person_outline, color: c.accent),
          ),
          title: Text(l10n.participantsYou),
          subtitle: ownDevices > 0 ? Text(l10n.devicesCount(ownDevices)) : null,
        ),
        const SizedBox(height: 8),
        SectionTitle(l10n.detailsFiles),
        if (files.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              l10n.detailsNoFiles,
              style: ArveilType.secondary.copyWith(color: c.inkMuted),
            ),
          )
        else
          for (final file in files)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.insert_drive_file_outlined, color: c.inkSoft),
              title: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(attachmentSize(file.size)),
            ),
      ],
    );
  }
}
