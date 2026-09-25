import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'rust/api/profile.dart';

String attachmentSize(BigInt size) {
  final bytes = size.toDouble();
  if (bytes < 1024) return '$size B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

class AttachmentCard extends StatelessWidget {
  const AttachmentCard({
    super.key,
    required this.event,
    required this.active,
    required this.resume,
    required this.cancel,
    required this.export,
  });
  final HistoryEventView event;
  final bool active;
  final VoidCallback resume, cancel, export;

  @override
  Widget build(BuildContext context) {
    final file = event.attachment!;
    final state = file.state;
    final ready =
        state == AttachmentStateView.ready || state == AttachmentStateView.sent;
    final retry =
        !active &&
        (state == AttachmentStateView.pending ||
            state == AttachmentStateView.transferring ||
            state == AttachmentStateView.unavailable ||
            (!file.outgoing && state == AttachmentStateView.cancelled));
    final cancellable =
        state == AttachmentStateView.pending ||
        state == AttachmentStateView.transferring;
    final status = switch (state) {
      AttachmentStateView.pending =>
        file.outgoing
            ? context.l10n.attachmentSavedPending
            : file.transferred > BigInt.zero
            ? context.l10n.attachmentDownloadInterrupted
            : context.l10n.attachmentDownloadAwaiting,
      AttachmentStateView.transferring =>
        active
            ? context.l10n.attachmentTransferring
            : context.l10n.attachmentTransferInterrupted,
      AttachmentStateView.ready => context.l10n.attachmentDownloaded,
      AttachmentStateView.sent =>
        event.delivery.isEmpty
            ? context.l10n.deliveryNoRecipients
            : event.delivery.every((s) => s.startsWith('accepted'))
            ? context.l10n.deliveryAccepted
            : event.delivery.any((s) => s.startsWith('undeliverable'))
            ? context.l10n.deliveryRejected
            : event.delivery.any((s) => s == 'expired/unknown')
            ? context.l10n.deliveryExpired
            : context.l10n.attachmentReady,
      AttachmentStateView.cancelled => context.l10n.attachmentCancelled,
      AttachmentStateView.unavailable => context.l10n.attachmentUnavailable,
      AttachmentStateView.expired => context.l10n.attachmentExpiredOnRelay,
      AttachmentStateView.invalid => context.l10n.attachmentUnverified,
      AttachmentStateView.legacy => context.l10n.attachmentLegacy,
    };
    return Align(
      alignment: file.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: Key('attachment-${event.eventId}'),
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: file.outgoing
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.insert_drive_file_outlined),
            Text(
              file.name,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(attachmentSize(file.size)),
            const SizedBox(height: 8),
            Text(status),
            if (active || (file.transferred > BigInt.zero && !ready)) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: file.total > BigInt.zero
                    ? (file.transferred.toDouble() / file.total.toDouble())
                          .clamp(0.0, 1.0)
                    : null,
              ),
              Text(
                '${attachmentSize(file.transferred)} / ${attachmentSize(file.total)}',
              ),
            ],
            Wrap(
              spacing: 8,
              children: [
                if (retry)
                  TextButton(
                    key: Key('resume-${event.eventId}'),
                    onPressed: resume,
                    child: Text(
                      file.outgoing
                          ? context.l10n.attachmentSendResume
                          : file.transferred > BigInt.zero
                          ? context.l10n.attachmentResumeDownload
                          : context.l10n.attachmentDownload,
                    ),
                  ),
                if (cancellable)
                  TextButton(
                    key: Key('cancel-${event.eventId}'),
                    onPressed: cancel,
                    child: Text(context.l10n.attachmentCancel),
                  ),
                if (ready)
                  TextButton(
                    key: Key('export-${event.eventId}'),
                    onPressed: export,
                    child: Text(context.l10n.attachmentSaveCopy),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
