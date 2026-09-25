import 'package:flutter/material.dart';

import 'rust/api/profile.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.profile,
    required this.bootstrap,
  });
  final Profile profile;
  final String bootstrap;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  DeviceInventoryView? _inventory;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  // Always reload the durable snapshot, including after a lost network reply.
  Future<void> _run([Future<void> Function()? action]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await action?.call();
    } catch (_) {
      error =
          'No se pudo completar la operación. Consulta el estado guardado y vuelve a sincronizar.';
    }
    try {
      final inventory = await widget.profile.devices();
      if (mounted) setState(() => _inventory = inventory);
    } catch (_) {
      error =
          'No se pudo leer el estado de los dispositivos. Vuelve a intentarlo.';
    }
    if (mounted) {
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  Future<void> _revoke(ManagedDeviceView device) async {
    if (_busy ||
        device.current ||
        device.revoked ||
        !(_inventory?.administrator ?? false)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Revocar este dispositivo?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Comprueba el identificador completo en el otro dispositivo antes de continuar.',
              ),
              const SizedBox(height: 12),
              SelectableText(device.deviceId),
              const SizedBox(height: 12),
              const Text(
                'La revocación es permanente. Se guardará aquí y se publicará al conectar. El relay bloqueará el dispositivo cuando acepte el cambio; las conversaciones también necesitan retirarlo de su grupo. No borra las copias ni el historial que ya tenga.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('confirm-device-revocation'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revocar definitivamente'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      () => widget.profile.revokeDevice(
        bootstrap: widget.bootstrap,
        deviceId: device.deviceId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inventory = _inventory;
    return Scaffold(
      appBar: AppBar(title: const Text('Dispositivos')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_busy) const LinearProgressIndicator(),
            const Text(
              'Estado conocido por este perfil. Estar autorizado no indica que un dispositivo esté conectado.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('sync-devices'),
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await widget.profile.sync_(bootstrap: widget.bootstrap);
                    }),
              icon: const Icon(Icons.sync),
              label: const Text('Sincronizar dispositivos'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, key: const Key('devices-error')),
              TextButton(
                onPressed: _busy ? null : () => _run(),
                child: const Text('Volver a leer el estado local'),
              ),
            ],
            if (inventory != null) ...[
              const SizedBox(height: 12),
              Text(
                inventory.administrator
                    ? 'Este perfil puede administrar sus dispositivos.'
                    : 'Este dispositivo está vinculado. Revoca dispositivos desde el perfil administrador.',
              ),
              const SizedBox(height: 8),
              Text(
                'Versión local del manifiesto: ${inventory.manifestSequence}',
              ),
              if (inventory.unknownActive + inventory.unknownRevoked > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Inventario parcial: el manifiesto incluye ${inventory.unknownActive} credenciales autorizadas y ${inventory.unknownRevoked} revocadas cuyos identificadores de dispositivo no conoce este perfil. Consulta el administrador para gestionarlas.',
                    key: const Key('partial-device-inventory'),
                  ),
                ),
              for (final device
                  in [...inventory.devices]..sort(
                    (a, b) => a.current == b.current
                        ? a.deviceId.compareTo(b.deviceId)
                        : a.current
                        ? -1
                        : 1,
                  ))
                Card(
                  key: Key('device-${device.deviceId}'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          device.current
                              ? 'Este dispositivo'
                              : 'Dispositivo vinculado',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        SelectableText(device.deviceId),
                        const SizedBox(height: 8),
                        Text(
                          device.revoked
                              ? 'Revocado según el estado local'
                              : 'No consta revocado en este perfil',
                        ),
                        if (device.revocation case final progress?) ...[
                          const SizedBox(height: 8),
                          Text(
                            progress.relayPublished
                                ? 'Revocación aceptada por el relay'
                                : 'Pendiente de publicar la revocación en el relay',
                          ),
                          Text(
                            'Conversaciones locales pendientes de retirarlo: ${progress.groupsWaiting}',
                          ),
                          if (progress.groupsWaiting > 0)
                            const Text(
                              'Sincroniza para recibir los cambios. La retirada corresponde al dispositivo que coordina los cambios del grupo; mientras tanto, el envío permanece bloqueado en quienes conocen la revocación.',
                            ),
                          Text(
                            'Avisos pendientes de publicar: ${progress.notificationsPending}',
                          ),
                          if (progress.notificationsUnconfirmed > 0)
                            Text(
                              'Avisos rechazados o caducados sin confirmación: ${progress.notificationsUnconfirmed}. Comprueba el estado con los otros participantes.',
                            ),
                          if (progress.withoutRoute > 0)
                            Text(
                              'Avisos que no pudieron prepararse por falta de ruta: ${progress.withoutRoute}. Requieren revisar las rutas; no se reenvían automáticamente.',
                            ),
                          const Text(
                            'La aceptación del relay no confirma que los demás dispositivos hayan recibido el aviso.',
                          ),
                        ],
                        if (inventory.administrator &&
                            !device.current &&
                            !device.revoked) ...[
                          const SizedBox(height: 12),
                          OutlinedButton(
                            key: Key('revoke-${device.deviceId}'),
                            onPressed: _busy ? null : () => _revoke(device),
                            child: const Text('Revocar dispositivo'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
