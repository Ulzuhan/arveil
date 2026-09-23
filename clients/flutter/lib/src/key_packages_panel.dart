import 'package:flutter/material.dart';

import 'profile_session.dart';
import 'rust/api/profile.dart';

class KeyPackagesPanel extends StatelessWidget {
  const KeyPackagesPanel({super.key, required this.session});
  final ProfileSession session;

  @override
  Widget build(BuildContext context) {
    final supply = session.keyPackages;
    final level = supply?.level ?? KeyPackageLevelView.unknown;
    final pending = supply?.publicationPending ?? false;
    final canReplenish =
        pending ||
        level == KeyPackageLevelView.empty ||
        level == KeyPackageLevelView.low;
    final checked = supply?.checkedAt;
    final date = checked == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(checked.toInt() * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return Column(
      key: const Key('key-package-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Disponibilidad para nuevas conversaciones',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        const Text(
          'Este dispositivo publica claves de un solo uso (KeyPackages) para que otras personas puedan iniciar conversaciones con él. Las conversaciones existentes conservan sus propias claves.',
        ),
        const SizedBox(height: 12),
        Text(
          switch (level) {
            KeyPackageLevelView.unknown => 'Disponibilidad sin comprobar',
            KeyPackageLevelView.empty =>
              'Última consulta: sin claves disponibles',
            KeyPackageLevelView.low => 'Última consulta: quedan pocas claves',
            KeyPackageLevelView.ready => 'Última consulta: claves disponibles',
          },
          key: const Key('key-package-state'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (supply?.available case final count?) ...[
          const SizedBox(height: 8),
          Text(
            '$count claves disponibles según el relay.',
            key: const Key('key-package-count'),
          ),
        ],
        if (date != null) ...[
          const SizedBox(height: 8),
          Text(
            'Consultado el ${two(date.day)}/${two(date.month)}/${date.year} a las ${two(date.hour)}:${two(date.minute)}. Puede cambiar cuando otra persona use una clave.',
          ),
        ],
        if (level == KeyPackageLevelView.empty) ...[
          const SizedBox(height: 8),
          const Text(
            'Otros dispositivos no podrán iniciar nuevas conversaciones con este dispositivo hasta que haya claves disponibles.',
          ),
        ],
        if (level == KeyPackageLevelView.low) ...[
          const SizedBox(height: 8),
          const Text('Repón las claves antes de que se agoten.'),
        ],
        if (pending) ...[
          const SizedBox(height: 8),
          const Text(
            'Hay una publicación pendiente de confirmar. Reanudar enviará el mismo lote guardado; no regenerará esas claves.',
          ),
        ],
        if (session.keyPackagesUnavailable) ...[
          const SizedBox(height: 8),
          const Text(
            'No se pudo actualizar la disponibilidad. El último dato guardado no confirma el estado actual.',
            key: Key('key-package-unavailable'),
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: session.busy ? null : () => session.checkKeyPackages(),
          icon: const Icon(Icons.refresh),
          label: const Text('Comprobar disponibilidad'),
        ),
        if (canReplenish) ...[
          const SizedBox(height: 8),
          FilledButton(
            onPressed: session.busy
                ? null
                : () => session.checkKeyPackages(replenish: true),
            child: Text(
              pending ? 'Reanudar publicación de claves' : 'Reponer claves',
            ),
          ),
        ],
      ],
    );
  }
}
