import 'package:arveil/src/design/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A conversation on a background, in one theme and accent.
class _Panel extends StatelessWidget {
  const _Panel(this.theme, this.wallpaper);
  final ThemeData theme;
  final Wallpaper wallpaper;

  @override
  Widget build(BuildContext context) => Theme(
    data: theme,
    child: Expanded(
      child: ConversationBackground(
        wallpaper: wallpaper,
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DateSeparator('Hoy'),
              ChatBubble(
                own: false,
                sender: 'Lucía',
                meta: BubbleMeta(time: '18:40'),
                child: Text('¿Quedamos el sábado?'),
              ),
              ChatBubble(
                own: true,
                meta: BubbleMeta(
                  time: '18:42',
                  own: true,
                  status: DeliveryStatus.accepted,
                ),
                child: Text('¡Perfecto! Llevo el postre.'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    goldenFileComparator = TolerantComparator(
      Uri.parse('test/goldens/wallpapers_test.dart'),
    );
    await loadFonts();
  });

  testWidgets('two backgrounds keep bubbles legible in both themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(780, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ArveilTheme.light(),
        home: Material(
          child: Row(
            children: [
              _Panel(ArveilTheme.light(accent: Accent.pine), Wallpaper.arcs),
              _Panel(ArveilTheme.dark(accent: Accent.plum), Wallpaper.waves),
            ],
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(Row).first,
      matchesGoldenFile('wallpapers.png'),
    );
  });
}
