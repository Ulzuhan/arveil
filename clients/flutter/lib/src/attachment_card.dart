import 'package:flutter/material.dart';
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
            ? 'Guardado en este dispositivo · pendiente de envío'
            : file.transferred > BigInt.zero
            ? 'Descarga interrumpida'
            : 'Descarga pendiente de tu autorización',
      AttachmentStateView.transferring =>
        active
            ? 'Transfiriendo…'
            : 'Transferencia interrumpida · puedes reanudar',
      AttachmentStateView.ready =>
        'Descargado y verificado · copia privada cifrada',
      AttachmentStateView.sent =>
        event.delivery.isEmpty
            ? 'Guardado localmente · sin destinatarios disponibles'
            : event.delivery.every((s) => s.startsWith('accepted'))
            ? 'Aceptado por el relay · lectura sin confirmar'
            : event.delivery.any((s) => s.startsWith('undeliverable'))
            ? 'Algún buzón rechazó el mensaje'
            : event.delivery.any((s) => s == 'expired/unknown')
            ? 'Entrega caducada o desconocida'
            : 'Archivo preparado · envío pendiente de sincronización',
      AttachmentStateView.cancelled =>
        'Transferencia cancelada · copia incompleta eliminada',
      AttachmentStateView.unavailable =>
        'Archivo no disponible o acceso rechazado. Puedes reintentar o pedir otra copia.',
      AttachmentStateView.expired =>
        'Archivo caducado en el relay. Pide que lo envíen de nuevo.',
      AttachmentStateView.invalid =>
        'No se pudo verificar el archivo. No se permite guardarlo fuera de Arveil.',
      AttachmentStateView.legacy =>
        'Adjunto de una versión anterior; no está disponible en esta pantalla.',
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
                          ? 'Enviar / reanudar'
                          : file.transferred > BigInt.zero
                          ? 'Reanudar descarga'
                          : 'Descargar',
                    ),
                  ),
                if (cancellable)
                  TextButton(
                    key: Key('cancel-${event.eventId}'),
                    onPressed: cancel,
                    child: const Text('Cancelar transferencia'),
                  ),
                if (ready)
                  TextButton(
                    key: Key('export-${event.eventId}'),
                    onPressed: export,
                    child: const Text('Guardar copia…'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
