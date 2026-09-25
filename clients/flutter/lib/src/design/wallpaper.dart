import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Backgrounds a conversation can have: plain, or a motif the app draws.
/// Nothing is loaded from outside, and bubbles, dates and notices stay
/// opaque on top, so a motif never lowers legibility.
enum Wallpaper { plain, arcs, dots, waves, diamonds }

/// A conversation's background under its content. The motif sits behind a
/// repaint boundary, so scrolling the messages never repaints it.
class ConversationBackground extends StatelessWidget {
  const ConversationBackground({
    super.key,
    required this.wallpaper,
    required this.child,
  });
  final Wallpaper wallpaper;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return ColoredBox(
      color: c.ground,
      child: Stack(
        children: [
          if (wallpaper != Wallpaper.plain)
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: WallpaperPainter(wallpaper, c.line),
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }
}

/// Draws one motif in the decorative line colour, which stays faint on
/// the ground in both themes.
class WallpaperPainter extends CustomPainter {
  WallpaperPainter(this.wallpaper, this.color);
  final Wallpaper wallpaper;
  final Color color;

  /// How many times any wallpaper was painted; lets a test show that
  /// scrolling does not repaint it.
  @visibleForTesting
  static int paints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    switch (wallpaper) {
      case Wallpaper.plain:
        return;
      case Wallpaper.arcs:
        const cell = 64.0;
        for (var y = 0.0; y < size.height + cell; y += cell) {
          for (var x = 0.0; x < size.width + cell; x += cell) {
            for (final r in const [14.0, 26.0, 38.0]) {
              canvas.drawArc(
                Rect.fromCircle(center: Offset(x, y), radius: r),
                0,
                math.pi / 2,
                false,
                stroke,
              );
            }
          }
        }
      case Wallpaper.dots:
        final fill = Paint()..color = color;
        const step = 22.0;
        var row = 0;
        for (var y = step / 2; y < size.height; y += step, row++) {
          final shift = row.isOdd ? step / 2 : 0.0;
          for (var x = shift; x < size.width; x += step) {
            canvas.drawCircle(Offset(x, y), 1.8, fill);
          }
        }
      case Wallpaper.waves:
        const gap = 30.0;
        for (var y = gap / 2; y < size.height + gap; y += gap) {
          final path = Path()..moveTo(0, y);
          for (var x = 0.0; x <= size.width; x += 8) {
            path.lineTo(x, y + 6 * math.sin(x / 24));
          }
          canvas.drawPath(path, stroke);
        }
      case Wallpaper.diamonds:
        const cell = 40.0;
        for (var y = 0.0; y < size.height + cell; y += cell) {
          for (var x = 0.0; x < size.width + cell; x += cell) {
            final path = Path()
              ..moveTo(x, y - 9)
              ..lineTo(x + 9, y)
              ..lineTo(x, y + 9)
              ..lineTo(x - 9, y)
              ..close();
            canvas.drawPath(path, stroke);
          }
        }
    }
  }

  @override
  bool shouldRepaint(WallpaperPainter old) =>
      old.wallpaper != wallpaper || old.color != color;
}
