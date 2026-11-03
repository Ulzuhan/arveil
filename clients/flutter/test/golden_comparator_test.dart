import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'goldens/support.dart';

Future<Uint8List> picture({
  int width = 100,
  int height = 100,
  int background = 0xff808080,
  int changedPixels = 0,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(ui.Color(background), ui.BlendMode.src);
  if (changedPixels > 0) {
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, changedPixels.toDouble(), 1),
      ui.Paint()..color = const ui.Color(0xff000000),
    );
  }
  final drawing = recorder.endRecording();
  final image = await drawing.toImage(width, height);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    drawing.dispose();
  }
}

void main() {
  late Directory directory;
  late TolerantComparator comparator;
  final golden = Uri.parse('reference.png');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('arveil-golden-');
    comparator = TolerantComparator(directory.uri.resolve('test.dart'));
    await comparator.update(golden, await picture());
  });

  tearDown(() async => directory.delete(recursive: true));

  test('identical pixels pass', () async {
    expect(await comparator.compare(await picture(), golden), isTrue);
  });

  test('two levels of channel rounding pass in either direction', () async {
    for (final color in [0xff7e8082, 0xff82807e]) {
      expect(
        await comparator.compare(await picture(background: color), golden),
        isTrue,
      );
    }
  });

  test('a visible tint across the image fails', () async {
    await expectLater(
      comparator.compare(await picture(background: 0xff838080), golden),
      throwsA(isA<FlutterError>()),
    );
  });

  test('the original 0.5 percent pixel budget is inclusive', () async {
    expect(
      await comparator.compare(await picture(changedPixels: 50), golden),
      isTrue,
    );
  });

  test('changes above the pixel budget fail and produce diagnostics', () async {
    await expectLater(
      comparator.compare(await picture(changedPixels: 51), golden),
      throwsA(isA<FlutterError>()),
    );
    expect(
      File.fromUri(
        directory.uri.resolve('failures/reference_isolatedDiff.png'),
      ).existsSync(),
      isTrue,
    );
  });

  test('rounding cannot hide changes above the pixel budget', () async {
    await expectLater(
      comparator.compare(
        await picture(background: 0xff828282, changedPixels: 51),
        golden,
      ),
      throwsA(isA<FlutterError>()),
    );
  });

  test('different image dimensions fail', () async {
    await expectLater(
      comparator.compare(await picture(width: 101), golden),
      throwsA(isA<FlutterError>()),
    );
    await expectLater(
      comparator.compare(await picture(height: 101), golden),
      throwsA(isA<FlutterError>()),
    );
  });
}
