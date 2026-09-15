import 'package:flutter/material.dart';

import 'src/profile_session.dart';
import 'src/rust/api/profile.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ArveilRust.init();
  runApp(const ArveilApp());
}

class ArveilApp extends StatelessWidget {
  const ArveilApp({super.key, this.session});
  final ProfileSession? session;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Arveil',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff245b51)),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: ProfilePage(session: session),
  );
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, this.session});
  final ProfileSession? session;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final ProfileSession _session = widget.session ?? ProfileSession();
  final _form = GlobalKey<FormState>();
  final _bootstrap = TextEditingController();
  final _invite = TextEditingController();

  @override
  void dispose() {
    _bootstrap.dispose();
    _invite.dispose();
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    await _session.open();
    if (!mounted) return;
    _bootstrap.text = _session.setup?.bootstrap ?? '';
  }

  Future<void> _enroll() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    final success = await _session.enroll(
      _bootstrap.text.trim(),
      _invite.text.trim(),
    );
    if (!mounted) return;
    if (success || _session.setup?.stage == SetupStage.ready) _invite.clear();
  }

  Future<void> _close() async {
    _invite.clear();
    if (await _session.close() && mounted) _bootstrap.clear();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Arveil'),
        actions: [
          if (_session.isOpen)
            TextButton.icon(
              onPressed: _session.busy ? null : _close,
              icon: const Icon(Icons.lock_outline),
              label: const Text('Cerrar perfil'),
            ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (!_session.isOpen)
                  ..._welcome(context)
                else if (_session.setup == null) ...[
                  const Text('No se pudo leer el estado del perfil.'),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _session.busy ? null : _session.refresh,
                    child: const Text('Volver a leer'),
                  ),
                ] else if (_session.setup!.stage == SetupStage.ready)
                  ..._ready(context)
                else if (_session.setup!.stage == SetupStage.linkedDevice) ...[
                  Text(
                    'Dispositivo vinculado',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Este perfil usa el flujo de vinculación de dispositivos. '
                    'Su gestión desde la interfaz estará disponible en una próxima versión.',
                  ),
                ] else
                  ..._onboarding(context),
                if (_session.busy) ...[
                  const SizedBox(height: 24),
                  const LinearProgressIndicator(
                    semanticsLabel: 'Operación en curso',
                  ),
                  const SizedBox(height: 12),
                  const Text('Guardando el avance. Espera un momento…'),
                ],
                if (_session.error case final message?) ...[
                  const SizedBox(height: 24),
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      key: const Key('error'),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(message),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );

  List<Widget> _welcome(BuildContext context) => [
    const SizedBox(height: 36),
    const Align(
      alignment: Alignment.centerLeft,
      child: Icon(Icons.shield_outlined, size: 44),
    ),
    const SizedBox(height: 24),
    Text(
      'Tu identidad, en este dispositivo',
      style: Theme.of(context).textTheme.headlineLarge,
    ),
    const SizedBox(height: 16),
    const Text(
      'Abre tu perfil o prepara uno nuevo para unirte con una invitación.',
    ),
    const SizedBox(height: 16),
    const Text(
      'El perfil se cifra con una clave guardada en el almacén seguro del dispositivo. '
      'Si pierdes esa clave, no podrás recuperar el historial local.',
    ),
    const SizedBox(height: 28),
    FilledButton.icon(
      onPressed: _session.busy ? null : _open,
      icon: const Icon(Icons.arrow_forward),
      label: const Text('Abrir perfil'),
    ),
  ];

  List<Widget> _onboarding(BuildContext context) {
    final state = _session.setup!;
    final retry =
        state.stage != SetupStage.new_ &&
        state.stage != SetupStage.identityReady;
    return [
      Text(
        retry ? 'Retoma tu alta' : 'Únete a tu espacio',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 16),
      Text(
        retry
            ? 'Tu avance está guardado. Usa la misma invitación para continuar con tu identidad.'
            : 'Pide al administrador los datos del relay y una invitación. '
                  'Tu identidad se crea en este dispositivo al continuar.',
      ),
      const SizedBox(height: 20),
      Text(switch (state.stage) {
        SetupStage.redeeming => 'Pendiente de confirmar la invitación.',
        SetupStage.redeemed =>
          'Invitación aceptada. Falta recibir la configuración.',
        SetupStage.publishing =>
          'Configuración recibida. Falta terminar el buzón y las claves de mensajería.',
        SetupStage.identityReady => 'Tu identidad local ya está creada.',
        _ => 'Listo para crear tu identidad.',
      }, key: const Key('setup-status')),
      const SizedBox(height: 24),
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('bootstrap'),
              controller: _bootstrap,
              enabled: !_session.busy,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Datos del relay',
                hintText: 'arveil-bootstrap:v0:…',
              ),
              validator: (value) =>
                  (value ?? '').trim().startsWith('arveil-bootstrap:v0:')
                  ? null
                  : 'Pega los datos completos del relay.',
            ),
            const SizedBox(height: 20),
            TextFormField(
              key: const Key('invite'),
              controller: _invite,
              enabled: !_session.busy,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Invitación',
                helperText: 'No se guarda. Consérvala hasta completar el alta.',
              ),
              validator: (value) =>
                  RegExp(r'^[0-9a-fA-F]{64}$').hasMatch((value ?? '').trim())
                  ? null
                  : 'La invitación debe contener 64 caracteres hexadecimales.',
              onFieldSubmitted: (_) {
                if (!_session.busy) _enroll();
              },
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _session.busy ? null : _enroll,
              icon: const Icon(Icons.arrow_forward),
              label: Text(
                retry ? 'Reintentar alta' : 'Crear identidad y unirme',
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _ready(BuildContext context) => [
    const Icon(Icons.check_circle_outline, size: 48),
    const SizedBox(height: 20),
    Text(
      'Tu perfil está listo',
      style: Theme.of(context).textTheme.headlineLarge,
    ),
    const SizedBox(height: 16),
    const Text(
      'Identidad registrada, buzón preparado y claves de mensajería publicadas.',
    ),
    const SizedBox(height: 24),
    const Text(
      'Conversaciones',
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 12),
    const Text(
      'La creación y lectura de conversaciones desde la interfaz es el siguiente paso.',
    ),
    const SizedBox(height: 12),
    if (_session.conversations case final conversations?)
      Text('${conversations.length} conversaciones en este perfil.'),
    const SizedBox(height: 16),
    OutlinedButton.icon(
      onPressed: _session.busy ? null : _session.refresh,
      icon: const Icon(Icons.refresh),
      label: const Text('Consultar conversaciones'),
    ),
  ];
}
