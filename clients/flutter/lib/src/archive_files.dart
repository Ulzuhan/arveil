import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

/// Only encrypted bytes cross the archive selectors. The secret travels separately.
class ArchiveFiles {
  const ArchiveFiles();
  static const maximumBytes = 64 * 1024 * 1024;

  Future<bool> save(Uint8List encrypted) async =>
      await FilePicker.saveFile(
        dialogTitle: 'Guardar historial cifrado',
        fileName: 'arveil-history.age',
        bytes: encrypted,
      ) !=
      null;

  Future<Uint8List?> open() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Abrir historial cifrado',
    );
    if (file == null) return null;
    if ((await file.length() ?? 0) > maximumBytes) {
      throw const FormatException('El archivo supera 64 MiB.');
    }
    return readBoundedArchive(file.readAsByteStream());
  }
}

Future<Uint8List> readBoundedArchive(Stream<List<int>> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (chunk.length > ArchiveFiles.maximumBytes - bytes.length) {
      throw const FormatException('El archivo supera 64 MiB.');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
