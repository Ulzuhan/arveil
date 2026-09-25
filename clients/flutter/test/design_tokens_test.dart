import 'package:arveil/src/design/theme.dart';
import 'package:arveil/src/design/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 2.x contrast ratio between two opaque colours.
double contrast(Color a, Color b) {
  final (x, y) = (a.computeLuminance(), b.computeLuminance());
  final (high, low) = x > y ? (x, y) : (y, x);
  return (high + 0.05) / (low + 0.05);
}

/// Every text/background pair the system uses, and the minimum it owes:
/// 4.5:1 for text, 3:1 for the borders and marks of controls.
List<(String, Color, Color, double)> pairs(ArveilColors c, ColorScheme s) => [
  for (final (name, background) in [
    ('ground', c.ground),
    ('bar', c.bar),
    ('surface', c.surface),
    ('raised', c.surfaceRaised),
  ]) ...[
    ('ink on $name', c.ink, background, 4.5),
    ('muted on $name', c.inkMuted, background, 4.5),
    ('soft on $name', c.inkSoft, background, 4.5),
    ('accent text on $name', c.accent, background, 4.5),
    ('danger on $name', c.danger, background, 4.5),
    ('control border on $name', c.lineStrong, background, 3),
  ],
  ('muted on chip', c.inkMuted, c.chip, 4.5),
  ('soft on chip', c.inkSoft, c.chip, 4.5),
  ('on accent', c.onAccent, c.accent, 4.5),
  ('ink on own bubble', c.ink, c.accentSoft, 4.5),
  ('meta on own bubble', c.ownMeta, c.accentSoft, 4.5),
  ('attention', c.onAttention, c.attention, 4.5),
  ('on danger', c.onDanger, c.danger, 4.5),
  ('danger container', c.onDangerSoft, c.dangerSoft, 4.5),
  ('online mark', c.online, c.ground, 3),
  for (final (i, tone) in c.avatars.indexed)
    ('avatar $i', tone.foreground, tone.background, 4.5),
  for (final (i, sender) in c.senders.indexed)
    ('sender $i', sender, c.surfaceRaised, 4.5),
  ('scheme primary', s.onPrimary, s.primary, 4.5),
  ('scheme error', s.onError, s.error, 4.5),
  ('scheme error container', s.onErrorContainer, s.errorContainer, 4.5),
  (
    'scheme tertiary container',
    s.onTertiaryContainer,
    s.tertiaryContainer,
    4.5,
  ),
  ('scheme primary container', s.onPrimaryContainer, s.primaryContainer, 4.5),
  ('scheme surface variant text', s.onSurfaceVariant, s.surface, 4.5),
  ('scheme outline', s.outline, s.surface, 3),
];

void main() {
  for (final (mode, theme) in [
    ('light', ArveilTheme.light()),
    ('dark', ArveilTheme.dark()),
  ]) {
    test('$mode theme meets WCAG AA for every pair it uses', () {
      final colors = theme.extension<ArveilColors>()!;
      final failures = [
        for (final (name, fg, bg, minimum) in pairs(colors, theme.colorScheme))
          if (contrast(fg, bg) < minimum)
            '$name: ${contrast(fg, bg).toStringAsFixed(2)} < $minimum',
      ];
      expect(failures, isEmpty);
    });
  }

  test('an identity keeps its avatar and name colour, and they vary', () {
    const colors = ArveilColors.light;
    final ids = [for (var i = 0; i < 40; i++) 'identity-$i'];
    for (final id in ids) {
      expect(colors.avatarFor(id), same(colors.avatarFor(id)));
      expect(colors.senderFor(id), colors.senderFor(id));
    }
    expect(ids.map(colors.avatarFor).toSet().length, greaterThan(1));
    expect(ids.map(colors.senderFor).toSet().length, greaterThan(1));
  });

  test('both themes carry the tokens and use the bundled families', () {
    for (final theme in [ArveilTheme.light(), ArveilTheme.dark()]) {
      expect(theme.extension<ArveilColors>(), isNotNull);
      expect(theme.textTheme.bodyMedium!.fontFamily, 'InstrumentSans');
      expect(theme.textTheme.headlineLarge!.fontFamily, 'Newsreader');
    }
  });
}
