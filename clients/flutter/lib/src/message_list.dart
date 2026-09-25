import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'conversation_text.dart';
import 'design/design.dart';
import 'rust/api/profile.dart';

/// One line of a conversation's history: a day, or an event with its place
/// in a run from one author.
sealed class HistoryItem {
  const HistoryItem();
}

class DayItem extends HistoryItem {
  const DayItem(this.day);
  final DateTime day;
}

class EventItem extends HistoryItem {
  const EventItem(this.event, this.position);
  final HistoryEventView event;
  final BubblePosition position;
}

DateTime _local(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

DateTime _day(DateTime at) => DateTime(at.year, at.month, at.day);

/// Whether this device wrote the event, whatever its kind.
bool mine(HistoryEventView event) => event.attachment?.outgoing ?? event.own;

String _author(HistoryEventView event) =>
    mine(event) ? '' : event.senderIdentity ?? '?';

/// Messages from one author a few minutes apart on the same day share a
/// run; notices always stand alone.
bool _joined(HistoryEventView a, HistoryEventView b) {
  if (a.notice != null || b.notice != null || _author(a) != _author(b)) {
    return false;
  }
  if (a.createdAt <= 0 || b.createdAt <= 0) {
    return a.createdAt <= 0 && b.createdAt <= 0;
  }
  return (b.createdAt - a.createdAt).abs() <= 600 &&
      _day(_local(a.createdAt)) == _day(_local(b.createdAt));
}

/// The history in reading order, with a day before the first event of
/// each local date. Events without a recorded time get no day.
List<HistoryItem> historyItems(List<HistoryEventView> events) {
  final items = <HistoryItem>[];
  DateTime? lastDay;
  for (var i = 0; i < events.length; i++) {
    final event = events[i];
    if (event.createdAt > 0) {
      final day = _day(_local(event.createdAt));
      if (day != lastDay) {
        items.add(DayItem(day));
        lastDay = day;
      }
    }
    final previous = i > 0 && _joined(events[i - 1], event);
    final next = i + 1 < events.length && _joined(event, events[i + 1]);
    items.add(
      EventItem(event, switch ((previous, next)) {
        (false, false) => BubblePosition.single,
        (false, true) => BubblePosition.first,
        (true, true) => BubblePosition.middle,
        (true, false) => BubblePosition.last,
      }),
    );
  }
  return items;
}

/// "Today", "Yesterday" or the date, for a day separator.
String dayLabel(DateTime day, {DateTime? now}) {
  final today = _day(now ?? DateTime.now());
  return switch (today.difference(_day(day)).inDays) {
    0 => currentStrings.today,
    1 => currentStrings.yesterday,
    _ => numericDate(currentStrings, day),
  };
}

/// A text message, a legacy event, or a device-change notice.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.event,
    this.showSender = false,
    this.senderVerified = false,
    this.position = BubblePosition.single,
  });
  final HistoryEventView event;

  /// Name who wrote a received message, for conversations where more than
  /// one other person writes.
  final bool showSender;

  /// The user verified the identity that wrote this event.
  final bool senderVerified;
  final BubblePosition position;

  String _text(AppLocalizations l10n) =>
      event.kind == 'received' || event.kind == 'sent'
      ? utf8.decode(event.body, allowMalformed: true)
      : event.kind.startsWith('file')
      ? l10n.legacyAttachment
      : l10n.conversationEvent;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (event.notice case final notice?) {
      return NoticeChip(
        key: Key('notice-${event.eventId}'),
        text: noticeText(event.senderLabel, notice),
        detail: senderVerified ? l10n.noticeSigned : l10n.noticeCompare,
        meta: event.createdAt > 0 ? clockTime(_local(event.createdAt)) : null,
      );
    }
    final own = mine(event);
    final identity = event.senderIdentity;
    return GestureDetector(
      onLongPress: () => showMessageDetails(context, event),
      onSecondaryTap: () => showMessageDetails(context, event),
      child: ChatBubble(
        key: Key('message-${event.eventId}'),
        own: own,
        position: position,
        sender: showSender && !own ? event.senderLabel : null,
        senderColor: identity == null
            ? null
            : ArveilColors.of(context).senderFor(identity),
        meta: BubbleMeta(
          time: event.createdAt > 0 ? clockTime(_local(event.createdAt)) : '',
          own: own,
          status: event.kind == 'sent' ? deliveryStatus(event.delivery) : null,
        ),
        child: Text(_text(l10n)),
      ),
    );
  }
}

/// What one mailbox's delivery state means, in words that never claim
/// anyone read the message.
String mailboxState(AppLocalizations l10n, String state) =>
    switch (deliveryStatus([state])) {
      DeliveryStatus.accepted => l10n.deliveryAccepted,
      DeliveryStatus.rejected => l10n.mailboxRejected,
      DeliveryStatus.expired => l10n.deliveryExpired,
      DeliveryStatus.pending || DeliveryStatus.none => l10n.deliveryWaiting,
    };

/// When and how a message arrived or left, per mailbox for what this
/// device sent, with a way to copy its text. A sheet on phones, a dialog
/// elsewhere.
Future<void> showMessageDetails(BuildContext context, HistoryEventView event) {
  final l10n = context.l10n;
  final text = event.kind == 'received' || event.kind == 'sent'
      ? utf8.decode(event.body, allowMalformed: true)
      : null;
  // A file this device sent has per-mailbox delivery like a text.
  final sentHere =
      event.kind == 'sent' || (event.attachment?.outgoing ?? false);
  Widget content(BuildContext context) => Column(
    key: const Key('message-details'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (event.createdAt > 0)
        Text(l10n.messageRecordedAt(recordedTime(event.createdAt))),
      const SizedBox(height: 12),
      if (!sentHere)
        Text(
          event.own ? l10n.sentFromOtherDevice : l10n.receivedHere,
          style: Theme.of(context).textTheme.bodyMedium,
        )
      else if (event.delivery.isEmpty)
        Text(l10n.deliveryNoRecipients)
      else ...[
        Text(
          l10n.deliveryPerMailbox,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        for (final (i, state) in event.delivery.indexed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: DeliveryIcon(status: deliveryStatus([state]), size: 20),
            title: Text(l10n.mailboxNumber(i + 1)),
            subtitle: Text(mailboxState(l10n, state)),
          ),
      ],
    ],
  );
  List<Widget> actions(BuildContext context) => [
    if (text != null)
      TextButton.icon(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: text));
          if (context.mounted) {
            Navigator.pop(context);
            ScaffoldMessenger.maybeOf(
              context,
            )?.showSnackBar(SnackBar(content: Text(l10n.textCopied)));
          }
        },
        icon: const Icon(Icons.copy_outlined),
        label: Text(l10n.copyText),
      ),
    TextButton(
      onPressed: () => Navigator.pop(context),
      child: Text(l10n.close),
    ),
  ];
  if (WindowSize.of(context) == WindowSize.compact) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.messageDetails,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              content(context),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                children: actions(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.messageDetails),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(child: content(context)),
      ),
      actions: actions(context),
    ),
  );
}
