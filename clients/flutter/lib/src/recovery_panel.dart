import 'package:flutter/material.dart';

import 'kit_files.dart';
import 'export_secret.dart';
import 'profile_session.dart';

class RecoveryPanel extends StatefulWidget {
  const RecoveryPanel({
    super.key,
    required this.session,
    required this.files,
    this.export = false,
  });
  final ProfileSession session;
  final KitFiles files;
  final bool export;

  @override
  State<RecoveryPanel> createState() => _RecoveryPanelState();
}

class _RecoveryPanelState extends State<RecoveryPanel>
    with WidgetsBindingObserver {
  final _relay = TextEditingController();
  final _secretInput = TextEditingController();
  List<int>? _encrypted;
  final _exportedSecret = ExportSecret();
  bool _confirmed = false;
  bool _picking = false;
  bool _deferred = false;
  bool _saved = false;
  ProfileSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _relay.text = session.setup?.bootstrap ?? '';
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _secretInput.clear();
    }
    setState(() => _exportedSecret.lifecycle(state));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _relay.dispose();
    _secretInput.dispose();
    _exportedSecret.clear();
    _encrypted = null;
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _exportedSecret.clear();
      _saved = false;
    });
    final secret = await session.saveKit(widget.files.save);
    if (mounted && secret != null) {
      setState(() {
        _exportedSecret.saved(secret, WidgetsBinding.instance.lifecycleState);
        _deferred = false;
      });
    }
  }

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final bytes = await widget.files.open();
      if (mounted && bytes != null) setState(() => _encrypted = bytes);
    } catch (error) {
      session.reportFailure(error);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _restore() async {
    if (!_confirmed ||
        _encrypted == null ||
        _secretInput.text.trim().isEmpty ||
        !_relay.text.trim().startsWith('arveil-bootstrap:v0:')) {
      session.reportFailure(
        const ProfileAccessException(
          'Selecciona el kit, introduce su clave y los datos del relay, y confirma las consecuencias de la recuperación.',
        ),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    final secret = _secretInput.text.trim();
    final encrypted = _encrypted!;
    _secretInput.clear();
    setState(() {
      _encrypted = null;
      _confirmed = false;
    });
    await session.restoreKit(_relay.text.trim(), encrypted, secret);
  }

  @override
  Widget build(BuildContext context) =>
      widget.export ? _export(context) : _import(context);

  Widget _export(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Kit de recuperación',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      const Text(
        'El kit recupera tu identidad, no el historial ni el estado de los grupos. Guarda el archivo cifrado y su clave por separado; juntos permiten tomar el control de la identidad.',
      ),
      const SizedBox(height: 12),
      if (_exportedSecret.pending)
        OutlinedButton(
          onPressed: () => setState(
            () =>
                _exportedSecret.reveal(WidgetsBinding.instance.lifecycleState),
          ),
          child: const Text('Mostrar clave del kit guardado'),
        ),
      if (_exportedSecret.visible case final secret?) ...[
        const Text(
          'Archivo guardado. Guarda ahora esta clave por separado, por ejemplo en tu gestor de contraseñas. Arveil no la conserva.',
        ),
        const SizedBox(height: 12),
        SelectableText(secret, key: const Key('kit-export-secret')),
        const SizedBox(height: 12),
        const Text(
          'La clave desaparece al salir de esta pantalla o cambiar de aplicación. Si la pierdes, crea un kit nuevo.',
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => setState(() {
            _exportedSecret.clear();
            _saved = true;
          }),
          child: const Text('He guardado la clave por separado'),
        ),
      ] else ...[
        if (_saved)
          const Text(
            'Kit y clave guardados según tu confirmación. Exporta uno nuevo después de cambiar tus dispositivos.',
          ),
        if (_deferred)
          const Text(
            'Kit pospuesto: perder el dispositivo administrador sin un kit puede impedir recuperar tu identidad.',
            key: Key('kit-deferred-warning'),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: session.busy ? null : _save,
          icon: const Icon(Icons.save_alt),
          label: const Text('Guardar kit cifrado'),
        ),
        if (!_saved && !_deferred)
          TextButton(
            onPressed: session.busy
                ? null
                : () => setState(() => _deferred = true),
            child: const Text('Posponer el kit'),
          ),
      ],
    ],
  );

  Widget _import(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Recuperar mi identidad',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 16),
      const Text(
        'Usa el kit más reciente y su clave. Esta recuperación crea un dispositivo administrador nuevo y revoca los dispositivos anteriores incluidos en el manifiesto. El historial no se recupera; tendrás que incorporarte de nuevo a los grupos.',
      ),
      const SizedBox(height: 20),
      TextFormField(
        key: const Key('recovery-bootstrap'),
        controller: _relay,
        enabled: !session.busy && !_picking,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        minLines: 2,
        maxLines: 4,
        decoration: const InputDecoration(
          labelText: 'Datos del relay original',
        ),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: session.busy || _picking ? null : _pick,
        icon: const Icon(Icons.folder_open),
        label: Text(
          _encrypted == null
              ? 'Seleccionar kit cifrado'
              : 'Kit seleccionado: cambiar archivo',
        ),
      ),
      const SizedBox(height: 16),
      TextFormField(
        key: const Key('recovery-secret'),
        controller: _secretInput,
        enabled: !session.busy && !_picking,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        decoration: const InputDecoration(labelText: 'Clave del kit'),
      ),
      const SizedBox(height: 12),
      CheckboxListTile(
        key: const Key('recovery-confirm'),
        contentPadding: EdgeInsets.zero,
        value: _confirmed,
        onChanged: session.busy || _picking
            ? null
            : (value) => setState(() => _confirmed = value ?? false),
        title: const Text(
          'Entiendo que se revocarán los dispositivos anteriores y no se recuperará su historial.',
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: session.busy || _picking || !_confirmed ? null : _restore,
        child: const Text('Restaurar identidad y revocar dispositivos'),
      ),
    ],
  );
}

class RecoveryResumePanel extends StatelessWidget {
  const RecoveryResumePanel({super.key, required this.session});
  final ProfileSession session;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Continúa la recuperación',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 16),
      const Text(
        'La identidad y las claves del nuevo dispositivo están guardadas. El relay puede haber aceptado ya la revocación de los anteriores. Reanuda esta misma operación; no necesitas volver a abrir el kit ni crear otro perfil.',
      ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: session.busy ? null : session.resumeRecovery,
        child: const Text('Reanudar recuperación'),
      ),
    ],
  );
}
