import 'package:flutter/material.dart';

import 'rust/api/profile.dart';

String contactId(String id) => id.length <= 12 ? id : id.substring(0, 12);

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.profile,
    this.selectRecipients = false,
  });
  final Profile profile;
  final bool selectRecipients;
  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  List<ContactView> _contacts = [];
  final Set<String> _selected = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool _available(ContactView c) =>
      c.verified && c.devices.any((d) => !d.revoked);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final contacts = await widget.profile.contacts();
      contacts.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _selected.removeWhere(
          (id) => !contacts.any((c) => c.identityId == id && _available(c)),
        );
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'No se pudieron leer los contactos. Vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit([ContactView? contact]) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            ContactEditorPage(profile: widget.profile, contact: contact),
      ),
    );
    if (mounted) await _load();
  }

  List<SavedRecipientView> get _recipients => [
    for (final c in _contacts)
      if (_selected.contains(c.identityId) && _available(c))
        for (final device in c.devices)
          if (!device.revoked)
            SavedRecipientView(
              identityId: c.identityId,
              deviceId: device.deviceId,
            ),
  ];

  @override
  Widget build(BuildContext context) {
    final recipients = _recipients;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.selectRecipients ? 'Elegir contactos' : 'Contactos'),
        actions: [
          IconButton(
            tooltip: 'Añadir contacto',
            onPressed: _loading ? null : () => _edit(),
            icon: const Icon(Icons.person_add_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(_error!),
                    TextButton(
                      onPressed: _load,
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Los nombres son locales. Comprueba la identidad comparando el número de seguridad por otro canal.',
                  ),
                  if (widget.selectRecipients)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Se incluirán los dispositivos guardados que no consten como revocados. Máximo: 16 dispositivos.',
                      ),
                    ),
                  if (!_loading && _error == null && _contacts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Column(
                        children: [
                          const Text('Todavía no tienes contactos guardados.'),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: () => _edit(),
                            child: const Text('Añadir contacto'),
                          ),
                        ],
                      ),
                    ),
                  for (final c in _contacts)
                    Card(
                      child: ListTile(
                        key: Key('contact-${c.identityId}'),
                        leading: widget.selectRecipients
                            ? Checkbox(
                                key: Key('select-contact-${c.identityId}'),
                                value: _selected.contains(c.identityId),
                                onChanged: _available(c) && !_loading
                                    ? (value) => setState(() {
                                        if (value == true) {
                                          _selected.add(c.identityId);
                                        } else {
                                          _selected.remove(c.identityId);
                                        }
                                      })
                                    : null,
                              )
                            : Icon(
                                c.verified
                                    ? Icons.verified_user_outlined
                                    : Icons.person_outline,
                              ),
                        title: Text(c.label),
                        subtitle: Text(
                          '${contactId(c.identityId)} · ${c.verified ? "Verificado" : "Sin verificar"}\n${c.devices.isEmpty ? "Añade una ruta para conversar" : "${c.devices.where((d) => !d.revoked).length} dispositivos disponibles"}',
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _loading ? null : () => _edit(c),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.selectRecipients)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    if (recipients.length > 16)
                      const Text('Selecciona como máximo 16 dispositivos.'),
                    FilledButton(
                      key: const Key('use-contacts'),
                      onPressed:
                          _loading ||
                              _error != null ||
                              recipients.isEmpty ||
                              recipients.length > 16
                          ? null
                          : () => Navigator.pop(context, recipients),
                      child: Text('Usar contactos (${_selected.length})'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ContactEditorPage extends StatefulWidget {
  const ContactEditorPage({super.key, required this.profile, this.contact});
  final Profile profile;
  final ContactView? contact;
  @override
  State<ContactEditorPage> createState() => _ContactEditorPageState();
}

class _ContactEditorPageState extends State<ContactEditorPage> {
  final _name = TextEditingController();
  final _route = TextEditingController();
  ContactView? _contact;
  RoutePreviewView? _preview;
  String? _checkedRoute;
  bool _compared = false;
  bool _busy = false;
  String? _error;
  String? _notice;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _contact = widget.contact;
    _name.text = _contact?.name ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    _route.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    final route = _route.text.trim();
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
      _compared = false;
    });
    try {
      final preview = (await widget.profile.previewRoutes(
        routes: [route],
      )).single;
      if (!mounted || revision != _revision) return;
      setState(() {
        _preview = preview;
        _checkedRoute = route;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Revisa la ruta completa del contacto. Debe ser de otro dispositivo.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = _contact == null
          ? await widget.profile.saveContact(
              route: _checkedRoute!,
              name: _name.text,
              safetyNumber: _compared ? _preview!.safetyNumber : null,
            )
          : await widget.profile.renameContact(
              identityId: _contact!.identityId,
              name: _name.text,
            );
      if (!mounted) return;
      setState(() {
        _contact = result;
        _name.text = result.name ?? '';
        _route.clear();
        _checkedRoute = null;
        _preview = null;
        _compared = false;
        _notice = 'Contacto guardado en este perfil.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'No se pudo guardar. Revisa el nombre y la comparación; conserva el perfil y vuelve a intentarlo.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final contact = _contact!;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await widget.profile.verifyContact(
        identityId: contact.identityId,
        safetyNumber: contact.safetyNumber,
      );
      if (mounted) {
        setState(() {
          _contact = result;
          _compared = false;
          _notice = 'Identidad verificada.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'La comparación no se pudo confirmar. Reabre el contacto y compara el número de nuevo.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contact = _contact;
    final number = contact?.safetyNumber ?? _preview?.safetyNumber;
    final identity = contact?.identityId ?? _preview?.identityId;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            contact == null ? 'Añadir contacto' : 'Datos del contacto',
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('contact-name'),
                      controller: _name,
                      enabled: !_busy,
                      maxLength: 128,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      decoration: const InputDecoration(
                        labelText: 'Nombre local (opcional)',
                        helperText:
                            'Solo se guarda en este perfil. No verifica la identidad.',
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (contact == null) ...[
                      TextField(
                        key: const Key('contact-route'),
                        controller: _route,
                        enabled: !_busy,
                        minLines: 3,
                        maxLines: 6,
                        maxLength: 4096,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        decoration: const InputDecoration(
                          labelText: 'Ruta de contacto',
                          helperText:
                              'Pide la ruta de este relay a la persona que quieres añadir.',
                          counterText: '',
                        ),
                        onChanged: (_) => setState(() {
                          _revision++;
                          _preview = null;
                          _checkedRoute = null;
                          _compared = false;
                          _error = null;
                        }),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: _busy ? null : _prepare,
                        child: const Text('Preparar contacto'),
                      ),
                    ],
                    if (identity != null) ...[
                      const SizedBox(height: 20),
                      SelectableText('Identidad $identity'),
                      const SizedBox(height: 12),
                      Text(
                        contact?.verified == true
                            ? 'Verificado'
                            : 'Sin verificar',
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Compara este número con la otra persona por otro canal. El nombre local no sustituye esta comprobación.',
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        number!,
                        key: const Key('contact-safety'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (contact?.verified != true)
                        CheckboxListTile(
                          key: const Key('contact-compared'),
                          contentPadding: EdgeInsets.zero,
                          value: _compared,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _compared = v ?? false),
                          title: const Text(
                            'Hemos comparado el número por otro canal y coincide.',
                          ),
                        ),
                      if (contact != null && !contact.verified)
                        OutlinedButton(
                          key: const Key('verify-contact'),
                          onPressed: _busy || !_compared ? null : _verify,
                          child: const Text('Verificar contacto'),
                        ),
                    ],
                    if (contact != null) ...[
                      const SizedBox(height: 16),
                      Text('${contact.devices.length} rutas guardadas'),
                      for (final device in contact.devices)
                        Text(
                          'Dispositivo ${contactId(device.deviceId)}${device.revoked ? " · Revocado" : ""}',
                        ),
                      const SizedBox(height: 12),
                      const Text(
                        'Para añadir o actualizar una ruta, vuelve a Añadir contacto. Comprueba que la identidad coincide y conserva el nombre que quieras usar.',
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('save-contact'),
                      onPressed: _busy || (contact == null && _preview == null)
                          ? null
                          : _save,
                      child: Text(
                        contact == null ? 'Guardar contacto' : 'Guardar nombre',
                      ),
                    ),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: LinearProgressIndicator(),
                      ),
                    if (_error != null || _notice != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(_error ?? _notice!),
                        ),
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
