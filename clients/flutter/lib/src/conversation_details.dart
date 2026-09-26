import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'attachment_card.dart';
import 'conversation_text.dart';
import 'design/design.dart';
import 'rust/api/profile.dart';

/// What sits under a conversation's name: whether the one other person
/// was verified, or how many people a group has.
String conversationSubtitle(AppLocalizations l10n, ConversationView row) {
  final people = otherPeople(row);
  if (people.length == 1) {
    return people.values.single.verified ? l10n.verified : l10n.unverified;
  }
  return l10n.conversationPeople(people.length);
}

/// A conversation's avatar, name and subtitle, for the top of its pane.
class ConversationHeader extends StatelessWidget {
  const ConversationHeader({super.key, required this.title, this.row});
  final String title;

  /// Null while the list has not caught up with a new conversation.
  final ConversationView? row;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    final row = this.row;
    return Row(
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
                Text(
                  conversationSubtitle(context.l10n, row),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ArveilType.secondary.copyWith(color: c.inkMuted),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Who is in a conversation, whether each was verified and with how many
/// devices, and the files in the history loaded so far.
class ConversationDetails extends StatelessWidget {
  const ConversationDetails({
    super.key,
    required this.row,
    required this.events,
    this.onName,
  });
  final ConversationView row;
  final List<HistoryEventView> events;

  /// Names another person locally; given the identity and the name it has,
  /// if any. Without it the people are listed read-only.
  final void Function(String identity, String? current)? onName;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = ArveilColors.of(context);
    final people = <String, List<PeerView>>{};
    for (final peer in row.peers.where((p) => !p.own)) {
      people.putIfAbsent(peer.identityId, () => []).add(peer);
    }
    final ownDevices = row.peers.where((p) => p.own && !p.revoked).length;
    final files = [for (final event in events) ?event.attachment];
    Widget person(String identity, List<PeerView> devices) {
      final peer = devices.first;
      final verified = peer.verified;
      final active = devices.where((d) => !d.revoked).length;
      final onName = this.onName;
      return ListTile(
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
          '${verified ? l10n.verified : l10n.unverified} · '
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
