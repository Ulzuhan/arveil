import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import '../l10n/l10n.dart';
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
    // Runs from initState too, before the widget may read inherited state.
    final l10n = currentStrings;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() => _error = l10n.archiveFailed);
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
      _message = context.l10n.archiveSaved(
        archive.records,
        archive.files,
        archive.unavailableFiles,
      );
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
      () => _message = context.l10n.archiveImported(
        receipt.imported,
        receipt.duplicates,
      ),
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
      setState(() => _message = context.l10n.archiveFileSaved);
    }
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.archiveTitle)),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(context.l10n.archiveExplanation),
        const SizedBox(height: 12),
        Text(context.l10n.archiveKeepApart),
        CheckboxListTile(
          value: _confirmed,
          onChanged: _busy
              ? null
              : (v) => setState(() => _confirmed = v ?? false),
          title: Text(context.l10n.archiveConsent),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        FilledButton.icon(
          key: const Key('export-archive'),
          onPressed: !_busy && _confirmed ? _export : null,
          icon: const Icon(Icons.save_alt),
          label: Text(context.l10n.archiveSave),
        ),
        if (_secret.pending)
          OutlinedButton(
            onPressed: () => setState(
              () => _secret.reveal(WidgetsBinding.instance.lifecycleState),
            ),
            child: Text(context.l10n.archiveRevealKey),
          ),
        if (_secret.visible case final secret?) ...[
          const SizedBox(height: 16),
          Text(context.l10n.archiveKeyNote),
          SelectableText(secret, key: const Key('archive-export-secret')),
          TextButton(
            onPressed: () => setState(_secret.clear),
            child: Text(context.l10n.archiveKeySaved),
          ),
        ],
        const Divider(height: 40),
        Text(
          context.l10n.archiveImportTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Text(context.l10n.archiveImportNote),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _busy ? null : _pick,
          child: Text(
            _encrypted == null
                ? context.l10n.archiveChooseFile
                : context.l10n.archiveFileChosen,
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
          decoration: InputDecoration(labelText: context.l10n.archiveKeyLabel),
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
          child: Text(context.l10n.archiveImport),
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
          context.l10n.archiveImportedTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (_page?.entries.isEmpty ?? false) Text(context.l10n.archiveEmpty),
        for (final e in _page?.entries ?? <ArchiveEntryView>[])
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _entryHeader(context.l10n, e),
                    key: Key('archive-entry-${e.eventId}'),
                  ),
                  SelectableText(e.text),
                  if (e.fileName != null)
                    e.fileSize == null
                        ? Text(context.l10n.archiveNoFileCopy)
                        : TextButton.icon(
                            onPressed: _busy ? null : () => _saveFile(e),
                            icon: const Icon(Icons.download),
                            label: Text(context.l10n.archiveSaveFileCopy),
                          ),
                ],
              ),
            ),
          ),
        if (_page?.next case final next?)
          TextButton(
            onPressed: _busy ? null : () => _run(() => _load(next)),
            child: Text(context.l10n.archiveOlder),
          ),
        TextButton(
          onPressed: _busy ? null : () => _run(() => _load()),
          child: Text(context.l10n.archiveBackToStart),
        ),
      ],
    ),
  );
}

/// "Group · direction", plus the author the archive names, if any.
String _entryHeader(AppLocalizations l10n, ArchiveEntryView e) {
  final group = e.groupId.substring(
    0,
    e.groupId.length < 12 ? e.groupId.length : 12,
  );
  final header = e.own
      ? l10n.archiveEntryOutgoing(group)
      : l10n.archiveEntryIncoming(group);
  return switch (e.senderLabel) {
    final sender? => l10n.archiveEntrySender(header, sender),
    null => header,
  };
}
