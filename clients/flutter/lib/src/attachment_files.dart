import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const maximumAttachmentBytes = 25 * 1024 * 1024 - 16;

class PickedAttachment {
  const PickedAttachment(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

String safeAttachmentName(String name) {
  final base = name
      .split(RegExp(r'[/\\]'))
      .last
      .replaceFirst(RegExp(r'^\.+'), '')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '');
  final result = String.fromCharCodes(base.runes.take(120));
  return result.isEmpty ? 'file' : result;
}

/// Native selectors own access to the chosen source/destination. Neither URI
/// nor local path is passed to Rust or retained with the conversation.
class AttachmentFiles {
  const AttachmentFiles();
  static const _android = MethodChannel('io.github.ulzuhan.arveil/attachments');

  Future<PickedAttachment?> open() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      // The general picker plugin caches Android sources before returning.
      // Our channel reads the selected content URI directly into bounded memory.
      final picked = await _android.invokeMapMethod<String, Object?>('pick');
      if (picked == null) return null;
      final bytes = picked['bytes'] as Uint8List;
      if (bytes.length > maximumAttachmentBytes) {
        throw const FormatException('El archivo debe ocupar menos de 25 MiB.');
      }
      return PickedAttachment(
        safeAttachmentName(picked['name'] as String),
        bytes,
      );
    }
    final file = await FilePicker.pickFile(dialogTitle: 'Elegir archivo');
    if (file == null) return null;
    if ((file.lengthSync() ?? 0) > maximumAttachmentBytes) {
      throw const FormatException('El archivo debe ocupar menos de 25 MiB.');
    }
    return PickedAttachment(
      safeAttachmentName(file.name),
      await readBoundedAttachment(file.readAsByteStream()),
    );
  }

  Future<bool> save(String name, Uint8List bytes) async =>
      await FilePicker.saveFile(
        dialogTitle: 'Guardar copia del archivo',
        fileName: safeAttachmentName(name),
        bytes: bytes,
      ) !=
      null;
}

Future<Uint8List> readBoundedAttachment(Stream<List<int>> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (chunk.length > maximumAttachmentBytes - bytes.length) {
      throw const FormatException('El archivo debe ocupar menos de 25 MiB.');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
