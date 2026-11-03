import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Goldens compare pixels, and antialiasing can differ between otherwise
/// identical machines. Ignore two steps of 8-bit channel rounding, then allow
/// at most 0.5% differing pixels. Image dimensions must still match exactly.
class TolerantComparator extends LocalFileComparator {
  TolerantComparator(super.testFile, {this.tolerance = 0.005});
  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    try {
      if (result.passed || result.diffPercent <= tolerance) return true;
      final actual = result.diffs?['testImage'];
      final expected = result.diffs?['masterImage'];
      if (actual != null &&
          expected != null &&
          actual.width == expected.width &&
          actual.height == expected.height) {
        final actualPixels = (await actual.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final expectedPixels = (await expected.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        var different = 0;
        for (var pixel = 0; pixel < actualPixels.length; pixel += 4) {
          for (var channel = 0; channel < 4; channel++) {
            if ((actualPixels[pixel + channel] -
                        expectedPixels[pixel + channel])
                    .abs() >
                2) {
              different++;
              break;
            }
          }
        }
        if (different / (actual.width * actual.height) <= tolerance) {
          return true;
        }
      }
      final error = await generateFailureOutput(result, golden, basedir);
      throw FlutterError(error);
    } finally {
      result.dispose();
    }
  }
}

/// Tests render with a placeholder font unless real ones are loaded; the
/// goldens should show the bundled typefaces and icons.
Future<void> loadFonts() async {
  Future<void> load(String family, List<String> assets) async {
    final loader = FontLoader(family);
    for (final asset in assets) {
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
  }

  await load('InstrumentSans', ['assets/fonts/InstrumentSans-VF.ttf']);
  await load('Newsreader', ['assets/fonts/Newsreader-VF.ttf']);
  await load('IBMPlexMono', [
    'assets/fonts/IBMPlexMono-Regular.ttf',
    'assets/fonts/IBMPlexMono-Medium.ttf',
  ]);
  await load('MaterialIcons', ['fonts/MaterialIcons-Regular.otf']);
}
