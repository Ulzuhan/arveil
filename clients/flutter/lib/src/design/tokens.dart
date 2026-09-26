import 'package:flutter/material.dart';

/// Arveil's colour tokens (docs/es/CLIENT_DESIGN.md, "Sistema visual").
///
/// Screens read colours from here, never as literals. Every text/background
/// pair a screen uses is checked for WCAG AA contrast by
/// `test/design_tokens_test.dart`, in both themes.
@immutable
class ArveilColors extends ThemeExtension<ArveilColors> {
  const ArveilColors({
    required this.ground,
    required this.bar,
    required this.surface,
    required this.surfaceRaised,
    required this.ink,
    required this.inkMuted,
    required this.inkSoft,
    required this.line,
    required this.lineStrong,
    required this.divider,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.ownMeta,
    required this.chip,
    required this.attention,
    required this.onAttention,
    required this.danger,
    required this.onDanger,
    required this.dangerSoft,
    required this.onDangerSoft,
    required this.online,
    required this.avatars,
    required this.senders,
  });

  /// Page and message-area background.
  final Color ground;

  /// Bars, composer and side panes.
  final Color bar;

  /// Cards and settings groups.
  final Color surface;

  /// Other people's bubbles and text fields.
  final Color surfaceRaised;
  final Color ink;
  final Color inkMuted;
  final Color inkSoft;

  /// Decorative borders and separators.
  final Color line;

  /// Borders of controls, which need 3:1 against their background.
  final Color lineStrong;
  final Color divider;
  final Color accent;
  final Color onAccent;

  /// Own bubbles, selection and the active tab.
  final Color accentSoft;

  /// Time and delivery state inside an own bubble.
  final Color ownMeta;

  /// Date separators and conversation notices.
  final Color chip;
  final Color attention;
  final Color onAttention;
  final Color danger;
  final Color onDanger;
  final Color dangerSoft;
  final Color onDangerSoft;
  final Color online;

  /// Avatar tones, background and text, chosen by identity.
  final List<AvatarTone> avatars;

  /// Author names in group conversations, chosen by identity.
  final List<Color> senders;

  static const light = ArveilColors(
    ground: Color(0xFFF4F1EA),
    bar: Color(0xFFFBF9F4),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFFFFF),
    ink: Color(0xFF16211F),
    inkMuted: Color(0xFF56625F),
    inkSoft: Color(0xFF3F4B48),
    line: Color(0xFFE3DED3),
    lineStrong: Color(0xFF7A8480),
    divider: Color(0xFFECE7DE),
    accent: Color(0xFF245B51),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFDDEAE4),
    ownMeta: Color(0xFF3D5A53),
    chip: Color(0xFFEAE5DA),
    attention: Color(0xFFF6E7CC),
    onAttention: Color(0xFF6B4108),
    danger: Color(0xFFA2382B),
    onDanger: Color(0xFFFFFFFF),
    dangerSoft: Color(0xFFF7DEDA),
    onDangerSoft: Color(0xFF6E2016),
    online: Color(0xFF2E7D6B),
    avatars: [
      AvatarTone(Color(0xFFDCE8D5), Color(0xFF2E4A28)),
      AvatarTone(Color(0xFFEFDCCB), Color(0xFF6A3A17)),
      AvatarTone(Color(0xFFD9E4F0), Color(0xFF24476B)),
      AvatarTone(Color(0xFFE8D9EA), Color(0xFF5A3561)),
      AvatarTone(Color(0xFFE3E6D2), Color(0xFF4A4F24)),
    ],
    senders: [
      Color(0xFF8A4B1E),
      Color(0xFF2F5D8A),
      Color(0xFF5B4A8A),
      Color(0xFF2E6B3E),
    ],
  );

  static const dark = ArveilColors(
    ground: Color(0xFF0E1413),
    bar: Color(0xFF151D1C),
    surface: Color(0xFF151D1C),
    surfaceRaised: Color(0xFF1B2524),
    ink: Color(0xFFE6ECEA),
    inkMuted: Color(0xFF9DAAA6),
    inkSoft: Color(0xFFC4CFCC),
    line: Color(0xFF25302E),
    lineStrong: Color(0xFF6C7A76),
    divider: Color(0xFF25302E),
    accent: Color(0xFF8FD0C0),
    onAccent: Color(0xFF0E1413),
    accentSoft: Color(0xFF1D4740),
    ownMeta: Color(0xFFA9CFC5),
    chip: Color(0xFF1B2524),
    attention: Color(0xFF3A2A12),
    onAttention: Color(0xFFF2C98A),
    danger: Color(0xFFF2A59B),
    onDanger: Color(0xFF0E1413),
    dangerSoft: Color(0xFF4A1D17),
    onDangerSoft: Color(0xFFF2A59B),
    online: Color(0xFF6FB3A3),
    avatars: [
      AvatarTone(Color(0xFF243A2A), Color(0xFFCFE6C8)),
      AvatarTone(Color(0xFF40301F), Color(0xFFF0D6BF)),
      AvatarTone(Color(0xFF243548), Color(0xFFCFE0F2)),
      AvatarTone(Color(0xFF3A2A40), Color(0xFFEBD3F0)),
      AvatarTone(Color(0xFF343823), Color(0xFFE2E6C2)),
    ],
    senders: [
      Color(0xFFE8B48A),
      Color(0xFF9CC3EE),
      Color(0xFFC3B5F0),
      Color(0xFFA5D6A7),
    ],
  );

  /// The same tone for an identity on every device: a stable choice from
  /// its identifier, never from a name that can change.
  AvatarTone avatarFor(String identity) =>
      avatars[_index(identity, avatars.length)];

  Color senderFor(String identity) => senders[_index(identity, senders.length)];

  static int _index(String identity, int count) {
    var hash = 0;
    for (final unit in identity.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash % count;
  }

  /// The tokens of the theme in use; the defaults for its brightness when
  /// a widget is shown outside [ArveilTheme], as in a lone widget test.
  static ArveilColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ArveilColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  ArveilColors copyWith() => this;

  @override
  ArveilColors lerp(ArveilColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return ArveilColors(
      ground: mix(ground, other.ground),
      bar: mix(bar, other.bar),
      surface: mix(surface, other.surface),
      surfaceRaised: mix(surfaceRaised, other.surfaceRaised),
      ink: mix(ink, other.ink),
      inkMuted: mix(inkMuted, other.inkMuted),
      inkSoft: mix(inkSoft, other.inkSoft),
      line: mix(line, other.line),
      lineStrong: mix(lineStrong, other.lineStrong),
      divider: mix(divider, other.divider),
      accent: mix(accent, other.accent),
      onAccent: mix(onAccent, other.onAccent),
      accentSoft: mix(accentSoft, other.accentSoft),
      ownMeta: mix(ownMeta, other.ownMeta),
      chip: mix(chip, other.chip),
      attention: mix(attention, other.attention),
      onAttention: mix(onAttention, other.onAttention),
      danger: mix(danger, other.danger),
      onDanger: mix(onDanger, other.onDanger),
      dangerSoft: mix(dangerSoft, other.dangerSoft),
      onDangerSoft: mix(onDangerSoft, other.onDangerSoft),
      online: mix(online, other.online),
      avatars: t < 0.5 ? avatars : other.avatars,
      senders: t < 0.5 ? senders : other.senders,
    );
  }
}

/// An avatar's background and the initials drawn on it.
@immutable
class AvatarTone {
  const AvatarTone(this.background, this.foreground);
  final Color background;
  final Color foreground;
}

/// Radii and spacing shared by components.
abstract final class ArveilShape {
  static const double bubble = 18;
  static const double bubbleTail = 6;
  static const double card = 20;
  static const double button = 16;
  static const double buttonSmall = 12;
  static const double field = 14;
  static const double primaryButtonHeight = 52;

  /// Spacing steps, in multiples of four.
  static const double s1 = 4, s2 = 8, s3 = 12, s4 = 16, s5 = 20, s6 = 24;

  /// Motion is brief, and none when the system asks to reduce it.
  static Duration motion(BuildContext context) =>
      MediaQuery.of(context).disableAnimations
      ? Duration.zero
      : const Duration(milliseconds: 200);
}
