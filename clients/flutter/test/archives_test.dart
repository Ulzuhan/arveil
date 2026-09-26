import 'dart:async';
import 'dart:typed_data';
import 'package:arveil/src/archive_files.dart';
import 'package:arveil/src/archives_page.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:flutter_test/flutter_test.dart';
import 'conversations_test.dart' show ChatProfile;

class ArchiveProfile extends ChatProfile {
  int exports = 0;
  int imports = 0;
  bool fail = false;
  @override
  Future<ArchiveView> exportArchive() async {
    exports++;
    if (fail) throw StateError('PRIVATE_HOST_PATH');
    return ArchiveView(
      encrypted: Uint8List.fromList([1, 2]),
      secret: 'fixture-secret',
      records: 1,
      files: 0,
      unavailableFiles: 1,
    );
  }

  @override
  Future<ArchiveReceiptView> importArchive({
    required List<int> encrypted,
    required String secret,
  }) async {
    imports++;
    if (fail) throw StateError('PRIVATE_HOST_PATH');
    return const ArchiveReceiptView(imported: 1, duplicates: 0);
  }

  @override
  Future<ArchivePageView> archivePage({
    PlatformInt64? before,
    required int limit,
  }) async => ArchivePageView(
    entries: imports == 0
        ? []
        : [
            ArchiveEntryView(
              groupId: 'aabbcc',
              eventId: '112233',
              kind: 'received',
              text: 'Archived text',
              createdAt: 1,
              senderLabel: 'Lucía',
              own: false,
            ),
          ],
  );
}

class MemoryArchives extends ArchiveFiles {
  bool cancelled = false;
  Completer<bool>? saving;
  Uint8List? saved;
  @override
  Future<bool> save(Uint8List encrypted) async {
    if (cancelled) return false;
    saved = encrypted;
    return saving == null ? true : await saving!.future;
  }

  @override
  Future<Uint8List?> open() async =>
      cancelled ? null : Uint8List.fromList([1, 2]);
}

void main() {
  Future<void> press(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.tap(f);
    await t.pumpAndSettle();
  }

  Future<void> show(WidgetTester t, ArchiveProfile p, MemoryArchives f) async {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(
      MaterialApp(
        home: ArchivesPage(profile: p, files: f),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets(
    'export requires acknowledgement; cancelled save reveals no secret',
    (t) async {
      final p = ArchiveProfile();
      final files = MemoryArchives()..cancelled = true;
      await show(t, p, files);
      expect(
        t
            .widget<FilledButton>(find.byKey(const Key('export-archive')))
            .onPressed,
        isNull,
      );
      await press(t, find.byType(CheckboxListTile));
      await press(t, find.byKey(const Key('export-archive')));
      expect(p.exports, 1);
      expect(find.text('fixture-secret'), findsNothing);
      files.cancelled = false;
      await press(t, find.byKey(const Key('export-archive')));
      expect(files.saved, [1, 2]);
      expect(find.text('fixture-secret'), findsOneWidget);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await t.pump();
      expect(find.text('fixture-secret'), findsNothing);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
  testWidgets('native save result waits for an explicit foreground reveal', (
    t,
  ) async {
    final files = MemoryArchives()..saving = Completer<bool>();
    await show(t, ArchiveProfile(), files);
    await press(t, find.byType(CheckboxListTile));
    await t.tap(find.byKey(const Key('export-archive')));
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    files.saving!.complete(true);
    await t.pumpAndSettle();
    expect(find.text('fixture-secret'), findsNothing);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    expect(find.text('fixture-secret'), findsNothing);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(find.text('fixture-secret'), findsNothing);
    await press(t, find.text('Mostrar clave del archivo guardado'));
    expect(find.text('fixture-secret'), findsOneWidget);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(find.text('fixture-secret'), findsNothing);
    expect(find.text('Mostrar clave del archivo guardado'), findsNothing);
  });
  testWidgets(
    'import clears secret and shows read-only records without a send action',
    (t) async {
      final p = ArchiveProfile();
      await show(t, p, MemoryArchives());
      await press(t, find.text('Elegir archivo cifrado'));
      await t.enterText(
        find.byKey(const Key('archive-import-secret')),
        'fixture-secret',
      );
      await t.pump();
      await press(t, find.byKey(const Key('import-archive')));
      expect(p.imports, 1);
      await t.scrollUntilVisible(
        find.text('Archived text'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Archived text'), findsOneWidget);
      // The author is the archive's claim, and says so.
      expect(
        find.text('Grupo aabbcc · Entrante · Lucía, según el archivo'),
        findsOneWidget,
      );
      expect(
        t
            .widget<TextField>(find.byKey(const Key('archive-import-secret')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.text('Enviar'), findsNothing);
    },
  );
  testWidgets('failure shows no raw diagnostics and allows retry', (t) async {
    final p = ArchiveProfile()..fail = true;
    await show(t, p, MemoryArchives());
    await press(t, find.byType(CheckboxListTile));
    await press(t, find.byKey(const Key('export-archive')));
    expect(find.byKey(const Key('archive-error')), findsOneWidget);
    expect(find.textContaining('PRIVATE_HOST_PATH'), findsNothing);
    p.fail = false;
    await press(t, find.byKey(const Key('export-archive')));
    expect(find.text('fixture-secret'), findsOneWidget);
  });
  test('archive streams stop at the byte limit', () async {
    final chunk = Uint8List(1024 * 1024);
    await expectLater(
      readBoundedArchive(Stream.fromIterable(List.filled(65, chunk))),
      throwsFormatException,
    );
    expect(await readBoundedArchive(Stream.value([1, 2, 3])), [1, 2, 3]);
  });
}
