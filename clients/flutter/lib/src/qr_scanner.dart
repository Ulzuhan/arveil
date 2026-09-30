import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'design/design.dart';
import 'rust/api/profile.dart';

/// Whether this device can scan codes. Only Android does (ADR-012 §6): the
/// Mac shows codes and receives links instead.
bool get canScan => Platform.isAndroid;

/// Opens the camera, reads codes in the core, and returns the text of the
/// first one [accept] takes. The camera is asked for here, after the person
/// tapped "Scan", and never before. Returns null when they go back.
Future<String?> scanCode(
  BuildContext context, {
  required Profile profile,
  required bool Function(CardView card) accept,
  required String wrongCode,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) =>
        QrScannerPage(profile: profile, accept: accept, wrongCode: wrongCode),
  ),
);

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({
    super.key,
    required this.profile,
    required this.accept,
    required this.wrongCode,
  });
  final Profile profile;
  final bool Function(CardView card) accept;

  /// Said when a readable Arveil code is not the one this screen wants.
  final String wrongCode;

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

enum _CameraState { starting, ready, denied, unavailable }

class _QrScannerPageState extends State<QrScannerPage> {
  CameraController? _camera;
  _CameraState _state = _CameraState.starting;
  bool _reading = false;
  bool _done = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  String? _notice;
  int _generation = 0;
  int _readFailures = 0;
  Future<void> _released = Future.value();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onInactive: _pause,
      onResume: () => unawaited(_start()),
    );
    unawaited(_start());
  }

  Future<void> _start() async {
    final generation = ++_generation;
    bool current() => mounted && generation == _generation && !_done;
    try {
      await _released;
      if (!current()) return;
      final cameras = await availableCameras();
      if (!current()) return;
      if (cameras.isEmpty) {
        _set(_CameraState.unavailable);
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final camera = CameraController(
        back,
        // Linking cards carry keys and are dense. A 480p preview loses too
        // many modules when the whole code fits in the camera view.
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      _camera = camera;
      await camera.initialize();
      if (!current()) return;
      try {
        await camera.setFocusMode(FocusMode.auto);
      } on CameraException catch (_) {
        // Fixed-focus cameras can still scan.
      }
      if (!current()) return;
      await camera.startImageStream((image) => _frame(image, generation));
      if (!current()) return;
      _notice = null;
      _readFailures = 0;
      _set(_CameraState.ready);
    } on CameraException catch (e) {
      if (!current()) return;
      _pause();
      _set(
        e.code.contains('Denied') || e.code.contains('denied')
            ? _CameraState.denied
            : _CameraState.unavailable,
      );
    } catch (_) {
      if (!current()) return;
      _pause();
      _set(_CameraState.unavailable);
    }
  }

  void _pause() {
    ++_generation;
    _reading = false;
    final camera = _camera;
    _camera = null;
    if (camera != null) {
      _released = _released.then((_) => _release(camera));
    }
    _set(_CameraState.starting);
  }

  Future<void> _release(CameraController camera) async {
    try {
      if (camera.value.isStreamingImages) await camera.stopImageStream();
    } catch (_) {}
    try {
      await camera.dispose();
    } catch (_) {
      // The platform may already have closed an unavailable camera.
    }
  }

  void _set(_CameraState state) {
    if (mounted) setState(() => _state = state);
  }

  /// One frame at a time, a few times a second: the luminance plane is all
  /// a QR code needs, and it is read in the core, on a worker.
  void _frame(CameraImage image, int generation) {
    final now = DateTime.now();
    if (!mounted ||
        generation != _generation ||
        image.planes.isEmpty ||
        _reading ||
        _done ||
        now.difference(_lastFrame) < const Duration(milliseconds: 150)) {
      return;
    }
    _reading = true;
    _lastFrame = now;
    final luma = image.planes.first;
    unawaited(
      widget.profile
          .scanFrame(
            width: image.width,
            height: image.height,
            rowStride: luma.bytesPerRow,
            luma: luma.bytes,
          )
          .then((texts) async {
            if (!mounted || generation != _generation) return;
            _readFailures = 0;
            await _found(texts, generation);
          })
          .catchError((Object _) {
            if (!mounted || generation != _generation) return;
            if (++_readFailures >= 3) {
              _pause();
              _notice = context.l10n.scanReadFailed;
              _set(_CameraState.unavailable);
            }
          })
          .whenComplete(() {
            if (generation == _generation) _reading = false;
          }),
    );
  }

  Future<void> _found(List<String> texts, int generation) async {
    for (final text in texts) {
      if (!mounted || _done || generation != _generation) return;
      try {
        final card = await widget.profile.readCard(text: text);
        if (!mounted || generation != _generation) return;
        if (widget.accept(card)) {
          _done = true;
          if (mounted) Navigator.of(context).pop(text);
          return;
        }
        if (mounted) setState(() => _notice = widget.wrongCode);
      } catch (_) {
        // Not an Arveil code: keep looking.
      }
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    // Release without setting state while the widget is being disposed.
    ++_generation;
    final camera = _camera;
    if (camera != null) unawaited(_released.then((_) => _release(camera)));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final camera = _camera;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.scanTitle)),
      body: switch (_state) {
        _CameraState.starting => const Center(
          child: CircularProgressIndicator(),
        ),
        _CameraState.denied || _CameraState.unavailable => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _state == _CameraState.denied
                    ? l10n.scanDenied
                    : (_notice ?? l10n.scanUnavailable),
                key: const Key('scan-problem'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.scanPasteInstead),
              ),
            ],
          ),
        ),
        _CameraState.ready => SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (camera != null) Center(child: CameraPreview(camera)),
                    Center(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: DecoratedBox(
                            key: const Key('scan-guide'),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: ArveilColors.dark.ink,
                                width: 3,
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: double.infinity,
                color: ArveilColors.of(context).surface,
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const LinearProgressIndicator(key: Key('scan-active')),
                    const SizedBox(height: 12),
                    Text(
                      l10n.scanSearching,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _notice ?? l10n.scanHint,
                      key: const Key('scan-hint'),
                      textAlign: TextAlign.center,
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.scanPasteInstead),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      },
    );
  }
}
