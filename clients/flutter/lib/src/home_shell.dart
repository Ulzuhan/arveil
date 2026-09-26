import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'attachment_files.dart';
import 'contacts_page.dart';
import 'conversation_controller.dart';
import 'conversations_page.dart';
import 'design/design.dart';
import 'kit_files.dart';
import 'profile_session.dart';
import 'settings_page.dart';

enum HomeDestination { chats, contacts, settings }

class NewConversationIntent extends Intent {
  const NewConversationIntent();
}

class OpenSettingsIntent extends Intent {
  const OpenSettingsIntent();
}

class SearchChatsIntent extends Intent {
  const SearchChatsIntent();
}

class SearchConversationIntent extends Intent {
  const SearchConversationIntent();
}

/// The previous (-1) or next (1) conversation in the list.
class AdjacentConversationIntent extends Intent {
  const AdjacentConversationIntent(this.step);
  final int step;
}

/// Desktop shortcuts: ⌘ on Apple systems, Ctrl elsewhere. Escape comes
/// from the app's own dismiss shortcut.
Map<ShortcutActivator, Intent> homeShortcuts(TargetPlatform platform) {
  final apple =
      platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
  SingleActivator primary(LogicalKeyboardKey key) =>
      SingleActivator(key, meta: apple, control: !apple);
  return {
    primary(LogicalKeyboardKey.keyN): const NewConversationIntent(),
    primary(LogicalKeyboardKey.keyK): const SearchChatsIntent(),
    primary(LogicalKeyboardKey.keyF): const SearchConversationIntent(),
    primary(LogicalKeyboardKey.comma): const OpenSettingsIntent(),
    const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
        const AdjacentConversationIntent(-1),
    const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true):
        const AdjacentConversationIntent(1),
  };
}

/// The main navigation of a ready profile: chats, contacts and settings,
/// in a bottom bar on phones and a rail beside the panes on wide windows.
/// Enrollment never shows it.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.session,
    required this.kitFiles,
    required this.onClose,
    this.attachmentFiles = const AttachmentFiles(),
  });
  final ProfileSession session;
  final KitFiles kitFiles;
  final AttachmentFiles attachmentFiles;
  final VoidCallback onClose;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // The conversations page disposes the controller; it lives as long as
  // this shell, since switching destinations keeps it mounted.
  late final ConversationController _chat = ConversationController(
    widget.session.profile!,
    widget.session.setup!.bootstrap!,
  );
  final _chats = GlobalKey<ConversationsPageState>();

  /// Keeps the destinations' state when the window crosses a size class
  /// and the layout around them changes.
  final _pagesKey = GlobalKey();
  var _destination = HomeDestination.chats;
  final _visited = {HomeDestination.chats};

  void _go(HomeDestination destination) {
    if (destination == _destination) return;
    final from = _destination;
    setState(() {
      _destination = destination;
      _visited.add(destination);
    });
    // Names edited in contacts show up in the chat list.
    if (from == HomeDestination.contacts) unawaited(_chat.refresh());
  }

  /// Runs [action] on the chats page, bringing it on screen first.
  void _inChats(void Function(ConversationsPageState page) action) {
    if (_destination == HomeDestination.chats) {
      if (_chats.currentState case final page?) action(page);
      return;
    }
    // Switching destination schedules the frame that shows the page.
    _go(HomeDestination.chats);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chats.currentState case final page?) action(page);
    });
  }

  void _saveKit() =>
      Navigator.of(context).push(kitRoute(widget.session, widget.kitFiles));

  /// Why the administration device should save a kit now, or nothing:
  /// a title and what it means.
  (String, String)? _kitReminder(AppLocalizations l10n) {
    final setup = widget.session.setup;
    if (setup == null ||
        !setup.administrator ||
        widget.session.kitReminderDismissed) {
      return null;
    }
    if (setup.kitSavedAt == null) {
      return (l10n.kitReminderTitle, l10n.kitReminderNever);
    }
    if (setup.kitStale) {
      return (l10n.kitReminderStaleTitle, l10n.kitReminderStale);
    }
    return null;
  }

  List<Widget> _notices(BuildContext context) => [
    if (_kitReminder(context.l10n) case (final title, final body))
      StatusBanner(
        key: const Key('kit-reminder'),
        title: title,
        body: body,
        icon: Icons.key_outlined,
        actions: [
          FilledButton(onPressed: _saveKit, child: Text(context.l10n.kitSave)),
          TextButton(
            onPressed: () =>
                setState(() => widget.session.kitReminderDismissed = true),
            child: Text(context.l10n.later),
          ),
        ],
      ),
    if (widget.session.setup?.recoveryWarning ?? false)
      StatusBanner(
        title: context.l10n.recoveryWarningTitle,
        body: context.l10n.recoveryRollbackWarning,
        icon: Icons.gpp_maybe_outlined,
        tone: BannerTone.error,
      ),
  ];

  Widget _page(HomeDestination destination, WindowSize size) =>
      switch (destination) {
        HomeDestination.chats => ConversationsPage(
          key: _chats,
          controller: _chat,
          attachmentFiles: widget.attachmentFiles,
          twoPane: size.twoPane,
          active: _destination == HomeDestination.chats,
          notices: _notices(context),
        ),
        HomeDestination.contacts => ContactsPage(
          profile: widget.session.profile!,
        ),
        HomeDestination.settings => SettingsPage(
          session: widget.session,
          kitFiles: widget.kitFiles,
          onClose: widget.onClose,
        ),
      };

  /// Destinations stay mounted once visited, so a chat keeps syncing and
  /// its draft while contacts or settings are on screen.
  Widget _pages(WindowSize size) => IndexedStack(
    key: _pagesKey,
    index: _destination.index,
    children: [
      for (final destination in HomeDestination.values)
        if (_visited.contains(destination))
          ExcludeFocus(
            excluding: destination != _destination,
            child: TickerMode(
              enabled: destination == _destination,
              child: _page(destination, size),
            ),
          )
        else
          const SizedBox.shrink(),
    ],
  );

  List<(IconData, IconData, String)> _items(AppLocalizations l10n) => [
    (Icons.chat_bubble_outline, Icons.chat_bubble, l10n.navChats),
    (Icons.people_outline, Icons.people, l10n.navContacts),
    (Icons.settings_outlined, Icons.settings, l10n.navSettings),
  ];

  @override
  Widget build(BuildContext context) {
    final size = WindowSize.of(context);
    final items = _items(context.l10n);
    return Shortcuts(
      shortcuts: homeShortcuts(defaultTargetPlatform),
      child: Actions(
        actions: {
          NewConversationIntent: CallbackAction<NewConversationIntent>(
            onInvoke: (_) => _inChats((page) => page.newConversation()),
          ),
          SearchChatsIntent: CallbackAction<SearchChatsIntent>(
            onInvoke: (_) => _inChats((page) => page.focusSearch()),
          ),
          SearchConversationIntent: CallbackAction<SearchConversationIntent>(
            onInvoke: (_) => _inChats((page) => page.searchConversation()),
          ),
          OpenSettingsIntent: CallbackAction<OpenSettingsIntent>(
            onInvoke: (_) => _go(HomeDestination.settings),
          ),
          AdjacentConversationIntent:
              CallbackAction<AdjacentConversationIntent>(
                onInvoke: (intent) =>
                    _inChats((page) => page.selectAdjacent(intent.step)),
              ),
          DismissIntent: _CloseConversationAction(this),
        },
        // Focus that leaves a hidden destination lands here, still under
        // the shortcuts.
        child: FocusScope(
          autofocus: true,
          child: PopScope(
            canPop: _destination == HomeDestination.chats,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _go(HomeDestination.chats);
            },
            child: size.twoPane
                ? Scaffold(
                    body: Row(
                      children: [
                        FocusTraversalGroup(
                          child: SafeArea(
                            right: false,
                            child: NavigationRail(
                              key: const Key('navigation-rail'),
                              selectedIndex: _destination.index,
                              labelType: NavigationRailLabelType.all,
                              onDestinationSelected: (i) =>
                                  _go(HomeDestination.values[i]),
                              destinations: [
                                for (final (icon, selected, label) in items)
                                  NavigationRailDestination(
                                    icon: Icon(icon),
                                    selectedIcon: Icon(selected),
                                    label: Text(label),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: _pages(size)),
                      ],
                    ),
                  )
                : ListenableBuilder(
                    listenable: _chat,
                    builder: (context, _) => Scaffold(
                      body: _pages(size),
                      // An open conversation takes the whole phone screen.
                      bottomNavigationBar:
                          _destination == HomeDestination.chats &&
                              _chat.selected != null
                          ? null
                          : NavigationBar(
                              key: const Key('navigation-bar'),
                              selectedIndex: _destination.index,
                              onDestinationSelected: (i) =>
                                  _go(HomeDestination.values[i]),
                              destinations: [
                                for (final (icon, selected, label) in items)
                                  NavigationDestination(
                                    icon: Icon(icon),
                                    selectedIcon: Icon(selected),
                                    label: label,
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

/// Escape closes the open conversation; dialogs close themselves first.
class _CloseConversationAction extends Action<DismissIntent> {
  _CloseConversationAction(this.shell);
  final _HomeShellState shell;

  @override
  bool isEnabled(DismissIntent intent) =>
      shell._destination == HomeDestination.chats &&
      shell._chat.selected != null;

  @override
  Object? invoke(DismissIntent intent) =>
      shell._chats.currentState?.closeConversation();
}
