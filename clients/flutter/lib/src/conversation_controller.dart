import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'rust/api/profile.dart';

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
    _changed();
    try {
      do {
        _syncAgain = false;
        try {
          await profile.sync_(bootstrap: bootstrap);
          if (_disposed) return;
          networkError = null;
        } catch (_) {
          networkError =
              'Sincronización pendiente. Puedes leer y escribir sin conexión; usa Sincronizar para reintentar.';
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

  Future<String?> create(List<String> routes, List<String> numbers) async {
    if (_disposed || creating) return null;
    creating = true;
    error = null;
    _changed();
    try {
      final result = await profile.createConversation(
        bootstrap: bootstrap,
        routes: routes,
        safetyNumbers: numbers,
      );
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
    if (_watchGeneration case final generation?) {
      profile.stopWatching(generation: generation);
    }
    unawaited(_watch?.cancel());
    super.dispose();
  }
}
