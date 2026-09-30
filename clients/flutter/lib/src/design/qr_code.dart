import 'package:flutter/material.dart';

import '../rust/api/profile.dart';

/// A QR code of [text], drawn from the modules the core computes. Dark on
/// white in every theme, with the quiet zone a scanner needs around it.
class QrCodeView extends StatefulWidget {
  const QrCodeView({
    super.key,
    required this.profile,
    required this.text,
    required this.label,
    this.size = 360,
  });
  final Profile profile;
  final String text;

  /// What a screen reader says instead of the code.
  final String label;
  final double size;

  @override
  State<QrCodeView> createState() => _QrCodeViewState();
}

class _QrCodeViewState extends State<QrCodeView> {
  late Future<QrView?> _code = widget.profile.qrCode(text: widget.text);

  @override
  void didUpdateWidget(QrCodeView old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _code = widget.profile.qrCode(text: widget.text);
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: widget.label,
    image: true,
    child: SizedBox.square(
      dimension: widget.size,
      child: FutureBuilder<QrView?>(
        future: _code,
        builder: (context, snapshot) => switch (snapshot.data) {
          final code? => CustomPaint(
            painter: QrPainter(
              code,
              pixelRatio: MediaQuery.devicePixelRatioOf(context),
            ),
          ),
          null => const ColoredBox(color: Colors.white),
        },
      ),
    ),
  );
}

class QrPainter extends CustomPainter {
  QrPainter(this.code, {this.pixelRatio = 1});
  final QrView code;
  final double pixelRatio;

  /// Modules of white around the code on every side.
  static const quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final width = code.width;
    // Whole physical pixels keep dark and light modules equally wide.
    // Widening every dark module makes dense codes harder to read.
    final pixels = (size.shortestSide * pixelRatio / (width + 2 * quiet))
        .floorToDouble();
    if (pixels < 1) return;
    final module = pixels / pixelRatio;
    final side = (width + 2 * quiet) * pixels;
    final left = ((size.width * pixelRatio - side) / 2).floor() / pixelRatio;
    final top = ((size.height * pixelRatio - side) / 2).floor() / pixelRatio;
    final dark = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var y = 0; y < width; y++) {
      for (var x = 0; x < width; x++) {
        if (code.modules[y * width + x] == 1) {
          canvas.drawRect(
            Rect.fromLTWH(
              left + (x + quiet) * module,
              top + (y + quiet) * module,
              module,
              module,
            ),
            dark,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(QrPainter old) =>
      old.code != code || old.pixelRatio != pixelRatio;
}
