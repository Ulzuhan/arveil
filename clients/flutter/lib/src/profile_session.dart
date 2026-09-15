import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'profile_keys.dart';
import 'profile_location.dart';
import 'rust/api/profile.dart';

class ProfileAccessException implements Exception {
  const ProfileAccessException(this.message);
  final String message;
}

Future<Profile> openDeviceProfile() async {
  final directory = await ProfileLocation.ensure();
  final key = await ProfileKeys().forProfile(
    profileExists: await hasProfile(dir: directory.path),
  );
  if (key.state == KeyState.unavailable) {
    throw const ProfileAccessException(
      'El almacén seguro del dispositivo no está disponible. '
      'Comprueba los permisos y la firma de la aplicación.',
    );
  }
  if (key.state == KeyState.missing) {
    throw const ProfileAccessException(
      'Falta la clave de este perfil. No se puede abrir su historial local. '
      'Conserva el perfil hasta recuperar la clave.',
    );
  }
  return openProfile(dir: directory.path, key: key.value!);
}

// Only presentation state lives here. Rust owns identity, enrollment progress
// and the database. Neither invitation tokens nor profile keys are retained.
class ProfileSession extends ChangeNotifier {
  ProfileSession({Future<Profile> Function()? opener})
    : _opener = opener ?? openDeviceProfile;

  final Future<Profile> Function() _opener;
  Profile? _profile;
  SetupView? setup;
  List<ConversationView>? conversations;
  bool busy = false;
  bool _disposed = false;
  String? error;

  bool get isOpen => _profile != null;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (busy || _disposed) return false;
    busy = true;
    error = null;
    _changed();
    try {
      await action();
      return true;
    } catch (failure) {
      error = describeFailure(failure);
      return false;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<bool> open() => _run(() async {
    if (_profile != null) return;
    final profile = await _opener();
    var adopted = false;
    try {
      final state = await profile.setup();
      if (_disposed) return;
      _profile = profile;
      setup = state;
      adopted = true;
    } finally {
      if (!adopted) await profile.close();
    }
  });

  Future<bool> enroll(String bootstrap, String invite) => _run(() async {
    final profile = _profile!;
    try {
      await profile.enroll(bootstrap: bootstrap, invite: invite);
    } finally {
      // Refresh even on a lost reply. Never infer durable progress from a
      // widget or roll it back because the last network request failed.
      try {
        setup = await profile.setup();
      } catch (_) {
        // A failed query must not hide the original command failure.
        setup = null;
      }
    }
    if (setup == null) {
      throw const ProfileAccessException(
        'El alta terminó, pero no se pudo leer el perfil. Ciérralo y vuelve a abrirlo.',
      );
    }
  });

  Future<bool> refresh() => _run(() async {
    setup = await _profile!.setup();
    conversations = await _profile!.conversations();
  });

  Future<bool> close() => _run(() async {
    await _profile?.close();
    _profile = null;
    setup = null;
    conversations = null;
  });

  @override
  void dispose() {
    _disposed = true;
    final profile = _profile;
    _profile = null;
    if (profile != null) unawaited(profile.close().catchError((Object _) {}));
    super.dispose();
  }
}

// Public-facing messages never interpolate paths, tokens, SQL or remote text.
String describeFailure(Object failure) => switch (failure) {
  ProfileAccessException(:final message) => message,
  ProfileError_BadKey() => 'La clave del perfil no tiene un formato válido.',
  ProfileError_NoRandomness() => 'El sistema no pudo generar una clave segura.',
  ProfileError_AlreadyOpen() || ProfileError_InUse() =>
    'El perfil está abierto en otra sesión. Ciérrala e inténtalo de nuevo.',
  ProfileError_Closing() =>
    'El perfil aún se está cerrando. Vuelve a intentarlo.',
  ProfileError_Unusable() =>
    'No se pudo descifrar el perfil. Conserva los datos y comprueba su clave.',
  ProfileError_Io() || FileSystemException() =>
    'No se pudo acceder al perfil. Comprueba el espacio y los permisos del dispositivo.',
  PlatformException() =>
    'No se pudo preparar el almacenamiento seguro del perfil. Vuelve a intentarlo.',
  CommandError_Transport() =>
    'No se pudo conectar con el relay. Comprueba la conexión y reintenta con la misma invitación.',
  CommandError_Domain() =>
    'Comprueba los datos de alta. Si ya empezaste, usa el mismo relay y la misma invitación.',
  CommandError_Protocol() =>
    'El relay no aceptó el alta. Comprueba la invitación con su administrador y vuelve a intentarlo.',
  CommandError_Busy() =>
    'Hay otra operación en curso. Espera y vuelve a intentarlo.',
  CommandError_Storage() || CommandError_FileSystem() =>
    'No se pudo guardar el avance. Comprueba el almacenamiento y vuelve a intentarlo.',
  CommandError_Interrupted() =>
    'La operación se interrumpió. Puedes volver a intentarlo.',
  _ =>
    'No se pudo completar la operación. Cierra el perfil y vuelve a abrirlo.',
};
