import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'accents.dart';
import 'tokens.dart';
import 'typography.dart';

/// The light and dark themes, built from the tokens only, with the chosen
/// accent.
abstract final class ArveilTheme {
  static ThemeData light({Accent accent = Accent.pine}) =>
      _build(ArveilColors.light.withAccent(accent.light), Brightness.light);
  static ThemeData dark({Accent accent = Accent.pine}) =>
      _build(ArveilColors.dark.withAccent(accent.dark), Brightness.dark);

  static ThemeData _build(ArveilColors c, Brightness brightness) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      primaryContainer: c.accentSoft,
      onPrimaryContainer: c.ink,
      secondary: c.accent,
      onSecondary: c.onAccent,
      secondaryContainer: c.accentSoft,
      onSecondaryContainer: c.ink,
      tertiary: c.onAttention,
      onTertiary: c.attention,
      tertiaryContainer: c.attention,
      onTertiaryContainer: c.onAttention,
      error: c.danger,
      onError: c.onDanger,
      errorContainer: c.dangerSoft,
      onErrorContainer: c.onDangerSoft,
      surface: c.surface,
      onSurface: c.ink,
      onSurfaceVariant: c.inkMuted,
      surfaceContainerLowest: c.surface,
      surfaceContainerLow: c.bar,
      surfaceContainer: c.bar,
      surfaceContainerHigh: c.chip,
      surfaceContainerHighest: c.surfaceRaised,
      outline: c.lineStrong,
      outlineVariant: c.line,
      inverseSurface: c.ink,
      onInverseSurface: c.ground,
      inversePrimary: c.accentSoft,
      shadow: Colors.black,
      scrim: Colors.black,
    );
    final text = ArveilType.textTheme(c.ink, c.inkMuted);
    RoundedRectangleBorder rounded(double radius) =>
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
    OutlineInputBorder field(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(ArveilShape.field),
          borderSide: BorderSide(color: color, width: width),
        );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: ArveilType.sans,
      textTheme: text,
      scaffoldBackgroundColor: c.ground,
      canvasColor: c.ground,
      dividerColor: c.divider,
      extensions: [c],
      appBarTheme: AppBarTheme(
        backgroundColor: c.bar,
        foregroundColor: c.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.titleMedium,
        systemOverlayStyle: brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: rounded(
          ArveilShape.card,
        ).copyWith(side: BorderSide(color: c.line)),
      ),
      dividerTheme: DividerThemeData(color: c.divider, thickness: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: rounded(ArveilShape.button),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: c.accent,
          side: BorderSide(color: c.lineStrong),
          shape: rounded(ArveilShape.button),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: c.accent,
          shape: rounded(ArveilShape.buttonSmall),
          textStyle: text.labelLarge,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceRaised,
        border: field(c.lineStrong),
        enabledBorder: field(c.lineStrong),
        focusedBorder: field(c.accent, 2),
        errorBorder: field(c.danger),
        labelStyle: TextStyle(color: c.inkMuted),
        hintStyle: TextStyle(color: c.inkMuted),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: c.inkSoft,
        textColor: c.ink,
        selectedColor: c.ink,
        selectedTileColor: c.accentSoft,
        shape: rounded(ArveilShape.buttonSmall),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: c.accent,
        textColor: c.onAccent,
        textStyle: text.labelMedium,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.bar,
        surfaceTintColor: Colors.transparent,
        indicatorColor: c.accentSoft,
        elevation: 0,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: c.bar,
        indicatorColor: c.accentSoft,
        selectedIconTheme: IconThemeData(color: c.ink),
        unselectedIconTheme: IconThemeData(color: c.inkSoft),
        selectedLabelTextStyle: text.labelMedium?.copyWith(color: c.ink),
        unselectedLabelTextStyle: text.labelMedium?.copyWith(color: c.inkSoft),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.accentSoft,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.ink,
        contentTextStyle: text.bodyMedium?.copyWith(color: c.ground),
        behavior: SnackBarBehavior.floating,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
    );
  }
}

/// Registers the bundled fonts' licenses with Flutter's license page, as
/// the SIL Open Font License asks of software that bundles the fonts.
void registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (family, file) in const [
      ('Newsreader', 'OFL-Newsreader.txt'),
      ('Instrument Sans', 'OFL-InstrumentSans.txt'),
      ('IBM Plex Mono', 'OFL-IBMPlexMono.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([
        family,
      ], await rootBundle.loadString('assets/fonts/$file'));
    }
  });
}
