import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../design/design.dart';
import 'controller.dart';

class UpdateScope extends InheritedNotifier<UpdateController> {
  const UpdateScope({
    super.key,
    required UpdateController controller,
    required super.child,
  }) : super(notifier: controller);
  static UpdateController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>()?.notifier;
}

void openUpdates(BuildContext context, UpdateController controller) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UpdatesPage(controller: controller),
      ),
    );

/// Only foreground checks: no push token, background job or notification service.
class UpdateLifecycle extends StatefulWidget {
  const UpdateLifecycle({
    super.key,
    required this.controller,
    required this.navigator,
    required this.child,
  });
  final UpdateController controller;
  final GlobalKey<NavigatorState> navigator;
  final Widget child;
  @override
  State<UpdateLifecycle> createState() => _UpdateLifecycleState();
}

class _UpdateLifecycleState extends State<UpdateLifecycle>
    with WidgetsBindingObserver {
  bool _showing = false;
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
    listenable: widget.controller,
    builder: (context, _) => Column(
      children: [
        if (widget.controller.available && !_showing)
          Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.system_update_outlined),
                    const SizedBox(width: 12),
                    Expanded(child: Text(context.l10n.updatesAvailable)),
                    TextButton(
                      onPressed: () async {
                        setState(() => _showing = true);
                        await widget.navigator.currentState?.push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                UpdatesPage(controller: widget.controller),
                          ),
                        );
                        if (mounted) setState(() => _showing = false);
                      },
                      child: Text(context.l10n.updatesView),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(child: widget.child),
      ],
    ),
  );
}

class UpdatesPage extends StatelessWidget {
  const UpdatesPage({super.key, required this.controller});
  final UpdateController controller;

  String _error(AppLocalizations l10n, String code) => switch (code) {
    'signature' || 'manifest' => l10n.updatesErrorSignature,
    'expired' => l10n.updatesErrorExpired,
    'rollback' => l10n.updatesErrorRollback,
    'state' => l10n.updatesErrorState,
    'package' => l10n.updatesErrorPackage,
    'permission' => l10n.updatesPermission,
    'cancelled' => l10n.updatesCancelled,
    'install' => l10n.updatesErrorInstall,
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
                      const SizedBox(height: 16),
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
