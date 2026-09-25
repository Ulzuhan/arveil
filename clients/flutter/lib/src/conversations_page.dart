import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'conversation_controller.dart';
import 'attachment_card.dart';
import 'attachment_files.dart';
import 'chat_list.dart';
import 'contacts_page.dart';
import 'conversation_details.dart';
import 'conversation_text.dart';
import 'design/design.dart';
import 'message_list.dart';
import 'rust/api/profile.dart';

export 'conversation_text.dart';
export 'message_list.dart';

class ConversationsPage extends StatefulWidget {
  const ConversationsPage({
    super.key,
    required this.controller,
    this.attachmentFiles = const AttachmentFiles(),
    this.twoPane,
    this.active = true,
    this.notices = const [],
  });
  final ConversationController controller;
  final AttachmentFiles attachmentFiles;

  /// List and conversation side by side; by default when the window is
  /// expanded.
  final bool? twoPane;

  /// Whether this page is the destination on screen, so the back gesture
  /// is its own.
  final bool active;

  /// Shown above the chat list, such as the kit reminder.
  final List<Widget> notices;

  @override
  State<ConversationsPage> createState() => ConversationsPageState();
}

/// Public so the navigation's shortcuts can drive the page.
class ConversationsPageState extends State<ConversationsPage>
    with WidgetsBindingObserver {
  final _draft = TextEditingController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'chat search');
  final Map<String, String> _drafts = {};
  bool _fileDialog = false;
  bool _detailsOpen = false;
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
    _search.dispose();
    _searchFocus.dispose();
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

  /// Opens the new conversation screen, unless one is being created.
  Future<void> newConversation() async {
    if (!chat.creating) await _create();
  }

  /// Opens the conversation [step] rows away from the open one, or the
  /// first or last when none is open.
  Future<void> selectAdjacent(int step) async {
    final rows = chat.conversations;
    if (rows.isEmpty) return;
    final at = rows.indexWhere((c) => c.groupId == chat.selected);
    final next = at < 0
        ? (step > 0 ? 0 : rows.length - 1)
        : (at + step).clamp(0, rows.length - 1);
    if (next != at) await _select(rows[next].groupId);
  }

  /// Puts the cursor in the chat search, closing a conversation that
  /// covers the list on a phone.
  void focusSearch() {
    final covered =
        !(widget.twoPane ?? WindowSize.of(context).twoPane) &&
        chat.selected != null;
    if (!covered) return _searchFocus.requestFocus();
    unawaited(_select(null));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
  }

  /// Closes the open conversation, keeping its draft.
  Future<void> closeConversation() => _select(null);

  /// On desktop Enter sends and Shift+Enter starts a new line; on phones
  /// Enter starts a new line.
  bool get _enterSends => switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };

  String get _selectedTitle {
    final rows = chat.conversations.where((c) => c.groupId == chat.selected);
    return rows.isEmpty
        ? context.l10n.conversationFallback(shortId(chat.selected!))
        : conversationTitle(rows.first);
  }

  ConversationView? get _selectedRow {
    final rows = chat.conversations.where((c) => c.groupId == chat.selected);
    return rows.isEmpty ? null : rows.first;
  }

  /// Whether the details panel can sit beside an open conversation.
  bool _detailsFit(BuildContext context, bool wide) =>
      wide && MediaQuery.sizeOf(context).width >= WindowSize.detailsFrom;

  /// Details beside the conversation on the widest windows, in a sheet on
  /// phones and in a dialog in between.
  Future<void> _showDetails(bool wide) async {
    final row = _selectedRow;
    if (row == null) return;
    if (_detailsFit(context, wide)) {
      setState(() => _detailsOpen = !_detailsOpen);
      return;
    }
    Widget details() => ListenableBuilder(
      listenable: chat,
      builder: (context, _) =>
          ConversationDetails(row: _selectedRow ?? row, events: chat.events),
    );
    if (WindowSize.of(context) == WindowSize.compact) {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: details(),
          ),
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.conversationDetails),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(child: details()),
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

  List<Widget> get _chatActions => [
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
  ];

  Widget _detailsButton(bool wide) => IconButton(
    tooltip: context.l10n.conversationDetails,
    onPressed: _selectedRow == null ? null : () => _showDetails(wide),
    isSelected: _detailsOpen && _detailsFit(context, wide),
    icon: const Icon(Icons.info_outline),
    selectedIcon: const Icon(Icons.info),
  );

  /// Failures and confirmations from the last action, where it happened:
  /// over the open conversation, or over the list.
  List<Widget> get _banners => [
    if (chat.error case final message?)
      _banner(
        StatusBanner(
          title: message,
          icon: Icons.error_outline,
          tone: BannerTone.error,
        ),
      ),
    if (chat.notice case final message?)
      _banner(
        StatusBanner(
          title: message,
          icon: Icons.info_outline,
          tone: BannerTone.info,
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: chat,
    builder: (context, _) {
      final wide = widget.twoPane ?? WindowSize.of(context).twoPane;
      final selected = chat.selected != null;
      final progress = chat.syncing
          ? LinearProgressIndicator(semanticsLabel: context.l10n.syncing)
          : null;
      return PopScope(
        canPop: !widget.active || wide || !selected,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && widget.active && !wide && chat.selected != null) {
            unawaited(_select(null));
          }
        },
        child: wide ? _twoPanes(progress) : _onePane(progress),
      );
    },
  );

  /// Phones and medium windows: the list, or the open conversation.
  Widget _onePane(Widget? progress) {
    final selected = chat.selected != null;
    return Scaffold(
      appBar: selected
          ? AppBar(
              leading: IconButton(
                tooltip: context.l10n.backToConversations,
                onPressed: () => _select(null),
                icon: const Icon(Icons.arrow_back),
              ),
              titleSpacing: 0,
              title: ConversationHeader(
                title: _selectedTitle,
                row: _selectedRow,
              ),
              actions: [_detailsButton(false)],
            )
          : AppBar(title: Text(context.l10n.navChats), actions: _chatActions),
      body: SafeArea(
        child: Column(
          children: [
            ?progress,
            ..._banners,
            Expanded(child: selected ? _history(offline: true) : _list()),
          ],
        ),
      ),
    );
  }

  /// Wide windows: the list, the conversation and, from 1200 dp, its
  /// details, each with its own bar.
  Widget _twoPanes(Widget? progress) {
    final selected = chat.selected != null;
    final row = _selectedRow;
    final details =
        selected && row != null && _detailsOpen && _detailsFit(context, true);
    final c = ArveilColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: 340,
              child: FocusTraversalGroup(
                child: Column(
                  children: [
                    AppBar(
                      primary: false,
                      automaticallyImplyLeading: false,
                      title: Text(context.l10n.navChats),
                      actions: _chatActions,
                    ),
                    ?progress,
                    if (!selected) ..._banners,
                    Expanded(child: _list()),
                  ],
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: FocusTraversalGroup(
                child: selected
                    ? Column(
                        children: [
                          AppBar(
                            primary: false,
                            automaticallyImplyLeading: false,
                            title: ConversationHeader(
                              title: _selectedTitle,
                              row: row,
                            ),
                            actions: [_detailsButton(true)],
                          ),
                          ..._banners,
                          Expanded(child: _history(offline: false)),
                        ],
                      )
                    : EmptyState(
                        icon: Icons.forum_outlined,
                        title: context.l10n.chooseConversation,
                      ),
              ),
            ),
            if (details) ...[
              const VerticalDivider(width: 1),
              SizedBox(
                width: 320,
                child: FocusTraversalGroup(
                  child: Material(
                    color: c.bar,
                    child: Column(
                      children: [
                        AppBar(
                          primary: false,
                          automaticallyImplyLeading: false,
                          title: Text(context.l10n.conversationDetails),
                          actions: [
                            IconButton(
                              tooltip: context.l10n.close,
                              onPressed: () =>
                                  setState(() => _detailsOpen = false),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                            child: ConversationDetails(
                              row: row,
                              events: chat.events,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _banner(Widget banner) =>
      Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: banner);

  Widget _list() => ChatList(
    chat: chat,
    search: _search,
    searchFocus: _searchFocus,
    onOpen: _select,
    onNew: chat.creating ? null : _create,
    notices: [
      ...widget.notices,
      if (chat.networkError case final message?)
        StatusBanner(
          title: chat.syncState == SyncState.refused
              ? context.l10n.syncRefusedTitle
              : context.l10n.offlineTitle,
          body: message,
          icon: chat.syncState == SyncState.refused
              ? Icons.sync_problem
              : Icons.cloud_off_outlined,
        ),
    ],
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

  Widget _enterToSend(Widget field) => _enterSends
      ? Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): _SendIntent(),
            SingleActivator(LogicalKeyboardKey.numpadEnter): _SendIntent(),
          },
          child: Actions(
            actions: {_SendIntent: _SendAction(this)},
            child: field,
          ),
        )
      : field;

  /// The open conversation: its history in runs and days, older pages on
  /// request, and the composer. [offline] adds the connection banner when
  /// the list, which already shows it, is not on screen.
  Widget _history({required bool offline}) {
    final items = historyItems(chat.events).reversed.toList();
    final group = chat.selected!;
    final named = _group;
    return Column(
      children: [
        if (chat.sending)
          LinearProgressIndicator(semanticsLabel: context.l10n.savingMessage),
        if (offline && chat.networkError != null)
          _banner(
            StatusBanner(
              key: const Key('conversation-offline'),
              title: chat.syncState == SyncState.refused
                  ? context.l10n.syncRefusedTitle
                  : context.l10n.offlineTitle,
              body: chat.networkError,
              icon: chat.syncState == SyncState.refused
                  ? Icons.sync_problem
                  : Icons.cloud_off_outlined,
            ),
          ),
        Expanded(
          child: chat.loading
              ? const Center(child: CircularProgressIndicator())
              : chat.events.isEmpty
              ? SingleChildScrollView(
                  child: EmptyState(
                    icon: Icons.chat_bubble_outline,
                    title: context.l10n.firstMessage,
                  ),
                )
              : ListView.builder(
                  key: ValueKey('history-$group'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  reverse: true,
                  itemCount: items.length + (chat.before == null ? 0 : 1),
                  itemBuilder: (context, index) {
                    if (index == items.length) {
                      return Center(
                        child: TextButton(
                          onPressed: chat.loadingOlder ? null : chat.older,
                          child: Text(
                            chat.loadingOlder
                                ? context.l10n.reading
                                : context.l10n.loadOlder,
                          ),
                        ),
                      );
                    }
                    return switch (items[index]) {
                      DayItem(:final day) => DateSeparator(dayLabel(day)),
                      EventItem(:final event, :final position)
                          when event.attachment != null =>
                        AttachmentCard(
                          event: event,
                          position: position,
                          active: chat.activeTransfers.contains(event.eventId),
                          resume: () =>
                              chat.resumeAttachment(group, event.eventId),
                          cancel: () =>
                              chat.cancelAttachment(group, event.eventId),
                          export: () => _export(group, event),
                        ),
                      EventItem(:final event, :final position) => MessageBubble(
                        event: event,
                        position: position,
                        showSender: named,
                        senderVerified: _verified(event.senderIdentity),
                      ),
                    };
                  },
                ),
        ),
        Composer(
          controller: _draft,
          fieldKey: const Key('message-draft'),
          sendKey: const Key('send-message'),
          attachKey: const Key('attach-file'),
          maxLength: 32768,
          onAttach: _attach,
          canAttach: !_fileDialog,
          onSend: chat.sending ? null : _send,
          wrapField: _enterToSend,
        ),
      ],
    );
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}

/// Sends on Enter, except while an input method is composing text, when
/// Enter confirms the composition instead.
class _SendAction extends Action<_SendIntent> {
  _SendAction(this.page);
  final ConversationsPageState page;

  @override
  bool isEnabled(_SendIntent intent) {
    final composing = page._draft.value.composing;
    return !composing.isValid || composing.isCollapsed;
  }

  @override
  Object? invoke(_SendIntent intent) {
    if (!page.chat.sending) unawaited(page._send());
    return null;
  }
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
