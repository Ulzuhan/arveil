import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'attachment_files.dart';

// Deliberately excludes document/web formats and animated playback. The first
// image frame is decoded into a bounded, privately owned image, never ImageCache.
bool isPreviewImage(Uint8List bytes) {
  bool starts(List<int> signature, [int offset = 0]) =>
      bytes.length >= offset + signature.length &&
      Iterable<int>.generate(
        signature.length,
      ).every((i) => bytes[offset + i] == signature[i]);
  return starts([137, 80, 78, 71, 13, 10, 26, 10]) ||
      starts([255, 216, 255]) ||
      (starts([82, 73, 70, 70]) && starts([87, 69, 66, 80], 8));
}

/// Encoded bytes remain bounded by the attachment limit. Pixel limits are
/// separate: a small compressed image must not allocate arbitrary decoded RAM.
({int width, int height}) previewDimensions(int width, int height) {
  if (width <= 0 ||
      height <= 0 ||
      width > 16384 ||
      height > 16384 ||
      width * height > 64000000) {
    throw const FormatException('Image dimensions exceed the preview limit.');
  }
  final scale = math.min(
    1.0,
    math.min(
      4096 / math.max(width, height),
      math.sqrt(4000000 / (width * height)),
    ),
  );
  return (
    width: math.max(1, (width * scale).floor()),
    height: math.max(1, (height * scale).floor()),
  );
}

Future<ui.Image> decodeAttachmentImage(Uint8List bytes) async {
  if (bytes.length > maximumAttachmentBytes || !isPreviewImage(bytes)) {
    throw const FormatException('Unsupported image.');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = previewDimensions(descriptor.width, descriptor.height);
    codec = await descriptor.instantiateCodec(
      targetWidth: size.width,
      targetHeight: size.height,
    );
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// Only authenticated local bytes reach this route. It performs no downloads
/// and writes nothing unless the person explicitly exports or opens externally.
class AttachmentViewer extends StatefulWidget {
  const AttachmentViewer({
    super.key,
    required this.name,
    required this.bytes,
    required this.files,
  });
  final String name;
  final Uint8List bytes;
  final AttachmentFiles files;

  @override
  State<AttachmentViewer> createState() => _AttachmentViewerState();
}

class _AttachmentViewerState extends State<AttachmentViewer> {
  ui.Image? _image;
  late bool _loading = isPreviewImage(widget.bytes);
  bool _failed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_loading) _decode();
  }

  Future<void> _decode() async {
    try {
      final image = await decodeAttachmentImage(widget.bytes);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image = image;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  Future<void> _share({required bool external}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = context.l10n;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(external ? s.attachmentOpenExternal : s.exportTitle),
          content: Text(external ? s.attachmentOpenWarning : s.exportWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(s.cancel),
            ),
            FilledButton(
              key: const Key('confirm-file-share'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(external ? s.attachmentOpenExternal : s.exportChoose),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      final success = external
          ? await widget.files.openExternal(widget.name, widget.bytes)
          : await widget.files.save(widget.name, widget.bytes);
      if (!mounted) return;
      if (external && !success) {
        setState(() => _error = s.attachmentNoViewer);
      } else if (!external && success) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(s.exportSaved)));
      }
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.attachmentOpenFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _loading
                  ? Center(
                      child: CircularProgressIndicator(
                        semanticsLabel: s.reading,
                      ),
                    )
                  : _image != null
                  ? Semantics(
                      label: widget.name,
                      image: true,
                      child: InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 8,
                        child: Center(
                          child: RawImage(
                            key: const Key('attachment-image'),
                            image: _image,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.insert_drive_file_outlined,
                              size: 64,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _failed
                                  ? s.attachmentPreviewFailed
                                  : s.attachmentExternalPreview,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const Key('open-file-external'),
                    onPressed: _busy ? null : () => _share(external: true),
                    icon: const Icon(Icons.open_in_new),
                    label: Text(s.attachmentOpenExternal),
                  ),
                  OutlinedButton.icon(
                    key: const Key('save-viewed-file'),
                    onPressed: _busy ? null : () => _share(external: false),
                    icon: const Icon(Icons.save_alt),
                    label: Text(s.attachmentSaveCopy),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
