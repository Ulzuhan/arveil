import 'dart:convert';
import 'dart:io';

import 'package:arveil/main.dart';
import 'package:arveil/src/appearance.dart';
import 'package:arveil/src/design/design.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'conversation_view_test.dart' show HistoryProfile, message;
import 'chat_list_test.dart' show chatWith, peer;
import 'design_tokens_test.dart' show contrast, pairs;
import 'navigation_test.dart' show HomeProfile, desktop;
import 'widget_test.dart' show openSetting;

Future<AppearanceController> openApp(
  WidgetTester tester, {
  HomeProfile? profile,
  Appearance start = const Appearance(),
}) async {
  tester.view.physicalSize = desktop;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final appearance = AppearanceController(MemoryAppearanceStore(), start);
  final opened = profile ?? HomeProfile();
  final session = ProfileSession(opener: () async => opened);
  addTearDown(session.dispose);
  await tester.pumpWidget(ArveilApp(session: session, appearance: appearance));
  await tester.tap(find.text('Abrir perfil'));
  await tester.pumpAndSettle();
  return appearance;
}

void main() {
  for (final accent in Accent.values) {
    for (final (mode, theme) in [
      ('light', ArveilTheme.light(accent: accent)),
      ('dark', ArveilTheme.dark(accent: accent)),
    ]) {
      test('${accent.name} meets WCAG AA in the $mode theme', () {
        final colors = theme.extension<ArveilColors>()!;
        final failures = [
          for (final (name, fg, bg, minimum) in pairs(
            colors,
            theme.colorScheme,
          ))
            if (contrast(fg, bg) < minimum)
              '$name: ${contrast(fg, bg).toStringAsFixed(2)} < $minimum',
        ];
        expect(failures, isEmpty);
      });
    }
  }

  test('preferences keep each valid field and default the rest', () {
    const chosen = Appearance(
      theme: ThemeChoice.dark,
      accent: Accent.clay,
      wallpaper: Wallpaper.dots,
      textScale: 1.2,
      language: LanguageChoice.english,
    );
    expect(
      Appearance.fromJson(jsonDecode(jsonEncode(chosen.toJson()))),
      chosen,
    );
    final mixed = Appearance.fromJson({
      'theme': 'neon',
      'accent': 'moss',
      'textScale': 3.0,
      'wallpaper': 42,
    });
    expect(mixed.theme, ThemeChoice.system);
    expect(mixed.accent, Accent.moss);
    expect(mixed.textScale, 1.0);
    expect(mixed.wallpaper, Wallpaper.plain);
    expect(Appearance.fromJson('not a map'), const Appearance());
    expect(chosen.toJson().keys.toSet(), {
      'version',
      'theme',
      'accent',
      'wallpaper',
      'textScale',
      'language',
    });
  });

  test('the file is replaced whole and a broken one falls back', () async {
    final directory = await Directory.systemTemp.createTemp('appearance');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileAppearanceStore(() async => directory);
    final controller = await AppearanceController.load(store);
    expect(controller.value, const Appearance());
    await controller.update(
      const Appearance(accent: Accent.lake, textScale: 1.1),
    );
    final file = File('${directory.path}/appearance.json');
    expect(File('${file.path}.tmp').existsSync(), isFalse);
    expect((await AppearanceController.load(store)).value.accent, Accent.lake);
    file.writeAsStringSync('{broken');
    expect((await AppearanceController.load(store)).value, const Appearance());
  });

  testWidgets('changes apply at once: theme, accent, text size, language', (
    tester,
  ) async {
    final appearance = await openApp(tester);
    await openSetting(tester, 'open-appearance');
    await tester.tap(find.text('Oscuro'));
    await tester.pumpAndSettle();
    expect(appearance.value.theme, ThemeChoice.dark);
    BuildContext page() => tester.element(find.byType(Scaffold).last);
    expect(Theme.of(page()).brightness, Brightness.dark);

    await tester.tap(find.byKey(const Key('accent-plum')));
    await tester.pumpAndSettle();
    expect(Theme.of(page()).colorScheme.primary, Accent.plum.dark.accent);

    final slider = tester.getRect(find.byKey(const Key('text-size')));
    await tester.tapAt(Offset(slider.right - 12, slider.center.dy));
    await tester.pumpAndSettle();
    expect(appearance.value.textScale, 1.3);
    expect(MediaQuery.textScalerOf(page()).scale(10), closeTo(13, 0.001));

    final english = find.byKey(const Key('language-english'));
    await tester.scrollUntilVisible(
      english,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(english);
    await tester.pumpAndSettle();
    await tester.tap(english);
    await tester.pumpAndSettle();
    expect(appearance.value.language, LanguageChoice.english);
    expect(find.widgetWithText(AppBar, 'Appearance'), findsOneWidget);
  });

  testWidgets('scrolling a conversation never repaints its background', (
    tester,
  ) async {
    final now = DateTime.now();
    final history = [
      for (var i = 0; i < 40; i++)
        message('m$i', now.add(Duration(minutes: i * 20)), author: 'Lucía'),
    ];
    final group = chatWith('g', [peer('lucia', 'Lucía')]);
    await openApp(
      tester,
      profile: HistoryProfile([group], history),
      start: const Appearance(wallpaper: Wallpaper.arcs),
    );
    await tester.tap(find.byKey(const Key('conversation-g')));
    await tester.pumpAndSettle();
    final painter = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is WallpaperPainter,
    );
    expect(painter, findsOneWidget);
    expect(
      find.ancestor(of: painter, matching: find.byType(RepaintBoundary)),
      findsWidgets,
    );
    final before = WallpaperPainter.paints;
    await tester.drag(
      find.byKey(const ValueKey('history-g')),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(WallpaperPainter.paints, before);
  });
}
