import '../l10n/l10n.dart';
import 'design/components.dart';
import 'rust/api/profile.dart';

// What the chat list and the conversation say about conversations, as
// text. Code outside widgets reads [currentStrings].

String shortId(String id) => id.length <= 12 ? id : id.substring(0, 12);

/// Whether more than one other identity writes in a conversation, so
/// messages need their author named.
bool isGroup(ConversationView row) =>
    row.peers.where((p) => !p.own).map((p) => p.identityId).toSet().length > 1;

/// What a device-change notice says: who changed which devices. Counts
/// only; Rust never names the devices.
String noticeText(String? who, NoticeView notice) {
  final s = currentStrings;
  final added = notice.added > 0 ? s.noticeAdded(notice.added) : null;
  final removed = notice.removed > 0 ? s.noticeRemoved(notice.removed) : null;
  final change = added != null && removed != null
      ? s.noticeBoth(added, removed)
      : added ?? removed ?? '';
  return s.noticeSentence(who ?? s.noticeSomeone, change);
}

/// One line about a conversation's newest event, for its row in the list.
String rowPreview(ConversationView row, LastEventView last) {
  if (last.notice case final notice?) {
    return noticeText(last.senderLabel, notice);
  }
  final text = last.preview.isNotEmpty
      ? last.preview
      : last.attachmentName != null
      ? currentStrings.previewAttachment(last.attachmentName!)
      : currentStrings.conversationEvent;
  if (last.own) return currentStrings.previewOwn(text);
  final label = last.senderLabel;
  return isGroup(row) && label != null ? '$label: $text' : text;
}

String conversationTitle(ConversationView row) {
  final people = <String, String>{
    for (final p in row.peers)
      if (!p.own) p.identityId: p.label,
  };
  return people.isEmpty
      ? currentStrings.conversationFallback(shortId(row.groupId))
      : people.values.join(', ');
}

/// When this device recorded an event, in local time: the hour for today,
/// the date and hour otherwise. It is when the event arrived or was written
/// here, never a claim about when its sender wrote it.
String recordedTime(int seconds, {DateTime? now}) {
  final at = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  final today = now ?? DateTime.now();
  final hour = clockTime(at);
  final sameDay =
      at.year == today.year && at.month == today.month && at.day == today.day;
  return sameDay ? hour : '${numericDate(currentStrings, at)} $hour';
}

/// When a row's conversation last changed: the hour today, "yesterday",
/// or the date.
String listTime(int seconds, {DateTime? now}) {
  final at = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  final today = now ?? DateTime.now();
  final days = DateTime(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime(at.year, at.month, at.day)).inDays;
  return switch (days) {
    0 => clockTime(at),
    1 => currentStrings.yesterday,
    _ => numericDate(currentStrings, at),
  };
}

/// The other people in a conversation, one entry per identity.
Map<String, PeerView> otherPeople(ConversationView row) => {
  for (final p in row.peers)
    if (!p.own && !p.revoked) p.identityId: p,
};

/// What chooses a row's avatar tone: the one other person, or the group.
String rowIdentity(ConversationView row) {
  final people = otherPeople(row);
  return people.length == 1 ? people.keys.single : row.groupId;
}

/// Whether everyone else was verified, nobody else is left (null), or
/// someone was not compared yet.
bool? rowVerified(ConversationView row) {
  final people = otherPeople(row).values;
  if (people.isEmpty) return null;
  return people.every((p) => p.verified);
}

/// Delivery of the newest message, when this device sent it.
DeliveryStatus? rowStatus(LastEventView? last) =>
    last != null && last.own && last.kind == 'sent'
    ? deliveryStatus(last.delivery)
    : null;

/// Lower case without accents, so "lucia" finds "Lucía".
String foldForSearch(String text) {
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const to = 'aaaaaeeeeiiiiooooouuuunc';
  final lower = text.toLowerCase();
  final out = StringBuffer();
  for (final char in lower.split('')) {
    final i = from.indexOf(char);
    out.write(i < 0 ? char : to[i]);
  }
  return out.toString();
}

/// Whether a search matches the conversation's title or anyone in it.
bool matchesSearch(ConversationView row, String query) {
  final wanted = foldForSearch(query.trim());
  if (wanted.isEmpty) return true;
  return [
    conversationTitle(row),
    for (final p in otherPeople(row).values) p.label,
  ].any((text) => foldForSearch(text).contains(wanted));
}
