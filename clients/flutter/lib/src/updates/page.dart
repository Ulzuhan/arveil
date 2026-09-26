import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/l10n.dart';
import '../design/design.dart';
import 'controller.dart';

/// Hands the controller down without rebuilding on its changes: those come
/// once per percentage point of a download, and only the parts that show
/// its state listen to it.
class UpdateScope extends InheritedWidget {
  const UpdateScope({
    super.key,
    required this.controller,
    required super.child,
  });
  final UpdateController controller;
  static UpdateController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>()?.controller;

  @override
  bool updateShouldNotify(UpdateScope oldWidget) =>
      controller != oldWidget.controller;
}

const _updatesRoute = 'updates';

Future<void> openUpdates(BuildContext context, UpdateController controller) =>
    Navigator.of(context).push(_updatesPage(controller));

MaterialPageRoute<void> _updatesPage(UpdateController controller) =>
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: _updatesRoute),
      builder: (_) => UpdatesPage(controller: controller),
    );

/// Follows the app navigator's top route for the update banner, which sits
/// above the navigator: the banner hides under the updates page and is
/// covered like the page below when a dialog or sheet is open.
class UpdateRoutes extends NavigatorObserver {
  final top = ValueNotifier<Route<dynamic>?>(null);

  // Navigator reports while it builds; the banner above it updates after.
  void _set(Route<dynamic>? route) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => top.value = route);
    } else {
      top.value = route;
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(previousRoute);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(top.value, route)) _set(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(top.value, oldRoute)) _set(newRoute);
  }
}

/// Only foreground checks: no push token, background job or notification service.
class UpdateLifecycle extends StatefulWidget {
  const UpdateLifecycle({
    super.key,
    required this.controller,
    required this.navigator,
    required this.routes,
    required this.child,
  });
  final UpdateController controller;
  final GlobalKey<NavigatorState> navigator;
  final UpdateRoutes routes;
  final Widget child;
  @override
  State<UpdateLifecycle> createState() => _UpdateLifecycleState();
}

class _UpdateLifecycleState extends State<UpdateLifecycle>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.checkAutomatically());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.controller.refreshPermission());
      unawaited(widget.controller.checkAutomatically());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, widget.routes.top]),
    builder: (context, _) {
      final top = widget.routes.top.value;
      final shown =
          widget.controller.available && top?.settings.name != _updatesRoute;
      return Column(
        children: [
          if (shown) _banner(context, top is PopupRoute ? top : null),
          Expanded(
            // The banner took the status bar's inset; the pages below must
            // not add it again.
            child: MediaQuery.removePadding(
              context: context,
              removeTop: shown,
              child: widget.child,
            ),
          ),
        ],
      );
    },
  );

  Widget _banner(BuildContext context, PopupRoute<dynamic>? popup) {
    final banner = Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.system_update_outlined),
              const SizedBox(width: 12),
              Expanded(child: Text(context.l10n.updatesAvailable)),
              TextButton(
                onPressed: () => widget.navigator.currentState?.push(
                  _updatesPage(widget.controller),
                ),
                child: Text(context.l10n.updatesView),
              ),
            ],
          ),
        ),
      ),
    );
    if (popup == null) return banner;
    // A dialog's barrier covers only the navigator; this one extends it over
    // the banner, so it can be neither tapped nor read behind the dialog.
    return Stack(
      children: [
        ExcludeSemantics(child: banner),
        Positioned.fill(
          child: ModalBarrier(
            color: popup.barrierColor,
            dismissible: popup.barrierDismissible,
            barrierSemanticsDismissible: false,
            onDismiss: () => widget.navigator.currentState?.maybePop(),
          ),
        ),
      ],
    );
  }
}

class UpdatesPage extends StatelessWidget {
  const UpdatesPage({super.key, required this.controller});
  final UpdateController controller;

  String _error(AppLocalizations l10n, String code) => switch (code) {
    'signature' => l10n.updatesErrorSignature,
    'format' => l10n.updatesErrorFormat,
    'channel' => l10n.updatesErrorChannel,
    'expired' => l10n.updatesErrorExpired,
    'rollback' => l10n.updatesErrorRollback,
    'state' => l10n.updatesErrorState,
    'package' => l10n.updatesErrorPackage,
    'storage' => l10n.updatesErrorStorage,
    'permission' => l10n.updatesPermission,
    'cancelled' => l10n.updatesCancelled,
    'install' => l10n.updatesErrorInstall,
    'browser' => l10n.updatesErrorBrowser,
    _ => l10n.updatesErrorNetwork,
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.updatesTitle)),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final l10n = context.l10n;
          final update = controller.manifest?.android;
          final downloading = controller.phase == UpdatePhase.downloading;
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(l10n.updatesExplanation),
                  const SizedBox(height: 16),
                  if (!controller.configured)
                    Text(l10n.updatesUnconfigured)
                  else ...[
                    Text(l10n.updatesPrivacy),
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      key: const Key('updates-automatic'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.updatesAutomatic),
                      subtitle: Text(l10n.updatesAutomaticDetail),
                      value: controller.automatic,
                      onChanged: controller.busy
                          ? null
                          : controller.setAutomatic,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const Key('updates-check'),
                      onPressed: controller.busy ? null : controller.check,
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.updatesCheck),
                    ),
                    if (controller.phase == UpdatePhase.checking) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                        semanticsLabel: l10n.updatesChecking,
                      ),
                      const SizedBox(height: 8),
                      Text(l10n.updatesChecking),
                    ],
                    if (controller.phase == UpdatePhase.current) ...[
                      const SizedBox(height: 16),
                      Text(l10n.updatesCurrent),
                    ],
                    if (controller.phase == UpdatePhase.incompatible) ...[
                      const SizedBox(height: 16),
                      Text(l10n.updatesIncompatible),
                    ],
                    if (controller.available && update != null) ...[
                      const SizedBox(height: 24),
                      Text(
                        l10n.updatesVersion(
                          '${update.version}+${update.build}',
                        ),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.updatesSize(
                          (update.size / (1024 * 1024)).toStringAsFixed(1),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(update.notes),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          key: const Key('updates-notes'),
                          onPressed: controller.openNotes,
                          icon: const Icon(Icons.open_in_new),
                          label: Text(
                            l10n.updatesNotesLink(update.notesUrl.host),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (downloading) ...[
                        LinearProgressIndicator(
                          value: controller.received / update.size,
                          semanticsLabel: l10n.updatesDownloading,
                        ),
                        const SizedBox(height: 8),
                        Text(l10n.updatesDownloading),
                        TextButton(
                          onPressed: controller.cancelDownload,
                          child: Text(l10n.updatesCancelDownload),
                        ),
                      ] else if (controller.phase == UpdatePhase.ready) ...[
                        Text(l10n.updatesReady),
                        const SizedBox(height: 12),
                        if (controller.needsPermission) ...[
                          Text(l10n.updatesPermission),
                          OutlinedButton(
                            onPressed: controller.busy
                                ? null
                                : controller.permission,
                            child: Text(l10n.updatesAllowInstall),
                          ),
                          const SizedBox(height: 12),
                        ],
                        FilledButton.icon(
                          key: const Key('updates-install'),
                          onPressed: controller.busy
                              ? null
                              : controller.install,
                          icon: const Icon(Icons.system_update_outlined),
                          label: Text(l10n.updatesInstall),
                        ),
                      ] else if (controller.phase == UpdatePhase.installing)
                        Text(l10n.updatesInstalling)
                      else
                        FilledButton.icon(
                          key: const Key('updates-download'),
                          onPressed: controller.busy
                              ? null
                              : controller.download,
                          icon: const Icon(Icons.download_outlined),
                          label: Text(l10n.updatesDownload),
                        ),
                    ],
                  ],
                  if (controller.error case final code?) ...[
                    const SizedBox(height: 24),
                    StatusBanner(
                      title: _error(l10n, code),
                      icon: Icons.error_outline,
                      tone: BannerTone.error,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}
