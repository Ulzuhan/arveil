import 'dart:async';
import 'dart:typed_data';

import 'package:arveil/l10n/l10n.dart';
import 'package:arveil/src/design/theme.dart';
import 'package:arveil/src/qr_scanner.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeProfile;

class ScanProfile extends FakeProfile {
  final frames = <(int, int, int, List<int>)>[];
  List<String> codes = [];
  bool fail = false;
  @override
  Future<List<String>> scanFrame({
    required int width,
    required int height,
    required int rowStride,
    required List<int> luma,
  }) async {
    frames.add((width, height, rowStride, luma));
    if (fail) throw StateError('decoder unavailable');
    return codes;
  }

  @override
  Future<CardView> readCard({required String text}) async =>
      CardView.link(server: 'wss://relay.example.org', expiresAt: BigInt.zero);
}

class TestCamera extends CameraPlatform {
  final frames = StreamController<CameraImageData>.broadcast();
  final errors = StreamController<CameraErrorEvent>.broadcast();
  MediaSettings? settings;
  int created = 0;
  int released = 0;
  @override
  Future<List<CameraDescription>> availableCameras() async => [
    const CameraDescription(
      name: 'back',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
  ];
  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async {
    settings = mediaSettings;
    return ++created;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          1920,
          1080,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => errors.stream;
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();
  @override
  bool supportsImageStreaming() => true;
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) => frames.stream;
  @override
  Future<void> setFocusMode(int cameraId, FocusMode mode) async {}
  @override
  Future<void> dispose(int cameraId) async {
    released++;
  }

  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Colors.black);

  void frame() => frames.add(
    CameraImageData(
      format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
      width: 2,
      height: 2,
      planes: [
        CameraImagePlane(
          bytes: Uint8List.fromList([1, 2, 99, 3, 4, 99]),
          bytesPerRow: 3,
          bytesPerPixel: 1,
        ),
      ],
    ),
  );
}

void main() {
  late CameraPlatform original;
  late TestCamera camera;
  late ScanProfile profile;
  setUp(() {
    original = CameraPlatform.instance;
    CameraPlatform.instance = camera = TestCamera();
    profile = ScanProfile();
  });
  tearDown(() => CameraPlatform.instance = original);

  Future<void> open(
    WidgetTester tester, {
    void Function(String?)? result,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        theme: ArveilTheme.dark(),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result?.call(
              await scanCode(
                context,
                profile: profile,
                accept: (card) => card is CardView_Link,
                wrongCode: 'Otro código',
              ),
            ),
            child: const Text('Scan'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'shows scan feedback, forwards padded frames and returns a read code',
    (tester) async {
      String? result;
      await open(tester, result: (text) => result = text);
      expect(find.byKey(const Key('scan-guide')), findsOneWidget);
      expect(find.text('Buscando el código…'), findsOneWidget);
      expect(camera.settings!.resolutionPreset, ResolutionPreset.veryHigh);
      expect(camera.settings!.enableAudio, isFalse);
      profile.codes = ['arveil://link#test'];
      camera.frame();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final frame = profile.frames.single;
      expect((frame.$1, frame.$2, frame.$3), (2, 2, 3));
      expect(frame.$4, [1, 2, 99, 3, 4, 99]);
      expect(result, 'arveil://link#test');
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(camera.released, 1);
    },
  );

  testWidgets('releases the camera in the background and opens it on return', (
    tester,
  ) async {
    await open(tester, result: (_) {});
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('scan-active')), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(camera.released, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(camera.created, 2);
    expect(find.byKey(const Key('scan-active')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(camera.released, 2);
  });

  testWidgets(
    'reports repeated decoder failures instead of silently showing the camera',
    (tester) async {
      await open(tester, result: (_) {});
      profile.fail = true;
      for (var i = 0; i < 3; i++) {
        camera.frame();
        await tester.pump();
        // The scanner deliberately throttles camera frames using the clock.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 160)),
        );
      }
      await tester.pump();
      expect(find.byKey(const Key('scan-problem')), findsOneWidget);
      expect(find.textContaining('No se pudo leer la imagen'), findsOneWidget);
      expect(camera.released, 1);
    },
  );
}
