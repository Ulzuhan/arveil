import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'conversation_controller.dart';
import 'attachment_card.dart';
import 'attachment_files.dart';
import 'contacts_page.dart';
import 'rust/api/profile.dart';

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

class ConversationsPage extends StatefulWidget {
  const ConversationsPage({
    super.key,
    required this.controller,
    this.attachmentFiles = const AttachmentFiles(),
  });
  final ConversationController controller;
  final AttachmentFiles attachmentFiles;

  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage>
    with WidgetsBindingObserver {
  final _draft = TextEditingController();
  final Map<String, String> _drafts = {};
  bool _fileDialog = false;
  ConversationController get chat => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(chat.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    chat.setActive(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draft.dispose();
    chat.dispose();
    super.dispose();
  }

  Future<void> _select(String? group) async {
    if (chat.selected case final id?) _drafts[id] = _draft.text;
    _draft.text = _drafts[group] ?? '';
    await chat.select(group);
  }

  Future<void> _send() async {
    final group = chat.selected;
    final text = _draft.text;
    if (await chat.send(text) && mounted) {
      if (chat.selected == group && _draft.text == text) _draft.clear();
      if (_drafts[group] == text) _drafts.remove(group);
    }
  }

  Future<void> _attach() async {
    final group = chat.selected;
    if (_fileDialog || group == null) return;
    setState(() => _fileDialog = true);
    try {
      final file = await widget.attachmentFiles.open();
      if (!mounted || file == null || chat.selected != group) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.sendFile),
          content: SingleChildScrollView(
            child: Text(
              context.l10n.attachConfirm(
                file.name,
                attachmentSize(BigInt.from(file.bytes.length)),
                _selectedTitle,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              key: const Key('confirm-attachment'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.sendFile),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted && chat.selected == group) {
        await chat.queueAttachment(group, file);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.fileReadFailed)));
      }
    } finally {
      if (mounted) setState(() => _fileDialog = false);
    }
  }

  Future<void> _export(String group, HistoryEventView event) async {
    if (_fileDialog) return;
    setState(() => _fileDialog = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.exportTitle),
          content: Text(context.l10n.exportWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              key: const Key('confirm-export'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.exportChoose),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final bytes = await chat.profile.exportAttachment(
        groupId: group,
        eventId: event.eventId,
      );
      if (!mounted) return;
      final saved = await widget.attachmentFiles.save(
        event.attachment!.name,
        bytes,
      );
      if (saved && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.exportSaved)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.exportFailed)));
      }
    } finally {
      if (mounted) setState(() => _fileDialog = false);
    }
  }

  Future<void> _create() async {
    if (chat.selected case final id?) _drafts[id] = _draft.text;
    final group = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => NewConversationPage(chat: chat)),
    );
    if (group != null && mounted) _draft.text = _drafts[group] ?? '';
  }

  Future<void> _contacts() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => ContactsPage(profile: chat.profile)),
    );
    if (mounted) await chat.refresh();
  }

  String get _selectedTitle {
    final rows = chat.conversations.where((c) => c.groupId == chat.selected);
    return rows.isEmpty
        ? context.l10n.conversationFallback(shortId(chat.selected!))
        : conversationTitle(rows.first);
  }

  Future<void> _participants() async {
    final rows = chat.conversations.where((c) => c.groupId == chat.selected);
    if (rows.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.participants),
        content: SizedBox(
          width: 440,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final peer in rows.first.peers)
                ListTile(
                  title: Text(
                    peer.own ? context.l10n.participantsYou : peer.label,
                  ),
                  subtitle: Text(
                    '${context.l10n.participantDevice(shortId(peer.identityId), shortId(peer.deviceId))}\n${peer.revoked
                        ? context.l10n.revoked
                        : peer.own
                        ? context.l10n.ownDevice
                        : peer.verified
                        ? context.l10n.verified
                        : context.l10n.unverified}',
                  ),
                  isThreeLine: true,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.close),
          ),
        ],
      ),
    );
  }

  Future<void> _shareRoute() async {
    try {
      final route = await chat.profile.ownRoute();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.ownRouteTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.ownRouteShare),
                const SizedBox(height: 16),
                SelectableText(route, key: const Key('own-route')),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.close),
            ),
            FilledButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: route));
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(context.l10n.ownRouteCopy),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.ownRouteFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: chat,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final selected = chat.selected != null;
        return PopScope(
          canPop: wide || !selected,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_select(null));
          },
          child: Scaffold(
            appBar: AppBar(
              leading: !wide && selected
                  ? IconButton(
                      tooltip: context.l10n.backToConversations,
                      onPressed: () => _select(null),
                      icon: const Icon(Icons.arrow_back),
                    )
                  : null,
              title: Text(
                !wide && selected
                    ? _selectedTitle
                    : context.l10n.conversationsTitle,
              ),
              actions: [
                IconButton(
                  tooltip: context.l10n.contactsTitle,
                  onPressed: _contacts,
                  icon: const Icon(Icons.contacts_outlined),
                ),
                IconButton(
                  tooltip: context.l10n.myRoute,
                  onPressed: _shareRoute,
                  icon: const Icon(Icons.share_outlined),
                ),
                IconButton(
                  tooltip: context.l10n.newConversation,
                  onPressed: chat.creating ? null : _create,
                  icon: const Icon(Icons.edit_square),
                ),
                IconButton(
                  tooltip: context.l10n.sync,
                  onPressed: chat.syncing ? null : chat.sync,
                  icon: const Icon(Icons.sync),
                ),
              ],
            ),
            body: SafeArea(
              child: Column(
                children: [
                  if (chat.syncing)
                    LinearProgressIndicator(
                      semanticsLabel: context.l10n.syncing,
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                    child: Text(
                      syncStatusText(
                        chat.syncState,
                        chat.lastSynced,
                        DateTime.now(),
                      ),
                      key: const Key('sync-status'),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  if (chat.networkError case final message?) _banner(message),
                  if (chat.error case final message?)
                    _banner(message, error: true),
                  if (chat.notice case final message?) _banner(message),
                  Expanded(
                    child: wide
                        ? Row(
                            children: [
                              SizedBox(width: 280, child: _list()),
                              const VerticalDivider(width: 1),
                              Expanded(
                                child: selected
                                    ? _history()
                                    : Center(
                                        child: Text(
                                          context.l10n.chooseConversation,
                                        ),
                                      ),
                              ),
                            ],
                          )
                        : selected
                        ? _history()
                        : _list(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _banner(String message, {bool error = false}) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: error
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Text(message, style: Theme.of(context).textTheme.bodySmall),
    ),
  );

  Widget _list() => chat.conversations.isEmpty
      ? ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(Icons.forum_outlined, size: 40),
            const SizedBox(height: 16),
            Text(context.l10n.conversationsEmpty),
            const SizedBox(height: 12),
            Text(context.l10n.conversationsEmptyHelp),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: chat.creating ? null : _create,
              child: Text(context.l10n.newConversation),
            ),
          ],
        )
      : ListView.builder(
          itemCount: chat.conversations.length,
          itemBuilder: (context, index) {
            final row = chat.conversations[index];
            return ListTile(
              key: Key('conversation-${row.groupId}'),
              selected: chat.selected == row.groupId,
              leading: const Icon(Icons.forum_outlined),
              title: Text(
                conversationTitle(row),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                switch (row.lastEvent) {
                  final last? => rowPreview(row, last),
                  null => context.l10n.conversationCounts(
                    row.peerDevices,
                    row.eventCount,
                  ),
                },
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (row.lastActivity > 0)
                    Text(
                      recordedTime(row.lastActivity),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  if (row.unread > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Semantics(
                        label: context.l10n.unreadMessages(row.unread),
                        excludeSemantics: true,
                        child: Badge.count(
                          key: Key('unread-${row.groupId}'),
                          count: row.unread,
                        ),
                      ),
                    ),
                ],
              ),
              onTap: () => _select(row.groupId),
            );
          },
        );

  /// Whether more than one other person writes here, so received messages
  /// need their author named.
  bool get _group =>
      chat.conversations.where((c) => c.groupId == chat.selected).any(isGroup);

  /// Whether the user verified the identity that wrote an event.
  bool _verified(String? identity) =>
      identity != null &&
      chat.conversations
          .where((c) => c.groupId == chat.selected)
          .expand((c) => c.peers)
          .any((p) => p.identityId == identity && p.verified);

  Widget _history() => Column(
    children: [
      if (chat.sending)
        LinearProgressIndicator(semanticsLabel: context.l10n.savingMessage),
      ListTile(
        title: Text(
          _selectedTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(context.l10n.localHistory(shortId(chat.selected!))),
        trailing: IconButton(
          tooltip: context.l10n.participants,
          onPressed: _participants,
          icon: const Icon(Icons.people_outline),
        ),
      ),
      Expanded(
        child: chat.loading
            ? const Center(child: CircularProgressIndicator())
            : chat.events.isEmpty
            ? Center(child: Text(context.l10n.firstMessage))
            : ListView.builder(
                key: ValueKey('history-${chat.selected}'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                reverse: true,
                itemCount: chat.events.length + (chat.before == null ? 0 : 1),
                itemBuilder: (context, index) {
                  if (index == chat.events.length) {
                    return TextButton(
                      onPressed: chat.loadingOlder ? null : chat.older,
                      child: Text(
                        chat.loadingOlder
                            ? context.l10n.reading
                            : context.l10n.loadOlder,
                      ),
                    );
                  }
                  final event = chat.events[chat.events.length - 1 - index];
                  final group = chat.selected!;
                  if (event.attachment != null) {
                    return AttachmentCard(
                      event: event,
                      active: chat.activeTransfers.contains(event.eventId),
                      resume: () => chat.resumeAttachment(group, event.eventId),
                      cancel: () => chat.cancelAttachment(group, event.eventId),
                      export: () => _export(group, event),
                    );
                  }
                  return MessageBubble(
                    event: event,
                    showSender: _group,
                    senderVerified: _verified(event.senderIdentity),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              key: const Key('attach-file'),
              tooltip: context.l10n.attachFile,
              onPressed: _fileDialog ? null : _attach,
              icon: const Icon(Icons.attach_file),
            ),
            Expanded(
              child: TextField(
                key: const Key('message-draft'),
                controller: _draft,
                minLines: 1,
                maxLines: 5,
                maxLength: 32768,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                  labelText: context.l10n.messageHint,
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              key: const Key('send-message'),
              tooltip: context.l10n.send,
              onPressed: chat.sending ? null : _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    ],
  );
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.event,
    this.showSender = false,
    this.senderVerified = false,
  });
  final HistoryEventView event;

  /// Name who wrote a received message, for conversations where more than
  /// one other person writes.
  final bool showSender;

  /// The user verified the identity that wrote this event.
  final bool senderVerified;

  Widget _notice(BuildContext context, NoticeView notice) {
    final theme = Theme.of(context);
    return Align(
      child: Container(
        key: Key('notice-${event.eventId}'),
        constraints: const BoxConstraints(maxWidth: 420),
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              noticeText(event.senderLabel, notice),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 2),
            Text(
              senderVerified
                  ? context.l10n.noticeSigned
                  : context.l10n.noticeCompare,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall,
            ),
            if (event.createdAt > 0)
              Text(
                recordedTime(event.createdAt),
                style: theme.textTheme.labelSmall,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (event.notice case final notice?) return _notice(context, notice);
    final sent = event.kind == 'sent';
    final mine = event.own;
    final text = event.kind == 'received' || sent
        ? utf8.decode(event.body, allowMalformed: true)
        : event.kind.startsWith('file')
        ? context.l10n.legacyAttachment
        : currentStrings.conversationEvent;
    final status = !sent
        ? mine
              ? context.l10n.sentFromOtherDevice
              : context.l10n.receivedHere
        : event.delivery.isEmpty
        ? context.l10n.deliveryNoRecipients
        : event.delivery.any((s) => s.startsWith('undeliverable'))
        ? context.l10n.deliveryRejected
        : event.delivery.any((s) => s == 'expired/unknown')
        ? context.l10n.deliveryExpired
        : event.delivery.every((s) => s.startsWith('accepted'))
        ? context.l10n.deliveryAccepted
        : context.l10n.deliveryPending;
    final sender = showSender && !mine ? event.senderLabel : null;
    final meta = Theme.of(context).textTheme.labelSmall;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: Key('message-${event.eventId}'),
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: mine
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sender != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  sender,
                  key: Key('sender-${event.eventId}'),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            SelectableText(text),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                if (event.createdAt > 0)
                  Text(
                    recordedTime(event.createdAt),
                    key: Key('time-${event.eventId}'),
                    style: meta,
                  ),
                Text(status, style: meta),
              ],
            ),
          ],
        ),
      ),
    );
  }
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

class NewConversationPage extends StatefulWidget {
  const NewConversationPage({super.key, required this.chat});
  final ConversationController chat;
  @override
  State<NewConversationPage> createState() => _NewConversationPageState();
}

class _NewConversationPageState extends State<NewConversationPage> {
  final _routes = TextEditingController();
  List<String> _checkedRoutes = [];
  List<RoutePreviewView> _previews = [];
  bool _compared = false;
  bool _checking = false;
  String? _error;
  int _revision = 0;
  @override
  void dispose() {
    _routes.dispose();
    super.dispose();
  }

  Future<void> _chooseContacts() async {
    final recipients = await Navigator.of(context)
        .push<List<SavedRecipientView>>(
          MaterialPageRoute(
            builder: (_) => ContactsPage(
              profile: widget.chat.profile,
              selectRecipients: true,
            ),
          ),
        );
    if (!mounted || recipients == null) return;
    final group = await widget.chat.createSaved(recipients);
    if (!mounted) return;
    if (group != null) {
      Navigator.pop(context, group);
    } else {
      setState(() => _error = widget.chat.error);
    }
  }

  Future<void> _preview() async {
    final routes = _routes.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final revision = ++_revision;
    setState(() {
      _checking = true;
      _error = null;
      _compared = false;
      _previews = [];
    });
    try {
      final previews = await widget.chat.profile.previewRoutes(routes: routes);
      if (mounted && revision == _revision) {
        setState(() {
          _checkedRoutes = routes;
          _previews = previews;
        });
      }
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() => _error = context.l10n.newConversationRoutesInvalid);
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _create() async {
    final group = await widget.chat.create(
      _checkedRoutes,
      _previews.map((p) => p.safetyNumber).toList(),
    );
    if (!mounted) return;
    if (group != null) {
      Navigator.pop(context, group);
    } else {
      setState(() => _error = widget.chat.error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.chat,
    builder: (context, _) {
      final busy = _checking || widget.chat.creating;
      return PopScope(
        canPop: !widget.chat.creating,
        child: Scaffold(
          appBar: AppBar(title: Text(context.l10n.newConversation)),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    FilledButton.icon(
                      key: const Key('choose-contacts'),
                      onPressed: busy ? null : _chooseContacts,
                      icon: const Icon(Icons.contacts_outlined),
                      label: Text(context.l10n.newConversationChooseContacts),
                    ),
                    const SizedBox(height: 20),
                    Text(context.l10n.newConversationRoutesHelp),
                    const SizedBox(height: 20),
                    TextField(
                      key: const Key('peer-routes'),
                      controller: _routes,
                      enabled: !busy,
                      minLines: 3,
                      maxLines: 6,
                      maxLength: 65536,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      decoration: InputDecoration(
                        labelText: context.l10n.newConversationRoutesLabel,
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() {
                        _revision++;
                        _previews = [];
                        _checkedRoutes = [];
                        _compared = false;
                        _error = null;
                      }),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: busy ? null : _preview,
                      child: Text(context.l10n.newConversationPrepare),
                    ),
                    for (final preview in _previews)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.identityDevice(
                                  shortId(preview.identityId),
                                  shortId(preview.deviceId),
                                ),
                              ),
                              const SizedBox(height: 12),
                              SelectableText(
                                preview.safetyNumber,
                                key: Key('safety-${preview.deviceId}'),
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_previews.isNotEmpty) ...[
                      CheckboxListTile(
                        key: const Key('compared-routes'),
                        contentPadding: EdgeInsets.zero,
                        value: _compared,
                        onChanged: busy
                            ? null
                            : (v) => setState(() => _compared = v!),
                        title: Text(context.l10n.newConversationCompared),
                      ),
                      FilledButton(
                        key: const Key('create-conversation'),
                        onPressed: busy || !_compared ? null : _create,
                        child: Text(context.l10n.newConversationCreate),
                      ),
                    ],
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: LinearProgressIndicator(),
                      ),
                    if (_error case final message?)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(message),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
