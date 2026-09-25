import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'archive_files.dart';
import 'attachment_files.dart';
import 'export_secret.dart';
import 'rust/api/profile.dart';

class ArchivesPage extends StatefulWidget {
  const ArchivesPage({
    super.key,
    required this.profile,
    this.files = const ArchiveFiles(),
    this.attachments = const AttachmentFiles(),
  });
  final Profile profile;
  final ArchiveFiles files;
  final AttachmentFiles attachments;
  @override
  State<ArchivesPage> createState() => _ArchivesPageState();
}

class _ArchivesPageState extends State<ArchivesPage>
    with WidgetsBindingObserver {
  final _secretInput = TextEditingController();
  Uint8List? _encrypted;
  final _secret = ExportSecret();
  String? _message;
  String? _error;
  bool _busy = false;
  bool _confirmed = false;
  ArchivePageView? _page;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _run(() => _load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _secretInput.dispose();
    _secret.clear();
    _encrypted = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _secretInput.clear();
    }
    setState(() => _secret.lifecycle(state));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'No se pudo completar la operación. Comprueba el archivo, su clave y que pertenece a tu identidad. Máximo 10.000 registros; exportación de hasta 48 MiB de contenido e importación de archivos de hasta 64 MiB.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load([PlatformInt64? before]) async {
    final page = await widget.profile.archivePage(before: before, limit: 50);
    if (mounted) setState(() => _page = page);
  }

  Future<void> _export() => _run(() async {
    setState(() {
      _secret.clear();
      _message = null;
    });
    final archive = await widget.profile.exportArchive();
    if (!mounted) return;
    final saved = await widget.files.save(archive.encrypted);
    if (!mounted || !saved) return;
    setState(() {
      _message =
          'Archivo guardado: ${archive.records} registros, ${archive.files} adjuntos con copia, ${archive.unavailableFiles} sin copia.';
      _secret.saved(archive.secret, WidgetsBinding.instance.lifecycleState);
    });
  });
  Future<void> _pick() => _run(() async {
    final bytes = await widget.files.open();
    if (mounted && bytes != null) {
      setState(() {
        _encrypted = bytes;
        _message = null;
      });
    }
  });
  Future<void> _import() => _run(() async {
    final bytes = _encrypted!;
    final secret = _secretInput.text.trim();
    _secretInput.clear();
    setState(() {
      _encrypted = null;
      _message = null;
      _secret.clear();
    });
    final receipt = await widget.profile.importArchive(
      encrypted: bytes,
      secret: secret,
    );
    if (!mounted) return;
    setState(
      () => _message =
          '${receipt.imported} registros importados; ${receipt.duplicates} ya existentes, conservados sin cambios.',
    );
    await _load();
  });
  Future<void> _saveFile(ArchiveEntryView entry) => _run(() async {
    final bytes = await widget.profile.archiveFile(
      groupId: entry.groupId,
      eventId: entry.eventId,
    );
    if (!mounted) return;
    if (await widget.attachments.save(entry.fileName!, bytes) && mounted) {
      setState(
        () => _message = 'Copia del adjunto guardada en el destino elegido.',
      );
    }
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Historial cifrado')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'El archivo recupera mensajes y adjuntos disponibles, sin recuperar la identidad ni las sesiones de grupo. Restaura primero tu identidad con su kit si has perdido el dispositivo.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Guarda el archivo y su clave por separado. Juntos permiten leer esta copia del pasado. No se descargan adjuntos pendientes; los archivos antiguos de la CLI pueden figurar sin copia.',
        ),
        CheckboxListTile(
          value: _confirmed,
          onChanged: _busy
              ? null
              : (v) => setState(() => _confirmed = v ?? false),
          title: const Text(
            'Entiendo que esta copia permite leer el historial',
          ),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        FilledButton.icon(
          key: const Key('export-archive'),
          onPressed: !_busy && _confirmed ? _export : null,
          icon: const Icon(Icons.save_alt),
          label: const Text('Guardar historial cifrado'),
        ),
        if (_secret.pending)
          OutlinedButton(
            onPressed: () => setState(
              () => _secret.reveal(WidgetsBinding.instance.lifecycleState),
            ),
            child: const Text('Mostrar clave del archivo guardado'),
          ),
        if (_secret.visible case final secret?) ...[
          const SizedBox(height: 16),
          const Text(
            'Guarda esta clave por separado. Desaparece al salir o cambiar de aplicación; Arveil no la conserva.',
          ),
          SelectableText(secret, key: const Key('archive-export-secret')),
          TextButton(
            onPressed: () => setState(_secret.clear),
            child: const Text('He guardado la clave'),
          ),
        ],
        const Divider(height: 40),
        Text(
          'Importar historial',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'Solo se acepta un archivo de esta identidad. Los registros se añaden como historial de solo lectura: no se reenvían ni dan acceso a los grupos. Un archivo importado no demuestra la autoría de sus mensajes.',
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _busy ? null : _pick,
          child: Text(
            _encrypted == null
                ? 'Elegir archivo cifrado'
                : 'Archivo seleccionado; cambiar',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('archive-import-secret'),
          controller: _secretInput,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Clave del archivo'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('import-archive'),
          onPressed:
              !_busy &&
                  _encrypted != null &&
                  _secretInput.text.trim().isNotEmpty
              ? _import
              : null,
          child: const Text('Importar como historial'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(error, key: const Key('archive-error')),
          ),
        if (_message case final message?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(message, key: const Key('archive-result')),
          ),
        const Divider(height: 40),
        Text(
          'Historial importado · solo lectura',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (_page?.entries.isEmpty ?? false)
          const Text('Todavía no hay registros importados.'),
        for (final e in _page?.entries ?? <ArchiveEntryView>[])
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Grupo ${e.groupId.substring(0, e.groupId.length < 12 ? e.groupId.length : 12)} · ${e.own ? 'Saliente' : 'Entrante'}${e.senderLabel == null ? '' : ' · ${e.senderLabel}, según el archivo'}',
                    key: Key('archive-entry-${e.eventId}'),
                  ),
                  SelectableText(e.text),
                  if (e.fileName != null)
                    e.fileSize == null
                        ? const Text('Sin copia del adjunto en este archivo')
                        : TextButton.icon(
                            onPressed: _busy ? null : () => _saveFile(e),
                            icon: const Icon(Icons.download),
                            label: const Text('Guardar copia del adjunto'),
                          ),
                ],
              ),
            ),
          ),
        if (_page?.next case final next?)
          TextButton(
            onPressed: _busy ? null : () => _run(() => _load(next)),
            child: const Text('Ver registros anteriores'),
          ),
        TextButton(
          onPressed: _busy ? null : () => _run(() => _load()),
          child: const Text('Volver al inicio del historial'),
        ),
      ],
    ),
  );
}
