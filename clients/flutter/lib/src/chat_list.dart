import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'conversation_controller.dart';
import 'conversation_text.dart';
import 'design/design.dart';

/// The chat list: search, the sync line and notices above the rows, or
/// what to do when there are none.
class ChatList extends StatelessWidget {
  const ChatList({
    super.key,
    required this.chat,
    required this.search,
    required this.searchFocus,
    required this.onOpen,
    required this.onNew,
    this.notices = const [],
  });
  final ConversationController chat;
  final TextEditingController search;
  final FocusNode searchFocus;
  final ValueChanged<String> onOpen;

  /// Starts a new conversation; null while one is being created.
  final VoidCallback? onNew;

  /// Banners above the rows, such as the kit reminder.
  final List<Widget> notices;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final margin = WindowSize.of(context).margin;
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) {
        final rows = [
          for (final row in chat.conversations)
            if (matchesSearch(row, search.text)) row,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (chat.conversations.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(margin, 8, margin, 0),
                child: _SearchField(controller: search, focus: searchFocus),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(margin + 4, 10, margin, 6),
              child: SyncLine(
                key: const Key('sync-status'),
                text: syncStatusText(
                  chat.syncState,
                  chat.lastSynced,
                  DateTime.now(),
                ),
                reached: switch (chat.syncState) {
                  SyncState.synced => true,
                  SyncState.offline || SyncState.refused => false,
                  SyncState.never || SyncState.syncing => null,
                },
              ),
            ),
            for (final notice in notices)
              Padding(
                padding: EdgeInsets.fromLTRB(margin, 4, margin, 4),
                child: notice,
              ),
            Expanded(
              child: chat.conversations.isEmpty
                  ? SingleChildScrollView(
                      child: EmptyState(
                        icon: Icons.forum_outlined,
                        title: l10n.conversationsEmpty,
                        body: l10n.conversationsEmptyHelp,
                        action: FilledButton.icon(
                          onPressed: onNew,
                          icon: const Icon(Icons.edit_outlined),
                          label: Text(l10n.newConversation),
                        ),
                      ),
                    )
                  : rows.isEmpty
                  ? SingleChildScrollView(
                      child: EmptyState(
                        icon: Icons.search_off,
                        title: l10n.chatSearchNone(search.text.trim()),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.fromLTRB(
                        margin - 8,
                        4,
                        margin - 8,
                        16,
                      ),
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        final last = row.lastEvent;
                        final verified = rowVerified(row);
                        return ConversationTile(
                          key: Key('conversation-${row.groupId}'),
                          identity: rowIdentity(row),
                          title: conversationTitle(row),
                          preview: last != null
                              ? rowPreview(row, last)
                              : l10n.conversationCounts(
                                  row.peerDevices,
                                  row.eventCount,
                                ),
                          time: row.lastActivity > 0
                              ? listTime(row.lastActivity)
                              : null,
                          unread: row.unread,
                          verified: verified == true,
                          unverified: verified == false,
                          status: rowStatus(last),
                          selected: chat.selected == row.groupId,
                          onTap: () => onOpen(row.groupId),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// Filters the list by conversation or contact name. Escape clears it.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.focus});
  final TextEditingController controller;
  final FocusNode focus;

  void _clear() {
    controller.clear();
    focus.unfocus();
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => _clear()),
    },
    child: TextField(
      key: const Key('chat-search'),
      controller: controller,
      focusNode: focus,
      textInputAction: TextInputAction.search,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      decoration: InputDecoration(
        hintText: context.l10n.chatSearchHint,
        isDense: true,
        prefixIcon: const Icon(Icons.search),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: context.l10n.chatSearchClear,
                onPressed: _clear,
                icon: const Icon(Icons.close),
              ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        filled: true,
        fillColor: ArveilColors.of(context).chip,
      ),
    ),
  );
}
