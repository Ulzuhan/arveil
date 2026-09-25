import 'package:flutter/material.dart';

import 'tokens.dart';

/// Arveil's mark: the ivory ribbon A of `assets/brand/mark.svg`, drawn from
/// the same path so the app needs no SVG renderer.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40});
  final double size;

  /// Ribbon colour of the app icon.
  static const ivory = Color(0xFFF6EFDF);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Arveil',
      image: true,
      child: Container(
        width: size,
        height: size,
        // The brand tile keeps the app icon's pine green in both themes.
        decoration: BoxDecoration(
          color: ArveilColors.light.accent,
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: CustomPaint(painter: _RibbonPainter()),
      ),
    );
  }
}

class _RibbonPainter extends CustomPainter {
  /// The path in the 1024-unit box of mark.svg.
  static final _ribbon = Path()
    ..moveTo(197, 717)
    ..cubicTo(249, 605, 315, 461, 405, 284)
    ..cubicTo(425, 237, 466, 207, 510, 207)
    ..cubicTo(554, 207, 586, 236, 607, 280)
    ..lineTo(821, 713)
    ..cubicTo(849, 773, 817, 816, 767, 816)
    ..cubicTo(710, 816, 655, 794, 614, 756)
    ..cubicTo(570, 715, 527, 656, 482, 624)
    ..lineTo(421, 596)
    ..cubicTo(449, 557, 509, 559, 603, 591)
    ..cubicTo(604, 535, 581, 487, 518, 417)
    ..cubicTo(449, 469, 415, 527, 396, 586)
    ..cubicTo(374, 650, 384, 710, 351, 760)
    ..cubicTo(327, 798, 288, 817, 255, 816)
    ..cubicTo(203, 815, 181, 771, 197, 717)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    // The path carries the icon's own margins; scale the whole box.
    final scale = size.shortestSide / 1024;
    canvas.save();
    canvas.scale(scale);
    canvas.drawPath(_ribbon, Paint()..color = BrandMark.ivory);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
