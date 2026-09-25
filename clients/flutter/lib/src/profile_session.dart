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
      'Desbloquea el dispositivo y comprueba el permiso de acceso al almacén seguro.',
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
  bool waitingForPairing = false;
  bool cancellingPairing = false;
  bool _cancelledWait = false;
  String? approvalCode;
  KeyPackageSupplyView? keyPackages;
  bool keyPackagesUnavailable = false;

  Profile? get profile => _profile;

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
      if (!_cancelledWait) error = describeFailure(failure);
      return false;
    } finally {
      _cancelledWait = false;
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
      await _loadKeyPackages();
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
        await _loadKeyPackages();
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

  Future<void> _reloadAfter(Future<void> Function(Profile) command) async {
    final profile = _profile!;
    try {
      await command(profile);
    } finally {
      try {
        setup = await profile.setup();
        await _loadKeyPackages();
      } catch (_) {
        setup = null;
      }
    }
    if (setup == null) {
      throw const ProfileAccessException(
        'La operación terminó, pero no se pudo leer el perfil. Ciérralo y vuelve a abrirlo.',
      );
    }
  }

  Future<void> _loadKeyPackages() async {
    if (setup?.stage != SetupStage.ready || _profile == null) {
      keyPackages = null;
      return;
    }
    try {
      keyPackages = await _profile!.keyPackageSupply();
    } catch (_) {
      keyPackages = null;
    }
  }

  Future<bool> checkKeyPackages({bool replenish = false}) => _run(() async {
    keyPackagesUnavailable = false;
    try {
      keyPackages = replenish
          ? await _profile!.replenishKeyPackages()
          : await _profile!.checkKeyPackages();
    } catch (_) {
      // Persisted pending publication and the last dated report survive a
      // failed request. Never replace an unknown count with zero.
      keyPackagesUnavailable = true;
      await _loadKeyPackages();
      rethrow;
    }
  });

  Future<bool> beginPairing(String bootstrap) => _run(() async {
    _cancelledWait = false;
    await _reloadAfter((p) => p.beginPairing(bootstrap: bootstrap));
  });

  Future<bool> waitForPairing() => _run(() async {
    final state = setup!;
    waitingForPairing = true;
    _changed();
    try {
      await _reloadAfter(
        (p) => p.awaitPairing(
          bootstrap: state.bootstrap!,
          session: state.pairing!,
        ),
      );
    } finally {
      waitingForPairing = false;
    }
  });

  Future<bool> confirmPairing(String code) => _run(() async {
    _cancelledWait = false;
    final state = setup!;
    await _reloadAfter(
      (p) => p.confirmPairing(
        bootstrap: state.bootstrap!,
        sessionId: state.pairing!.sessionId,
        verificationCode: code,
      ),
    );
  });

  // Cancellation must be able to enter Rust while the rendezvous wait is
  // suspended. It does not promise to undo a confirmation that committed.
  Future<bool> cancelPairing() async {
    final state = setup;
    if (_disposed ||
        cancellingPairing ||
        state?.pairing == null ||
        (busy && !waitingForPairing)) {
      return false;
    }
    cancellingPairing = true;
    _changed();
    try {
      final cancelled = await _profile!.cancelPairing(
        sessionId: state!.pairing!.sessionId,
      );
      _cancelledWait = cancelled && waitingForPairing;
      setup = await _profile!.setup();
      error = cancelled
          ? null
          : 'La confirmación ya empezó. Reanuda la finalización de la vinculación.';
      return cancelled;
    } catch (failure) {
      error = describeFailure(failure);
      return false;
    } finally {
      cancellingPairing = false;
      _changed();
    }
  }

  Future<bool> approvePairing(String code) => _run(() async {
    _cancelledWait = false;
    approvalCode = await _profile!.approvePairing(
      bootstrap: setup!.bootstrap!,
      code: code,
    );
  });

  void dismissApproval() {
    approvalCode = null;
    _changed();
  }

  Future<String?> saveKit(Future<bool> Function(List<int>) save) async {
    String? secret;
    await _run(() async {
      _cancelledWait = false;
      final kit = await _profile!.exportKit();
      if (await save(kit.encrypted) && !_disposed) secret = kit.secret;
    });
    return secret;
  }

  Future<bool> restoreKit(
    String bootstrap,
    List<int> encrypted,
    String secret,
  ) => _run(() async {
    _cancelledWait = false;
    await _reloadAfter(
      (p) => p.restoreKit(
        bootstrap: bootstrap,
        encrypted: encrypted,
        secret: secret,
      ),
    );
  });

  Future<bool> resumeRecovery() => _run(() async {
    _cancelledWait = false;
    await _reloadAfter((p) => p.resumeRecovery());
  });

  void reportFailure(Object failure) {
    error = describeFailure(failure);
    _changed();
  }

  Future<bool> refresh() => _run(() async {
    _cancelledWait = false;
    setup = await _profile!.setup();
    if (setup!.stage == SetupStage.ready) {
      conversations = await _profile!.conversations();
    }
  });

  Future<bool> close() => _run(() async {
    await _profile?.close();
    _profile = null;
    setup = null;
    conversations = null;
    keyPackages = null;
    keyPackagesUnavailable = false;
    approvalCode = null;
    _cancelledWait = false;
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
  ProfileError_TooNew() =>
    'Una versión más reciente de Arveil guardó este perfil. Actualiza la app para abrirlo; el perfil no se ha modificado.',
  ProfileError_Unusable() =>
    'No se pudo descifrar el perfil. Conserva los datos y comprueba su clave.',
  ProfileError_Io() || FileSystemException() =>
    'No se pudo acceder al perfil. Comprueba el espacio y los permisos del dispositivo.',
  PlatformException() =>
    'No se pudo preparar el almacenamiento seguro del perfil. Vuelve a intentarlo.',
  CommandError_Transport() =>
    'No se pudo conectar con el relay. Comprueba la conexión y sigue las indicaciones de la operación pendiente.',
  CommandError_Domain() =>
    'Revisa los datos y la vigencia de la operación. Conserva el perfil; no empieces un alta diferente para reintentar.',
  CommandError_Protocol() =>
    'El relay no aceptó la operación. Comprueba los datos con su administrador; una recuperación puede necesitar un kit más reciente.',
  CommandError_Busy() =>
    'Hay otra operación en curso. Espera y vuelve a intentarlo.',
  CommandError_Storage() || CommandError_FileSystem() =>
    'No se pudo guardar el avance. Comprueba el almacenamiento y vuelve a intentarlo.',
  CommandError_Interrupted() =>
    'La operación se interrumpió. Puedes volver a intentarlo.',
  _ =>
    'No se pudo completar la operación. Cierra el perfil y vuelve a abrirlo.',
};
