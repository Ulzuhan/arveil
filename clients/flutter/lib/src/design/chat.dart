import 'package:flutter/material.dart';

import 'components.dart';
import 'tokens.dart';
import 'typography.dart';

/// Where a bubble sits in a run from one author: only the first of a run
/// has the tail and the author's name.
enum BubblePosition { single, first, middle, last }

/// A message bubble: own on the right on the accent tint, others on the
/// left, with an optional author and a meta line (time, delivery).
class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.own,
    required this.child,
    this.sender,
    this.senderColor,
    this.meta,
    this.position = BubblePosition.single,
  });
  final bool own;
  final Widget child;

  /// Author name, shown on the first bubble of a run in a group.
  final String? sender;
  final Color? senderColor;
  final Widget? meta;
  final BubblePosition position;

  bool get _starts =>
      position == BubblePosition.single || position == BubblePosition.first;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    const round = Radius.circular(ArveilShape.bubble);
    const tail = Radius.circular(ArveilShape.bubbleTail);
    final radius = BorderRadius.only(
      topLeft: !own && _starts ? tail : round,
      topRight: own && _starts ? tail : round,
      bottomLeft: round,
      bottomRight: round,
    );
    return Align(
      alignment: own ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          margin: EdgeInsets.only(top: _starts ? 6 : 2),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: own ? c.accentSoft : c.surfaceRaised,
            borderRadius: radius,
          ),
          child: MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_starts && sender != null)
                  Text(
                    sender!,
                    style: ArveilType.label.copyWith(
                      fontSize: 13,
                      color: senderColor ?? c.inkSoft,
                    ),
                  ),
                DefaultTextStyle.merge(
                  style: ArveilType.messageBody.copyWith(color: c.ink),
                  child: child,
                ),
                if (meta case final meta?)
                  Align(alignment: Alignment.centerRight, child: meta),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Time and, for what this device sent, its delivery status.
class BubbleMeta extends StatelessWidget {
  const BubbleMeta({
    super.key,
    required this.time,
    this.own = false,
    this.status,
  });
  final String time;
  final bool own;
  final DeliveryStatus? status;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    final color = own ? c.ownMeta : c.inkMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(time, style: ArveilType.meta.copyWith(color: color)),
        if (status case final status?) ...[
          const SizedBox(width: 4),
          DeliveryIcon(status: status, color: color),
        ],
      ],
    );
  }
}

/// A row of the conversation list.
class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.identity,
    required this.title,
    this.avatarLabel,
    this.preview,
    this.time,
    this.unread = 0,
    this.verified = false,
    this.unverified = false,
    this.status,
    this.selected = false,
    this.onTap,
  });

  /// Chooses the avatar tone: the contact's identity, or the group's id.
  final String identity;
  final String title;
  final String? avatarLabel;
  final String? preview;
  final String? time;
  final int unread;
  final bool verified;
  final bool unverified;

  /// Delivery of the newest message, when this device sent it.
  final DeliveryStatus? status;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? c.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    ArveilAvatar(
                      identity: identity,
                      label: avatarLabel ?? title,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ArveilType.rowName.copyWith(
                                    color: c.ink,
                                  ),
                                ),
                              ),
                              if (verified) ...[
                                const SizedBox(width: 6),
                                const VerifiedMark(size: 15),
                              ],
                              if (unverified) ...[
                                const SizedBox(width: 8),
                                const UnverifiedChip(),
                              ],
                              const Spacer(),
                              if (time case final time?)
                                Text(
                                  time,
                                  style: ArveilType.meta.copyWith(
                                    fontSize: 12.5,
                                    color: unread > 0 ? c.accent : c.inkMuted,
                                    fontWeight: unread > 0
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    fontVariations: [
                                      FontVariation.weight(
                                        unread > 0 ? 600 : 400,
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              if (status case final status?) ...[
                                DeliveryIcon(status: status),
                                const SizedBox(width: 4),
                              ],
                              Expanded(
                                child: Text(
                                  preview ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ArveilType.preview.copyWith(
                                    color: c.inkMuted,
                                  ),
                                ),
                              ),
                              if (unread > 0) ...[
                                const SizedBox(width: 8),
                                UnreadBadge(count: unread),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where a message is written: attach, type, send.
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.onSend,
    this.onAttach,
    this.hint = 'Mensaje',
    this.enabled = true,
    this.fieldKey,
    this.sendKey,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback? onAttach;
  final String hint;
  final bool enabled;
  final Key? fieldKey;
  final Key? sendKey;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.bar,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (onAttach != null)
              IconButton(
                tooltip: 'Adjuntar archivo',
                onPressed: enabled ? onAttach : null,
                icon: Icon(Icons.attach_file, color: c.inkSoft),
              ),
            Expanded(
              child: TextField(
                key: fieldKey,
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                style: ArveilType.messageBody.copyWith(color: c.ink),
                decoration: InputDecoration(
                  hintText: hint,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide(color: c.lineStrong),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide(color: c.lineStrong),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide(color: c.accent, width: 2),
                  ),
                ),
              ),
            ),
            const SizedBox(width: ArveilShape.s2),
            IconButton.filled(
              key: sendKey,
              tooltip: 'Enviar',
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ),
    );
  }
}
