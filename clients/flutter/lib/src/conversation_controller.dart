import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'attachment_files.dart';
import 'rust/api/profile.dart';

/// What the screen can honestly say about reaching the server. Nothing
/// here promises delivery: only when this device last synced, and why the
/// last attempt did not.
enum SyncState { never, syncing, synced, offline, refused }

/// One line about synchronization, relative to `now`.
String syncStatusText(SyncState state, DateTime? lastSynced, DateTime now) {
  String since(DateTime at) {
    final minutes = now.difference(at).inMinutes;
    if (minutes < 1) return 'ahora';
    if (minutes < 60) return 'hace $minutes min';
    String two(int n) => n.toString().padLeft(2, '0');
    return 'a las ${two(at.hour)}:${two(at.minute)}';
  }

  final last = lastSynced == null
      ? ''
      : ' · última sincronización ${since(lastSynced)}';
  return switch (state) {
    SyncState.never => 'Aún sin sincronizar',
    SyncState.syncing => 'Sincronizando…',
    SyncState.synced => 'Sincronizado ${since(lastSynced ?? now)}',
    SyncState.offline => 'Sin conexión con tu servidor$last',
    SyncState.refused => 'El servidor rechazó la sincronización$last',
  };
}

/// Ephemeral projections only; Rust owns messages, outbox and MLS state.
class ConversationController extends ChangeNotifier {
  ConversationController(this.profile, this.bootstrap);
  final Profile profile;
  final String bootstrap;
  List<ConversationView> conversations = [];
  List<HistoryEventView> events = [];
  String? selected;
  int? before;
  bool loading = false;
  bool loadingOlder = false;
  bool syncing = false;
  bool sending = false;
  bool creating = false;
  String? error;
  String? networkError;
  SyncState syncState = SyncState.never;

  /// When the last sync this controller ran succeeded. Presentation only:
  /// a new screen starts without one.
  DateTime? lastSynced;
  String? notice;
  bool _disposed = false;
  // Null means no lifecycle state has arrived during the initial local read.
  bool? _active;
  bool _syncAgain = false;
  Future<void>? _refreshWork;
  Future<void>? _syncWork;
  bool _refreshAgain = false;
  int _selection = 0;
  int _historyRead = 0;
  Timer? _timer;
  Timer? _debounce;
  Timer? _transferPoll;
  final Set<String> activeTransfers = {};
  StreamSubscription<ProgressView>? _watch;
  BigInt? _watchGeneration;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start({bool automatic = true}) async {
    final generation = profile.startWatching();
    _watchGeneration = generation;
    _watch = profile
        .watch(generation: generation)
        .listen(
          (_) {
            if (_disposed || _active != true) return;
            _debounce ??= Timer(const Duration(milliseconds: 150), () {
              _debounce = null;
              unawaited(refresh());
            });
          },
          onError: (Object _) {
            // Completion queries and the foreground timer also reconcile state.
          },
        );
    await refresh();
    if (!_disposed && automatic && _active == null) setActive(true);
  }

  void setActive(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    _timer?.cancel();
    if (active) {
      unawaited(sync());
      _timer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (!syncing) unawaited(sync());
      });
    } else {
      _syncAgain = false;
      _debounce?.cancel();
      _debounce = null;
    }
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (_refreshWork case final pending?) {
      _refreshAgain = true;
      return pending;
    }
    final work = _performRefresh();
    _refreshWork = work;
    return work.whenComplete(() => _refreshWork = null);
  }

  Future<void> _performRefresh() async {
    try {
      do {
        _refreshAgain = false;
        final rows = await profile.conversations();
        if (_disposed) return;
        conversations = rows;
        await _readSelected();
        _changed();
      } while (_refreshAgain && !_disposed);
    } catch (_) {
      error =
          'No se pudo leer el historial local. Conserva el perfil y vuelve a abrirlo.';
      _changed();
    }
  }

  Future<void> select(String? group) async {
    if (_disposed) return;
    selected = group;
    _selection++;
    events = [];
    before = null;
    loadingOlder = false;
    error = null;
    loading = group != null;
    _changed();
    final version = _selection;
    try {
      await _readSelected();
    } catch (_) {
      if (version == _selection) {
        error = 'No se pudo leer esta conversación. Vuelve a intentarlo.';
      }
    } finally {
      if (version == _selection) loading = false;
      _changed();
    }
  }

  Future<void> _readSelected() async {
    final group = selected;
    if (group == null || _disposed || loadingOlder) return;
    final read = ++_historyRead;
    final version = _selection;
    final oldest = events.isEmpty ? null : events.first.cursor;
    var page = await profile.historyPage(groupId: group, limit: 50);
    final rows = [...page.events];
    // Reconcile the displayed window in bounded pages without discarding the
    // older history the user opened. Stop promptly if the screen/selection changes.
    while (oldest != null &&
        page.next != null &&
        rows.isNotEmpty &&
        rows.first.cursor > oldest &&
        !_disposed &&
        version == _selection &&
        read == _historyRead) {
      page = await profile.historyPage(
        groupId: group,
        before: page.next,
        limit: 50,
      );
      rows.insertAll(0, page.events);
    }
    if (_disposed || version != _selection || read != _historyRead) return;
    events = rows;
    before = page.next;
    _changed();
    unawaited(_markSeen(group));
  }

  final Map<String, int> _marked = {};

  /// Tell Rust how far the open conversation has been seen, only while the
  /// app is in the foreground. A failure leaves the marker where it was and
  /// the next read tries again.
  Future<void> _markSeen(String group) async {
    if (_disposed || _active == false || selected != group || events.isEmpty) {
      return;
    }
    final newest = events.last.cursor;
    if ((_marked[group] ?? 0) >= newest) return;
    try {
      final marker = await profile.markRead(groupId: group, cursor: newest);
      if (_disposed) return;
      _marked[group] = marker.cursor;
      final row = conversations.where((c) => c.groupId == group).firstOrNull;
      if (row != null && row.unread != marker.unread) unawaited(refresh());
    } catch (_) {
      // The marker stays where it was; the next read tries again.
    }
  }

  Future<void> older() async {
    if (_disposed || loadingOlder || before == null || selected == null) return;
    final version = _selection;
    _historyRead++;
    final cursor = before!;
    loadingOlder = true;
    _changed();
    try {
      final page = await profile.historyPage(
        groupId: selected!,
        before: cursor,
        limit: 50,
      );
      if (_disposed || version != _selection) return;
      final merged = {
        for (final e in page.events) e.eventId: e,
        for (final e in events) e.eventId: e,
      };
      events = merged.values.toList()
        ..sort((a, b) => a.cursor.compareTo(b.cursor));
      before = page.next;
    } catch (_) {
      if (version == _selection) {
        error =
            'No se pudieron leer los mensajes anteriores. Puedes reintentar.';
      }
    } finally {
      if (version == _selection) loadingOlder = false;
      _changed();
    }
  }

  Future<void> sync() {
    if (_disposed) return Future.value();
    if (_syncWork case final pending?) {
      _syncAgain = true;
      return pending;
    }
    final work = _performSync();
    _syncWork = work;
    return work.whenComplete(() => _syncWork = null);
  }

  Future<void> _performSync() async {
    syncing = true;
    syncState = SyncState.syncing;
    _changed();
    try {
      do {
        _syncAgain = false;
        try {
          await profile.sync_(bootstrap: bootstrap);
          if (_disposed) return;
          networkError = null;
          lastSynced = DateTime.now();
          syncState = SyncState.synced;
        } catch (failure) {
          // Only a transport failure means the server was not reached; any
          // other typed refusal came from a server that answered.
          syncState = failure is CommandError_Transport
              ? SyncState.offline
              : SyncState.refused;
          networkError = syncState == SyncState.offline
              ? 'Sincronización pendiente. Puedes leer y escribir sin conexión; usa Sincronizar para reintentar.'
              : 'El servidor no aceptó la sincronización. Tus mensajes siguen guardados en este dispositivo; comprueba los datos del servidor con quien lo administra.';
          _syncAgain = false;
        }
        await refresh();
      } while (_syncAgain && !_disposed);
    } finally {
      syncing = false;
      _changed();
    }
  }

  Future<bool> send(String text) async {
    final group = selected;
    if (_disposed || sending || group == null) return false;
    if (text.trim().isEmpty || utf8.encode(text).length > 32768) {
      error = 'Escribe un mensaje de hasta 32 KiB.';
      _changed();
      return false;
    }
    sending = true;
    error = null;
    _changed();
    try {
      final result = await profile.queueMessage(groupId: group, text: text);
      // Acceptance comes only from the durable receipt, never a UI insertion.
      notice = result.warning == null
          ? null
          : 'Mensaje guardado. Reintenta la sincronización; no vuelvas a enviarlo.';
      unawaited(refresh());
      unawaited(sync());
      return true;
    } catch (_) {
      error =
          'No se confirmó el guardado. Conserva el borrador y consulta el historial antes de reintentar.';
      return false;
    } finally {
      sending = false;
      _changed();
    }
  }

  Future<bool> queueAttachment(String group, PickedAttachment file) async {
    if (_disposed || file.bytes.length > maximumAttachmentBytes) return false;
    try {
      final id = await profile.queueAttachment(
        groupId: group,
        name: file.name,
        bytes: file.bytes,
      );
      unawaited(refresh());
      unawaited(resumeAttachment(group, id));
      return true;
    } catch (_) {
      error =
          'No se confirmó el guardado del archivo. Consulta el historial antes de volver a adjuntarlo.';
      _changed();
      return false;
    }
  }

  Future<void> resumeAttachment(String group, String id) async {
    if (_disposed || !activeTransfers.add(id)) return;
    error = null;
    _transferPoll ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (_active == true) unawaited(refresh());
    });
    _changed();
    try {
      await profile.resumeAttachment(
        bootstrap: bootstrap,
        groupId: group,
        eventId: id,
      );
    } catch (_) {
      error =
          'La operación no se completó. Consulta el estado del archivo: reanuda su transferencia o sincroniza si ya está preparado.';
    } finally {
      activeTransfers.remove(id);
      if (activeTransfers.isEmpty) {
        _transferPoll?.cancel();
        _transferPoll = null;
      }
      await refresh();
      _changed();
    }
  }

  Future<void> cancelAttachment(String group, String id) async {
    try {
      await profile.cancelAttachment(groupId: group, eventId: id);
      error = null;
    } catch (_) {
      error =
          'No se pudo cancelar. La transferencia puede haber terminado; consulta su estado.';
    }
    await refresh();
    _changed();
  }

  Future<String?> create(List<String> routes, List<String> numbers) => _create(
    () => profile.createConversation(
      bootstrap: bootstrap,
      routes: routes,
      safetyNumbers: numbers,
    ),
  );

  Future<String?> createSaved(List<SavedRecipientView> recipients) => _create(
    () => profile.createContactConversation(
      bootstrap: bootstrap,
      recipients: recipients,
    ),
  );

  Future<String?> _create(Future<ChatMutationView> Function() operation) async {
    if (_disposed || creating) return null;
    creating = true;
    error = null;
    _changed();
    try {
      final result = await operation();
      if (_disposed) return null;
      notice = result.warning == null
          ? null
          : 'Conversación guardada. Sincroniza para completar el envío de la invitación; no la crees de nuevo.';
      await refresh();
      await select(result.groupId);
      return result.groupId;
    } catch (_) {
      error =
          'No se confirmó la creación. Comprueba las rutas, la conexión y que tus contactos tengan claves disponibles. Consulta la lista antes de reintentar.';
      return null;
    } finally {
      creating = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _debounce?.cancel();
    _transferPoll?.cancel();
    if (_watchGeneration case final generation?) {
      profile.stopWatching(generation: generation);
    }
    unawaited(_watch?.cancel());
    super.dispose();
  }
}
