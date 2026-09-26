import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../l10n/l10n.dart';
import 'profile_session.dart';

/// Only the encrypted kit crosses a native file dialog. Its secret is shown
/// separately and never included in file names, clipboard writes or logs.
class KitFiles {
  const KitFiles();
  static const maximumBytes = 4 * 1024 * 1024;

  Future<bool> save(List<int> encrypted) async =>
      await FilePicker.saveFile(
        dialogTitle: currentStrings.dialogSaveKit,
        fileName: 'arveil-identity.age',
        bytes: Uint8List.fromList(encrypted),
      ) !=
      null;

  Future<Uint8List?> open() async {
    final file = await FilePicker.pickFile(
      dialogTitle: currentStrings.dialogOpenKit,
    );
    if (file == null) return null;
    final size = await file.length();
    if (size != null && size > maximumBytes) {
      throw ProfileAccessException(currentStrings.kitTooLarge);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw ProfileAccessException(currentStrings.kitTooLarge);
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
