import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
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
    this.mergeSemantics = true,
  });
  final bool own;
  final Widget child;

  /// Reads the bubble as one node. Off when it holds its own buttons, so
  /// each stays reachable.
  final bool mergeSemantics;

  /// Author name, shown on the first bubble of a run in a group.
  final String? sender;
  final Color? senderColor;
  final Widget? meta;
  final BubblePosition position;

  bool get _starts =>
      position == BubblePosition.single || position == BubblePosition.first;

  Widget _merge(Widget child) =>
      mergeSemantics ? MergeSemantics(child: child) : child;

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
    // As wide as its content, up to 420 dp or 80 % of a narrow pane.
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: own ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(420, constraints.maxWidth * 0.8),
          ),
          child: Container(
            margin: EdgeInsets.only(top: _starts ? 6 : 2),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            decoration: BoxDecoration(
              color: own ? c.accentSoft : c.surfaceRaised,
              borderRadius: radius,
            ),
            child: _merge(
              IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_starts && sender != null)
                      Text(
                        sender!,
                        style: ArveilType.label.copyWith(
                          fontSize: 13,
                          color: senderColor ?? c.inkSoft,
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: DefaultTextStyle.merge(
                        style: ArveilType.messageBody.copyWith(color: c.ink),
                        child: child,
                      ),
                    ),
                    if (meta case final meta?)
                      Align(alignment: Alignment.centerRight, child: meta),
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
                              Expanded(
                                child: NameLine(
                                  name: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ArveilType.rowName.copyWith(
                                      color: c.ink,
                                    ),
                                  ),
                                  verified: verified,
                                  unverified: unverified,
                                ),
                              ),
                              const SizedBox(width: 8),
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

/// Where a message is written: attach, type, send. The keyboard learns
/// nothing from what is typed here.
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.onSend,
    this.onAttach,
    this.canAttach = true,
    this.hint,
    this.enabled = true,
    this.maxLength,
    this.fieldKey,
    this.sendKey,
    this.attachKey,
    this.wrapField,
  });
  final TextEditingController controller;

  /// Null disables the send button, as while a message is being saved.
  final VoidCallback? onSend;

  /// Shows the attach button when set.
  final VoidCallback? onAttach;
  final bool canAttach;

  /// Defaults to the language's word for a message.
  final String? hint;
  final bool enabled;
  final int? maxLength;
  final Key? fieldKey;
  final Key? sendKey;
  final Key? attachKey;

  /// Wraps the text field, for instance with keyboard shortcuts.
  final Widget Function(Widget field)? wrapField;

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
                key: attachKey,
                tooltip: context.l10n.attachFile,
                onPressed: enabled && canAttach ? onAttach : null,
                icon: Icon(Icons.attach_file, color: c.inkSoft),
              ),
            Expanded(
              child: (wrapField ?? (field) => field)(
                TextField(
                  key: fieldKey,
                  controller: controller,
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: maxLength,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  textCapitalization: TextCapitalization.sentences,
                  style: ArveilType.messageBody.copyWith(color: c.ink),
                  decoration: InputDecoration(
                    hintText: hint ?? context.l10n.messageHint,
                    counterText: '',
                    isDense: true,
                    // At least 48 dp tall, the touch target a field needs.
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
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
            ),
            const SizedBox(width: ArveilShape.s2),
            IconButton.filled(
              key: sendKey,
              tooltip: context.l10n.send,
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ),
    );
  }
}
