import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'appearance.dart';
import 'design/design.dart';

String accentName(AppLocalizations l10n, Accent accent) => switch (accent) {
  Accent.pine => l10n.accentPine,
  Accent.lake => l10n.accentLake,
  Accent.plum => l10n.accentPlum,
  Accent.clay => l10n.accentClay,
  Accent.moss => l10n.accentMoss,
  Accent.slate => l10n.accentSlate,
};

String wallpaperName(AppLocalizations l10n, Wallpaper wallpaper) =>
    switch (wallpaper) {
      Wallpaper.plain => l10n.wallpaperPlain,
      Wallpaper.arcs => l10n.wallpaperArcs,
      Wallpaper.dots => l10n.wallpaperDots,
      Wallpaper.waves => l10n.wallpaperWaves,
      Wallpaper.diamonds => l10n.wallpaperDiamonds,
    };

/// Theme, accent, conversation background, text size and language, with a
/// preview that changes as they do.
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key, required this.controller});
  final AppearanceController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l10n = context.l10n;
      final look = controller.value;
      void set(Appearance next) => controller.update(next);
      return Scaffold(
        appBar: AppBar(title: Text(l10n.appearanceTitle)),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: EdgeInsets.symmetric(
                  horizontal: WindowSize.of(context).margin + 8,
                  vertical: 16,
                ),
                children: [
                  _Preview(wallpaper: look.wallpaper),
                  SectionTitle(l10n.themeTitle),
                  SegmentedButton<ThemeChoice>(
                    key: const Key('theme-choice'),
                    segments: [
                      ButtonSegment(
                        value: ThemeChoice.system,
                        label: Text(l10n.themeSystem),
                      ),
                      ButtonSegment(
                        value: ThemeChoice.light,
                        label: Text(l10n.themeLight),
                      ),
                      ButtonSegment(
                        value: ThemeChoice.dark,
                        label: Text(l10n.themeDark),
                      ),
                    ],
                    selected: {look.theme},
                    onSelectionChanged: (choice) =>
                        set(look.copyWith(theme: choice.single)),
                  ),
                  SectionTitle(l10n.accentTitle),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final accent in Accent.values)
                        _Swatch(
                          accent: accent,
                          selected: accent == look.accent,
                          onTap: () => set(look.copyWith(accent: accent)),
                        ),
                    ],
                  ),
                  SectionTitle(l10n.wallpaperTitle),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final wallpaper in Wallpaper.values)
                        _WallpaperTile(
                          wallpaper: wallpaper,
                          selected: wallpaper == look.wallpaper,
                          onTap: () => set(look.copyWith(wallpaper: wallpaper)),
                        ),
                    ],
                  ),
                  SectionTitle(l10n.textSizeTitle),
                  Row(
                    children: [
                      const Icon(Icons.text_decrease, size: 20),
                      Expanded(
                        child: Slider(
                          key: const Key('text-size'),
                          min: 0,
                          max: Appearance.textScales.length - 1.0,
                          divisions: Appearance.textScales.length - 1,
                          value: Appearance.textScales
                              .indexOf(look.textScale)
                              .toDouble(),
                          label: l10n.textSizeValue(
                            (look.textScale * 100).round(),
                          ),
                          semanticFormatterCallback: (value) =>
                              l10n.textSizeValue(
                                (Appearance.textScales[value.round()] * 100)
                                    .round(),
                              ),
                          onChanged: (value) => set(
                            look.copyWith(
                              textScale: Appearance.textScales[value.round()],
                            ),
                          ),
                        ),
                      ),
                      const Icon(Icons.text_increase, size: 20),
                    ],
                  ),
                  Text(
                    l10n.textSizeHelp,
                    style: ArveilType.secondary.copyWith(
                      color: ArveilColors.of(context).inkMuted,
                    ),
                  ),
                  SectionTitle(l10n.languageTitle),
                  RadioGroup<LanguageChoice>(
                    groupValue: look.language,
                    onChanged: (choice) => set(look.copyWith(language: choice)),
                    child: Column(
                      children: [
                        for (final (choice, label) in [
                          (LanguageChoice.system, l10n.languageSystem),
                          (LanguageChoice.spanish, 'Español'),
                          (LanguageChoice.english, 'English'),
                        ])
                          RadioListTile<LanguageChoice>(
                            key: Key('language-${choice.name}'),
                            contentPadding: EdgeInsets.zero,
                            value: choice,
                            title: Text(label),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Two bubbles on the chosen background, in the chosen colours and size.
class _Preview extends StatelessWidget {
  const _Preview({required this.wallpaper});
  final Wallpaper wallpaper;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = ArveilColors.of(context);
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ArveilShape.card),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(ArveilShape.card),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: double.infinity),
            child: ConversationBackground(
              wallpaper: wallpaper,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ChatBubble(
                      own: false,
                      meta: const BubbleMeta(time: '18:40'),
                      child: Text(l10n.sampleReceived),
                    ),
                    ChatBubble(
                      own: true,
                      meta: const BubbleMeta(
                        time: '18:42',
                        own: true,
                        status: DeliveryStatus.accepted,
                      ),
                      child: Text(l10n.sampleOwn),
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

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.accent,
    required this.selected,
    required this.onTap,
  });
  final Accent accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = accent.of(Theme.of(context).brightness);
    final c = ArveilColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: accentName(context.l10n, accent),
      excludeSemantics: true,
      child: InkWell(
        key: Key('accent-${accent.name}'),
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: palette.accent,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? c.ink : Colors.transparent,
              width: 3,
            ),
          ),
          child: selected
              ? Icon(Icons.check, color: palette.onAccent, size: 22)
              : null,
        ),
      ),
    );
  }
}

class _WallpaperTile extends StatelessWidget {
  const _WallpaperTile({
    required this.wallpaper,
    required this.selected,
    required this.onTap,
  });
  final Wallpaper wallpaper;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: wallpaperName(context.l10n, wallpaper),
      excludeSemantics: true,
      child: InkWell(
        key: Key('wallpaper-${wallpaper.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(ArveilShape.buttonSmall),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 80,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                border: Border.all(
                  color: selected ? c.accent : c.lineStrong,
                  width: selected ? 3 : 1,
                ),
                borderRadius: BorderRadius.circular(ArveilShape.buttonSmall),
              ),
              child: ConversationBackground(
                wallpaper: wallpaper,
                child: const SizedBox.expand(),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              wallpaperName(context.l10n, wallpaper),
              style: ArveilType.label.copyWith(
                color: selected ? c.accent : c.inkSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
