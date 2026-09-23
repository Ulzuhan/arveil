import 'dart:async';

import 'package:flutter/material.dart';

import 'profile_session.dart';

class PairingPanel extends StatefulWidget {
  const PairingPanel({
    super.key,
    required this.session,
    this.administration = false,
  });
  final ProfileSession session;
  final bool administration;

  @override
  State<PairingPanel> createState() => _PairingPanelState();
}

class _PairingPanelState extends State<PairingPanel> {
  final _form = GlobalKey<FormState>();
  final _relay = TextEditingController();
  final _code = TextEditingController();
  final _comparison = TextEditingController();
  Timer? _clock;
  ProfileSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _relay.text = session.setup?.bootstrap ?? '';
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && session.setup?.pairing != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _relay.dispose();
    _code.dispose();
    _comparison.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    if (await session.beginPairing(_relay.text.trim()) && mounted) {
      unawaited(session.waitForPairing());
    }
  }

  Future<void> _approve() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    if (await session.approvePairing(_code.text.trim()) && mounted) {
      _code.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.administration) return _administration(context);
    final pairing = session.setup?.pairing;
    final remaining = pairing == null
        ? 0
        : pairing.expiresAt.toInt() -
              DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expired =
        pairing != null &&
        !pairing.committing &&
        (pairing.expired || remaining <= 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Vincular este dispositivo',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 16),
        const Text(
          'Usa tu dispositivo administrador para autorizar este perfil. La vinculación conserva tu identidad; no copia el historial anterior.',
        ),
        const SizedBox(height: 20),
        if (pairing == null)
          Form(
            key: _form,
            child: Column(
              children: [
                TextFormField(
                  key: const Key('pair-bootstrap'),
                  controller: _relay,
                  enabled: !session.busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Datos del relay',
                  ),
                  validator: (text) =>
                      (text ?? '').trim().startsWith('arveil-bootstrap:v0:')
                      ? null
                      : 'Pega los datos completos del relay.',
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: session.busy ? null : _begin,
                  child: const Text('Generar código de vinculación'),
                ),
              ],
            ),
          )
        else ...[
          if (pairing.committing) ...[
            const Text(
              'La confirmación está guardada. Falta terminar la configuración en el relay.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: session.busy
                  ? null
                  : () => session.confirmPairing(pairing.verificationCode!),
              child: const Text('Reanudar finalización'),
            ),
          ] else if (expired) ...[
            const Text(
              'Esta sesión ha caducado. Cancélala y genera un código nuevo.',
            ),
          ] else if (pairing.verificationCode case final verification?) ...[
            Text(
              'Código de comparación',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            SelectableText(
              verification,
              key: const Key('pair-verification'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            const Text(
              'Comprueba ambas pantallas. Introduce aquí el código que muestra el dispositivo administrador. Si son distintos, cancela.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('pair-comparison'),
              controller: _comparison,
              enabled: !session.busy,
              keyboardType: TextInputType.number,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: const InputDecoration(
                labelText: 'Código del otro dispositivo',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: session.busy
                  ? null
                  : () async {
                      FocusScope.of(context).unfocus();
                      await session.confirmPairing(_comparison.text.trim());
                      if (mounted) _comparison.clear();
                    },
              child: const Text('Confirmar comparación'),
            ),
          ] else ...[
            const Text(
              'En el administrador, abre «Vincular otro dispositivo» y pega este código por un canal privado.',
            ),
            const SizedBox(height: 12),
            SelectableText(pairing.code, key: const Key('pair-code')),
            const SizedBox(height: 12),
            Text('Caduca en ${remaining > 0 ? remaining : 0} segundos.'),
            const SizedBox(height: 12),
            Text(
              session.waitingForPairing
                  ? 'Esperando al dispositivo administrador…'
                  : 'La espera se interrumpió. Cancela esta sesión y genera otro código; la comparación ya recibida se conserva al reabrir.',
            ),
          ],
          if (!pairing.committing) ...[
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed:
                  session.cancellingPairing ||
                      (session.busy && !session.waitingForPairing)
                  ? null
                  : () async {
                      await session.cancelPairing();
                      if (mounted) _comparison.clear();
                    },
              child: const Text('Cancelar vinculación'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Cancelar detiene este alta local. Si el administrador ya emitió una autorización, no la revoca.',
            ),
          ],
        ],
      ],
    );
  }

  Widget _administration(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Vincular otro dispositivo',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      if (session.approvalCode case final verification?) ...[
        const Text(
          'Compara este código con el del nuevo dispositivo e introdúcelo allí para terminar.',
        ),
        const SizedBox(height: 12),
        SelectableText(
          verification,
          key: const Key('approval-verification'),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        const Text(
          'Ya se ha emitido la autorización. Cerrar esta comparación no la revoca. Si no reconoces la solicitud, revoca ese dispositivo desde la CLI.',
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: session.dismissApproval,
          child: const Text('Cerrar comparación'),
        ),
      ] else
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Pega únicamente el código de un dispositivo tuyo que tengas delante. Este paso emite su autorización.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('pair-approval-code'),
                controller: _code,
                enabled: !session.busy,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Código de vinculación',
                ),
                validator: (text) =>
                    (text ?? '').trim().startsWith('arveil-pair:')
                    ? null
                    : 'Pega el código de vinculación completo.',
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: session.busy ? null : _approve,
                child: const Text('Autorizar y comparar'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Mantén ambos dispositivos abiertos durante la espera, de hasta 90 segundos.',
              ),
            ],
          ),
        ),
    ],
  );
}
