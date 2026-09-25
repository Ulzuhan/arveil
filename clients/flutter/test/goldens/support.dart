import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Goldens compare pixels, and antialiasing can differ between otherwise
/// identical machines. A small share of differing pixels is accepted; a
/// layout, colour or font change moves far more.
class TolerantComparator extends LocalFileComparator {
  TolerantComparator(super.testFile, {this.tolerance = 0.005});
  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= tolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
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
