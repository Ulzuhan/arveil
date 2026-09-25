import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'conversation_controller.dart';
import 'conversation_text.dart';
import 'design/design.dart';
import 'message_list.dart';
import 'rust/api/profile.dart';

/// Search inside the open conversation: a field, matching messages newest
/// first, and a way to keep searching further back when a bounded read
/// stopped. Escape or the close button returns to the conversation.
class ConversationSearch extends StatefulWidget {
  const ConversationSearch({
    super.key,
    required this.chat,
    required this.onClose,
  });
  final ConversationController chat;
  final VoidCallback onClose;

  @override
  State<ConversationSearch> createState() => _ConversationSearchState();
}

class _ConversationSearchState extends State<ConversationSearch> {
  final _field = TextEditingController();
  Timer? _debounce;
  String _query = '';
  List<HistoryEventView> _results = [];
  int? _next;
  bool _busy = false;
  bool _failed = false;
  int _version = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _typed(String text) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _search(text, fresh: true),
    );
  }

  Future<void> _search(String text, {required bool fresh}) async {
    final query = text.trim();
    final version = ++_version;
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _results = [];
        _next = null;
        _busy = false;
        _failed = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _query = query;
      if (fresh) {
        _results = [];
        _next = null;
      }
    });
    final page = await widget.chat.searchHistory(
      query,
      before: fresh ? null : _next,
    );
    if (!mounted || version != _version) return;
    setState(() {
      _busy = false;
      _failed = page == null;
      if (page != null) {
        _results = [..._results, ...page.events];
        _next = page.next;
      }
    });
  }

  Widget _older(AppLocalizations l10n) => Center(
    child: TextButton.icon(
      key: const Key('search-older'),
      onPressed: _busy ? null : () => _search(_query, fresh: false),
      icon: const Icon(Icons.history),
      label: Text(l10n.searchOlder),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = ArveilColors.of(context);
    Widget body;
    if (_query.isEmpty) {
      body = EmptyState(
        icon: Icons.search,
        title: l10n.searchConversationPrompt,
      );
    } else if (_failed) {
      body = EmptyState(icon: Icons.error_outline, title: l10n.searchFailed);
    } else if (_results.isEmpty && !_busy && _next == null) {
      body = EmptyState(
        icon: Icons.search_off,
        title: l10n.searchNoResults(_query),
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_results.isEmpty && !_busy)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.searchNothingRecent,
                textAlign: TextAlign.center,
                style: ArveilType.secondary.copyWith(color: c.inkMuted),
              ),
            ),
          for (final event in _results)
            ListTile(
              key: Key('search-result-${event.eventId}'),
              title: Text(
                utf8.decode(event.body, allowMalformed: true),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  mine(event)
                      ? l10n.you
                      : event.senderLabel ?? l10n.noticeSomeone,
                  if (event.createdAt > 0) recordedTime(event.createdAt),
                ].join(' · '),
              ),
              onTap: () => showMessageDetails(context, event),
            ),
          if (_next != null) _older(l10n),
        ],
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Actions(
            actions: {
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) => widget.onClose(),
              ),
            },
            child: TextField(
              key: const Key('conversation-search'),
              controller: _field,
              autofocus: true,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              onChanged: _typed,
              onSubmitted: (text) => _search(text, fresh: true),
              decoration: InputDecoration(
                hintText: l10n.searchConversationHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: l10n.closeSearch,
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        Expanded(child: body),
      ],
    );
  }
}
