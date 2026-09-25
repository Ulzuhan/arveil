import 'package:flutter/material.dart';

/// Arveil's type scale (docs/es/CLIENT_DESIGN.md, "Tipografía"). Newsreader
/// for screen titles, Instrument Sans for the interface and IBM Plex Mono
/// for identifiers. The fonts are bundled; nothing is fetched at runtime.
abstract final class ArveilType {
  static const sans = 'InstrumentSans';
  static const serif = 'Newsreader';
  static const mono = 'IBMPlexMono';

  /// Variable fonts need their weight axis set explicitly: a weight alone
  /// would make the engine synthesize one.
  static TextStyle _style(
    String family,
    double size,
    int weight, {
    double? height,
    double? letterSpacing,
    double? opticalSize,
  }) => TextStyle(
    fontFamily: family,
    fontSize: size,
    fontWeight: FontWeight.values[(weight ~/ 100) - 1],
    height: height,
    letterSpacing: letterSpacing,
    fontVariations: [
      FontVariation.weight(weight.toDouble()),
      if (opticalSize != null) FontVariation.opticalSize(opticalSize),
    ],
  );

  /// Screen titles on phones.
  static final screenTitle = _style(
    serif,
    34,
    500,
    height: 1.1,
    letterSpacing: -0.3,
    opticalSize: 34,
  );

  /// Titles of panes and desktop screens.
  static final paneTitle = _style(
    serif,
    24,
    500,
    height: 1.15,
    opticalSize: 24,
  );
  static final barTitle = _style(sans, 17, 600);
  static final rowName = _style(sans, 16, 600);
  static final messageBody = _style(sans, 15.5, 400, height: 1.4);
  static final preview = _style(sans, 14.5, 400);
  static final secondary = _style(sans, 13, 400);
  static final label = _style(sans, 12.5, 600);
  static final meta = _style(sans, 11.5, 400);

  /// Eight groups of five digits, read aloud and compared.
  static final safetyNumber = _style(mono, 25, 500, letterSpacing: 2);
  static final identifier = _style(mono, 13.5, 400);

  /// Material roles mapped onto the scale, so stock widgets follow it.
  static TextTheme textTheme(Color ink, Color muted) {
    TextStyle c(TextStyle style, [Color? color]) =>
        style.copyWith(color: color ?? ink);
    return TextTheme(
      displaySmall: c(screenTitle),
      headlineLarge: c(screenTitle),
      headlineMedium: c(_style(serif, 28, 500, height: 1.15, opticalSize: 28)),
      headlineSmall: c(paneTitle),
      titleLarge: c(_style(sans, 20, 600)),
      titleMedium: c(barTitle),
      titleSmall: c(_style(sans, 15, 600)),
      bodyLarge: c(_style(sans, 16, 400, height: 1.45)),
      bodyMedium: c(messageBody),
      bodySmall: c(secondary, muted),
      labelLarge: c(_style(sans, 15, 600)),
      labelMedium: c(label),
      labelSmall: c(meta, muted),
    );
  }
}
