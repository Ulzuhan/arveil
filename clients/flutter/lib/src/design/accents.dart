import 'package:flutter/material.dart';

import 'tokens.dart';

/// One accent in one theme: the colour, text on it, its soft tint for own
/// bubbles and selection, and the time and state inside an own bubble.
@immutable
class AccentPalette {
  const AccentPalette(this.accent, this.onAccent, this.soft, this.meta);
  final Color accent;
  final Color onAccent;
  final Color soft;
  final Color meta;
}

/// The accents a person can choose (docs/es/CLIENT_DESIGN.md,
/// "Personalización"). Each has a light and a dark variant, and
/// `test/appearance_test.dart` checks every text pair of the system with
/// each of them. There is no free colour picker: it could not keep that
/// promise.
enum Accent {
  pine(
    AccentPalette(
      Color(0xFF245B51),
      Color(0xFFFFFFFF),
      Color(0xFFDDEAE4),
      Color(0xFF3D5A53),
    ),
    AccentPalette(
      Color(0xFF8FD0C0),
      Color(0xFF0E1413),
      Color(0xFF1A423B),
      Color(0xFFA9CFC5),
    ),
  ),
  lake(
    AccentPalette(
      Color(0xFF235A87),
      Color(0xFFFFFFFF),
      Color(0xFFDCE6F1),
      Color(0xFF34516D),
    ),
    AccentPalette(
      Color(0xFF9CC3EE),
      Color(0xFF0E1413),
      Color(0xFF1E3650),
      Color(0xFFB3CBE6),
    ),
  ),
  plum(
    AccentPalette(
      Color(0xFF5E4190),
      Color(0xFFFFFFFF),
      Color(0xFFE7E0F2),
      Color(0xFF4D4370),
    ),
    AccentPalette(
      Color(0xFFC6B8F2),
      Color(0xFF0E1413),
      Color(0xFF352A4D),
      Color(0xFFCBC1EA),
    ),
  ),
  clay(
    AccentPalette(
      Color(0xFF9A4526),
      Color(0xFFFFFFFF),
      Color(0xFFF4E1D7),
      Color(0xFF6B4131),
    ),
    AccentPalette(
      Color(0xFFF0AE8E),
      Color(0xFF0E1413),
      Color(0xFF4A2A1D),
      Color(0xFFE8C3B0),
    ),
  ),
  moss(
    AccentPalette(
      Color(0xFF4E5D1D),
      Color(0xFFFFFFFF),
      Color(0xFFE4E9D2),
      Color(0xFF4A5332),
    ),
    AccentPalette(
      Color(0xFFC4D68E),
      Color(0xFF0E1413),
      Color(0xFF333D1B),
      Color(0xFFCCD6AE),
    ),
  ),
  slate(
    AccentPalette(
      Color(0xFF3A4750),
      Color(0xFFFFFFFF),
      Color(0xFFE1E6EA),
      Color(0xFF434F58),
    ),
    AccentPalette(
      Color(0xFFB9C6CF),
      Color(0xFF0E1413),
      Color(0xFF29333A),
      Color(0xFFC0CBD3),
    ),
  );

  const Accent(this.light, this.dark);
  final AccentPalette light;
  final AccentPalette dark;

  AccentPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

extension AccentTokens on ArveilColors {
  /// These tokens with another accent; everything else stays.
  ArveilColors withAccent(AccentPalette palette) => ArveilColors(
    ground: ground,
    bar: bar,
    surface: surface,
    surfaceRaised: surfaceRaised,
    ink: ink,
    inkMuted: inkMuted,
    inkSoft: inkSoft,
    line: line,
    lineStrong: lineStrong,
    divider: divider,
    accent: palette.accent,
    onAccent: palette.onAccent,
    accentSoft: palette.soft,
    ownMeta: palette.meta,
    chip: chip,
    attention: attention,
    onAttention: onAttention,
    danger: danger,
    onDanger: onDanger,
    dangerSoft: dangerSoft,
    onDangerSoft: onDangerSoft,
    online: online,
    avatars: avatars,
    senders: senders,
  );
}
