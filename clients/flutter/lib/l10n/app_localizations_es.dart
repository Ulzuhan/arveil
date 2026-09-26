// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Arveil';

  @override
  String get navChats => 'Chats';

  @override
  String get navContacts => 'Contactos';

  @override
  String get navSettings => 'Ajustes';

  @override
  String get updatesTitle => 'Actualizaciones';

  @override
  String get updatesExplanation =>
      'Actualiza Arveil conservando tu perfil y tus conversaciones. Android te pedirá confirmar la instalación; no desinstales la app.';

  @override
  String get updatesPrivacy =>
      'La consulta contacta con el servicio de actualizaciones de esta distribución, independientemente de tu servidor. Ese servicio ve tu IP y la hora, pero no recibe tu identidad ni tu versión instalada. La descarga contacta con el alojamiento del APK.';

  @override
  String get updatesUnconfigured =>
      'Esta compilación no tiene un canal de actualizaciones configurado. Obtén la siguiente versión del distribuidor que te proporcionó la app e instálala encima de esta.';

  @override
  String get updatesAutomatic => 'Buscar al abrir la app';

  @override
  String get updatesAutomaticDetail =>
      'Como máximo una vez al día. Desactivado inicialmente; nunca instala por su cuenta.';

  @override
  String get updatesCheck => 'Buscar actualizaciones';

  @override
  String get updatesChecking => 'Buscando actualizaciones…';

  @override
  String get updatesCurrent => 'No hay una versión más reciente en este canal.';

  @override
  String get updatesAvailable => 'Hay una actualización de Arveil';

  @override
  String get updatesView => 'Ver';

  @override
  String get updatesIncompatible =>
      'Hay una versión más reciente, pero no es compatible con este dispositivo.';

  @override
  String updatesVersion(String version) {
    return 'Arveil $version';
  }

  @override
  String updatesSize(String size) {
    return 'Descarga: $size MiB';
  }

  @override
  String get updatesDownload => 'Descargar actualización';

  @override
  String get updatesDownloading => 'Descargando y verificando…';

  @override
  String get updatesCancelDownload => 'Cancelar descarga';

  @override
  String get updatesReady =>
      'Descarga verificada. Puedes continuar con el instalador de Android.';

  @override
  String get updatesPermission =>
      'Android necesita que permitas a Arveil instalar actualizaciones. Activa el permiso, vuelve aquí y pulsa «Instalar actualización».';

  @override
  String get updatesAllowInstall => 'Abrir permiso de Android';

  @override
  String get updatesInstall => 'Instalar actualización';

  @override
  String get updatesInstalling =>
      'Confirma la actualización en Android. La app se cerrará al actualizarse.';

  @override
  String get updatesCancelled =>
      'Instalación cancelada. Puedes volver a intentarlo.';

  @override
  String get updatesErrorSignature =>
      'No se pudo verificar el anuncio de actualización. No se ha aceptado ningún paquete.';

  @override
  String get updatesErrorExpired =>
      'El anuncio de actualización ha caducado. Comprueba la fecha del dispositivo y vuelve a buscar actualizaciones.';

  @override
  String get updatesErrorRollback =>
      'El servicio devolvió un anuncio anterior o contradictorio. Se ha rechazado.';

  @override
  String get updatesErrorState =>
      'No se pudo leer o guardar el estado de seguridad del actualizador. Conserva los datos de la app y contacta con quien te la proporcionó.';

  @override
  String get updatesErrorPackage =>
      'El paquete no coincide con la actualización esperada o con la firma de esta app. No se instalará.';

  @override
  String get updatesErrorInstall =>
      'Android no pudo completar la actualización. Conserva la app instalada y vuelve a intentarlo.';

  @override
  String get updatesErrorNetwork =>
      'No se pudo completar la consulta o la descarga. Comprueba la conexión y el espacio disponible y vuelve a intentarlo.';

  @override
  String get updatesErrorFormat =>
      'El servicio de actualizaciones envió un anuncio que esta app no puede leer. No se ha aceptado nada.';

  @override
  String get updatesErrorChannel =>
      'El anuncio es de un canal de actualizaciones distinto del de esta app. Se ha rechazado.';

  @override
  String get updatesErrorStorage =>
      'Android no pudo preparar la instalación. Libera espacio y vuelve a intentarlo; la descarga se conserva.';

  @override
  String get updatesErrorBrowser =>
      'Ninguna app pudo abrir el enlace a las notas de la versión.';

  @override
  String updatesNotesLink(String host) {
    return 'Notas de la versión en $host';
  }

  @override
  String get profileClose => 'Cerrar perfil';

  @override
  String get profileStateUnreadable => 'No se pudo leer el estado del perfil.';

  @override
  String get profileReadAgain => 'Volver a leer';

  @override
  String get enrollBack => 'Volver al alta';

  @override
  String get operationInProgress => 'Operación en curso';

  @override
  String get operationInProgressDetail =>
      'Operación en curso. El avance confirmado queda guardado en el perfil.';

  @override
  String get welcomeTitle => 'Tu identidad, en este dispositivo';

  @override
  String get welcomeBody =>
      'Abre tu perfil o prepara uno nuevo para unirte con una invitación.';

  @override
  String get welcomeKeyNote =>
      'El perfil se cifra con una clave guardada en el almacén seguro del dispositivo. Si pierdes esa clave, no podrás recuperar el historial local.';

  @override
  String get profileOpen => 'Abrir perfil';

  @override
  String get enrollTitleRetry => 'Retoma tu alta';

  @override
  String get enrollBodyRetry =>
      'Tu avance está guardado. Usa la misma invitación para continuar con tu identidad.';

  @override
  String get enrollBody =>
      'Pide al administrador los datos del servidor y una invitación. Tu identidad se crea en este dispositivo al continuar.';

  @override
  String get setupRedeeming => 'Pendiente de confirmar la invitación.';

  @override
  String get setupRedeemed =>
      'Invitación aceptada. Falta recibir la configuración.';

  @override
  String get setupPublishing =>
      'Configuración recibida. Falta terminar el buzón y las claves de mensajería.';

  @override
  String get setupIdentityReady => 'Tu identidad local ya está creada.';

  @override
  String get setupNew => 'Listo para crear tu identidad.';

  @override
  String get enrollRelayLabel => 'Datos del servidor';

  @override
  String get enrollRelayInvalid => 'Pega los datos completos del servidor.';

  @override
  String get enrollInviteLabel => 'Invitación';

  @override
  String get enrollInviteHelper =>
      'No se guarda. Consérvala hasta completar el alta.';

  @override
  String get enrollInviteInvalid =>
      'La invitación debe contener 64 caracteres hexadecimales.';

  @override
  String get enrollRetry => 'Reintentar alta';

  @override
  String get enrollSubmit => 'Crear identidad y unirme';

  @override
  String get enrollPair => 'Vincular con mi otro dispositivo';

  @override
  String get enrollRestore => 'Restaurar desde un kit';

  @override
  String get kitReminderNever =>
      'Sin kit ni otro dispositivo vinculado, perder este dispositivo significa perder tu identidad.';

  @override
  String get kitReminderStale =>
      'Tus dispositivos cambiaron después de guardar el kit. Guarda uno nuevo para que una recuperación los conozca.';

  @override
  String get kitSave => 'Guardar kit';

  @override
  String get later => 'Más tarde';

  @override
  String get recoveryRollbackWarning =>
      'El servidor conocía un manifiesto anterior al de tu kit. Comprueba las revocaciones con un contacto o dispositivo superviviente antes de confiar en su estado.';

  @override
  String get manageDevices => 'Gestionar dispositivos';

  @override
  String get encryptedHistory => 'Historial cifrado';

  @override
  String get linkedDeviceKitNote =>
      'Este dispositivo está vinculado. El kit de identidad se exporta desde el dispositivo administrador.';

  @override
  String get errorSecureStorageUnavailable =>
      'El almacén seguro del dispositivo no está disponible. Desbloquea el dispositivo y comprueba el permiso de acceso al almacén seguro.';

  @override
  String get errorProfileKeyMissing =>
      'Falta la clave de este perfil. No se puede abrir su historial local. Conserva el perfil hasta recuperar la clave.';

  @override
  String get errorEnrollmentUnreadable =>
      'El alta terminó, pero no se pudo leer el perfil. Ciérralo y vuelve a abrirlo.';

  @override
  String get errorOperationUnreadable =>
      'La operación terminó, pero no se pudo leer el perfil. Ciérralo y vuelve a abrirlo.';

  @override
  String get pairingConfirmationStarted =>
      'La confirmación ya empezó. Reanuda la finalización de la vinculación.';

  @override
  String get errorBadKey => 'La clave del perfil no tiene un formato válido.';

  @override
  String get errorNoRandomness =>
      'El sistema no pudo generar una clave segura.';

  @override
  String get errorProfileInUse =>
      'El perfil está abierto en otra sesión. Ciérrala e inténtalo de nuevo.';

  @override
  String get errorProfileClosing =>
      'El perfil aún se está cerrando. Vuelve a intentarlo.';

  @override
  String get errorProfileTooNew =>
      'Una versión más reciente de Arveil guardó este perfil. Actualiza la app para abrirlo; el perfil no se ha modificado.';

  @override
  String get errorProfileUnusable =>
      'No se pudo descifrar el perfil. Conserva los datos y comprueba su clave.';

  @override
  String get errorProfileIo =>
      'No se pudo acceder al perfil. Comprueba el espacio y los permisos del dispositivo.';

  @override
  String get errorSecureStoragePrepare =>
      'No se pudo preparar el almacenamiento seguro del perfil. Vuelve a intentarlo.';

  @override
  String get errorTransport =>
      'No se pudo conectar con el servidor. Comprueba la conexión y sigue las indicaciones de la operación pendiente.';

  @override
  String get errorDomain =>
      'Revisa los datos y la vigencia de la operación. Conserva el perfil; no empieces un alta diferente para reintentar.';

  @override
  String get errorProtocol =>
      'El servidor no aceptó la operación. Comprueba los datos con su administrador; una recuperación puede necesitar un kit más reciente.';

  @override
  String get errorPairingQuota =>
      'El servidor está limitando los intentos de vinculación desde esta red. Espera unos minutos (hasta 10) antes de generar un código nuevo; reintentar antes no sirve.';

  @override
  String get errorQuota =>
      'El servidor alcanzó uno de sus límites y no aceptó la operación. Espera unos minutos antes de volver a intentarlo; si se repite, avisa a quien lo administra.';

  @override
  String get errorBusy =>
      'Hay otra operación en curso. Espera y vuelve a intentarlo.';

  @override
  String get errorStorage =>
      'No se pudo guardar el avance. Comprueba el almacenamiento y vuelve a intentarlo.';

  @override
  String get errorInterrupted =>
      'La operación se interrumpió. Puedes volver a intentarlo.';

  @override
  String get errorUnknown =>
      'No se pudo completar la operación. Cierra el perfil y vuelve a abrirlo.';

  @override
  String get syncWhenNow => 'ahora';

  @override
  String syncWhenMinutes(int minutes) {
    return 'hace $minutes min';
  }

  @override
  String syncWhenTime(String time) {
    return 'a las $time';
  }

  @override
  String syncLastSuffix(String when) {
    return ' · última sincronización $when';
  }

  @override
  String get syncNever => 'Aún sin sincronizar';

  @override
  String get syncSyncing => 'Sincronizando…';

  @override
  String syncSynced(String when) {
    return 'Sincronizado $when';
  }

  @override
  String syncOffline(String last) {
    return 'Sin conexión con tu servidor$last';
  }

  @override
  String syncRefused(String last) {
    return 'El servidor rechazó la sincronización$last';
  }

  @override
  String get chatErrorHistory =>
      'No se pudo leer el historial local. Conserva el perfil y vuelve a abrirlo.';

  @override
  String get chatErrorConversation =>
      'No se pudo leer esta conversación. Vuelve a intentarlo.';

  @override
  String get chatErrorOlder =>
      'No se pudieron leer los mensajes anteriores. Puedes reintentar.';

  @override
  String get chatSyncPending =>
      'Sincronización pendiente. Puedes leer y escribir sin conexión; usa Sincronizar para reintentar.';

  @override
  String get chatSyncRefused =>
      'El servidor no aceptó la sincronización. Tus mensajes siguen guardados en este dispositivo; comprueba los datos del servidor con quien lo administra.';

  @override
  String get chatMessageTooLong => 'Escribe un mensaje de hasta 32 KiB.';

  @override
  String get chatSavedRetrySync =>
      'Mensaje guardado. Reintenta la sincronización; no vuelvas a enviarlo.';

  @override
  String get chatSaveUnconfirmed =>
      'No se confirmó el guardado. Conserva el borrador y consulta el historial antes de reintentar.';

  @override
  String get chatFileSaveUnconfirmed =>
      'No se confirmó el guardado del archivo. Consulta el historial antes de volver a adjuntarlo.';

  @override
  String get chatTransferIncomplete =>
      'La operación no se completó. Consulta el estado del archivo: reanuda su transferencia o sincroniza si ya está preparado.';

  @override
  String get chatCancelFailed =>
      'No se pudo cancelar. La transferencia puede haber terminado; consulta su estado.';

  @override
  String get chatCreatedSyncPending =>
      'Conversación guardada. Sincroniza para completar el envío de la invitación; no la crees de nuevo.';

  @override
  String get chatCreateUnconfirmed =>
      'No se confirmó la creación. Comprueba las rutas, la conexión y que tus contactos tengan claves disponibles. Consulta la lista antes de reintentar.';

  @override
  String get dialogSaveHistory => 'Guardar historial cifrado';

  @override
  String get dialogOpenHistory => 'Abrir historial cifrado';

  @override
  String get dialogSaveKit => 'Guardar kit de identidad cifrado';

  @override
  String get dialogOpenKit => 'Abrir kit de identidad';

  @override
  String get kitTooLarge => 'El kit supera el tamaño máximo de 4 MiB.';

  @override
  String get dialogChooseFile => 'Elegir archivo';

  @override
  String get dialogSaveFileCopy => 'Guardar copia del archivo';

  @override
  String get recoveryIncomplete =>
      'Selecciona el kit, introduce su clave y los datos del servidor, y confirma las consecuencias de la recuperación.';

  @override
  String get kitTitle => 'Kit de identidad';

  @override
  String get kitExplanation =>
      'El kit recupera tu identidad, no el historial ni el estado de los grupos. Guarda el archivo cifrado y su clave por separado; juntos permiten tomar el control de la identidad.';

  @override
  String get kitRevealSavedKey => 'Mostrar clave del kit guardado';

  @override
  String get kitSavedKeyNow =>
      'Archivo guardado. Guarda ahora esta clave por separado, por ejemplo en tu gestor de contraseñas. Arveil no la conserva.';

  @override
  String get kitKeyDisappears =>
      'La clave desaparece al salir de esta pantalla o cambiar de aplicación. Si la pierdes, crea un kit nuevo.';

  @override
  String get kitKeySavedConfirm => 'He guardado la clave por separado';

  @override
  String get kitSavedByConfirmation =>
      'Kit y clave guardados según tu confirmación. Exporta uno nuevo después de cambiar tus dispositivos.';

  @override
  String get kitDeferredWarning =>
      'Kit pospuesto: perder el dispositivo administrador sin un kit puede impedir recuperar tu identidad.';

  @override
  String get kitSaveEncrypted => 'Guardar kit cifrado';

  @override
  String get kitPostpone => 'Posponer el kit';

  @override
  String get recoveryTitle => 'Recuperar mi identidad';

  @override
  String get recoveryExplanation =>
      'Usa el kit más reciente y su clave. Esta recuperación crea un dispositivo administrador nuevo y revoca los dispositivos anteriores incluidos en el manifiesto. El historial no se recupera; tendrás que incorporarte de nuevo a los grupos.';

  @override
  String get recoveryRelayLabel => 'Datos del servidor original';

  @override
  String get recoveryChooseKit => 'Seleccionar kit cifrado';

  @override
  String get recoveryKitChosen => 'Kit seleccionado: cambiar archivo';

  @override
  String get recoveryKitKey => 'Clave del kit';

  @override
  String get recoveryConsent =>
      'Entiendo que se revocarán los dispositivos anteriores y no se recuperará su historial.';

  @override
  String get recoveryRestore => 'Restaurar identidad y revocar dispositivos';

  @override
  String get recoveryResumeTitle => 'Continúa la recuperación';

  @override
  String get recoveryResumeBody =>
      'La identidad y las claves del nuevo dispositivo están guardadas. El servidor puede haber aceptado ya la revocación de los anteriores. Reanuda esta misma operación; no necesitas volver a abrir el kit ni crear otro perfil.';

  @override
  String get recoveryResume => 'Reanudar recuperación';

  @override
  String get keyPackagesTitle => 'Claves para grupos nuevos';

  @override
  String get keyPackagesExplanation =>
      'Este dispositivo publica claves de un solo uso para que otras personas puedan iniciar conversaciones con él. Las conversaciones existentes conservan sus propias claves.';

  @override
  String get keyPackagesUnknown => 'Disponibilidad sin comprobar';

  @override
  String get keyPackagesEmpty => 'Última consulta: sin claves disponibles';

  @override
  String get keyPackagesLow => 'Última consulta: quedan pocas claves';

  @override
  String get keyPackagesReady => 'Última consulta: claves disponibles';

  @override
  String keyPackagesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count claves disponibles según el servidor.',
      one: '1 clave disponible según el servidor.',
    );
    return '$_temp0';
  }

  @override
  String keyPackagesCheckedAt(String date, String time) {
    return 'Consultado el $date a las $time. Puede cambiar cuando otra persona use una clave.';
  }

  @override
  String get keyPackagesNoneWarning =>
      'Otros dispositivos no podrán iniciar nuevas conversaciones con este dispositivo hasta que haya claves disponibles.';

  @override
  String get keyPackagesReplenishSoon =>
      'Repón las claves antes de que se agoten.';

  @override
  String get keyPackagesPending =>
      'Hay una publicación pendiente de confirmar. Reanudar enviará el mismo lote guardado; no regenerará esas claves.';

  @override
  String get keyPackagesUnavailable =>
      'No se pudo actualizar la disponibilidad. El último dato guardado no confirma el estado actual.';

  @override
  String get keyPackagesCheck => 'Comprobar disponibilidad';

  @override
  String get keyPackagesResume => 'Reanudar publicación de claves';

  @override
  String get keyPackagesReplenish => 'Reponer claves';

  @override
  String get attachmentSavedPending =>
      'Guardado en este dispositivo · pendiente de envío';

  @override
  String get attachmentDownloadInterrupted => 'Descarga interrumpida';

  @override
  String get attachmentDownloadAwaiting =>
      'Descarga pendiente de tu autorización';

  @override
  String get attachmentTransferring => 'Transfiriendo…';

  @override
  String get attachmentTransferInterrupted =>
      'Transferencia interrumpida · puedes reanudar';

  @override
  String get attachmentDownloaded =>
      'Descargado y verificado · copia privada cifrada';

  @override
  String get deliveryNoRecipients =>
      'Guardado localmente · sin destinatarios disponibles';

  @override
  String get deliveryAccepted =>
      'Aceptado por el servidor · lectura sin confirmar';

  @override
  String get deliveryRejected => 'Algún buzón rechazó el mensaje';

  @override
  String get deliveryExpired => 'Entrega caducada o desconocida';

  @override
  String get attachmentReady =>
      'Archivo preparado · envío pendiente de sincronización';

  @override
  String get attachmentCancelled =>
      'Transferencia cancelada · copia incompleta eliminada';

  @override
  String get attachmentUnavailable =>
      'Archivo no disponible o acceso rechazado. Puedes reintentar o pedir otra copia.';

  @override
  String get attachmentExpiredOnRelay =>
      'Archivo caducado en el servidor. Pide que lo envíen de nuevo.';

  @override
  String get attachmentUnverified =>
      'No se pudo verificar el archivo. No se permite guardarlo fuera de Arveil.';

  @override
  String get attachmentLegacy =>
      'Adjunto de una versión anterior; no está disponible en esta pantalla.';

  @override
  String get attachmentSendResume => 'Enviar / reanudar';

  @override
  String get attachmentResumeDownload => 'Reanudar descarga';

  @override
  String get attachmentDownload => 'Descargar';

  @override
  String get attachmentCancel => 'Cancelar transferencia';

  @override
  String get attachmentSaveCopy => 'Guardar copia…';

  @override
  String get devicesOperationFailed =>
      'No se pudo completar la operación. Consulta el estado guardado y vuelve a sincronizar.';

  @override
  String get devicesReadFailed =>
      'No se pudo leer el estado de los dispositivos. Vuelve a intentarlo.';

  @override
  String get devicesRevokeTitle => '¿Revocar este dispositivo?';

  @override
  String get devicesRevokeCheckId =>
      'Comprueba el identificador completo en el otro dispositivo antes de continuar.';

  @override
  String get devicesRevokeConsequences =>
      'La revocación es permanente. Se guardará aquí y se publicará al conectar. El servidor bloqueará el dispositivo cuando acepte el cambio; las conversaciones también necesitan retirarlo de su grupo. No borra las copias ni el historial que ya tenga.';

  @override
  String get cancel => 'Cancelar';

  @override
  String get devicesRevokeConfirm => 'Revocar definitivamente';

  @override
  String get devicesTitle => 'Dispositivos';

  @override
  String get devicesKnownState =>
      'Estado conocido por este perfil. Estar autorizado no indica que un dispositivo esté conectado.';

  @override
  String get devicesSync => 'Sincronizar dispositivos';

  @override
  String get devicesReadLocal => 'Volver a leer el estado local';

  @override
  String get devicesAdministrator =>
      'Este perfil puede administrar sus dispositivos.';

  @override
  String get devicesLinked =>
      'Este dispositivo está vinculado. Revoca dispositivos desde el perfil administrador.';

  @override
  String devicesManifestVersion(String sequence) {
    return 'Versión local del manifiesto: $sequence';
  }

  @override
  String devicesPartialInventory(int active, int revoked) {
    return 'Inventario parcial: el manifiesto incluye $active credenciales autorizadas y $revoked revocadas cuyos identificadores de dispositivo no conoce este perfil. Consulta el administrador para gestionarlas.';
  }

  @override
  String get devicesThis => 'Este dispositivo';

  @override
  String get devicesLinkedDevice => 'Dispositivo vinculado';

  @override
  String get devicesRevokedLocally => 'Revocado según el estado local';

  @override
  String get devicesNotRevoked => 'No consta revocado en este perfil';

  @override
  String get devicesRevocationAccepted => 'Revocación aceptada por el servidor';

  @override
  String get devicesRevocationPending =>
      'Pendiente de publicar la revocación en el servidor';

  @override
  String devicesGroupsWaiting(int count) {
    return 'Conversaciones locales pendientes de retirarlo: $count';
  }

  @override
  String get devicesGroupsWaitingHelp =>
      'Sincroniza para recibir los cambios. La retirada corresponde al dispositivo que coordina los cambios del grupo; mientras tanto, el envío permanece bloqueado en quienes conocen la revocación.';

  @override
  String devicesNoticesPending(int count) {
    return 'Avisos pendientes de publicar: $count';
  }

  @override
  String devicesNoticesUnconfirmed(int count) {
    return 'Avisos rechazados o caducados sin confirmación: $count. Comprueba el estado con los otros participantes.';
  }

  @override
  String devicesNoticesWithoutRoute(int count) {
    return 'Avisos que no pudieron prepararse por falta de ruta: $count. Requieren revisar las rutas; no se reenvían automáticamente.';
  }

  @override
  String get devicesAcceptanceCaveat =>
      'La aceptación del servidor no confirma que los demás dispositivos hayan recibido el aviso.';

  @override
  String get devicesRevoke => 'Revocar dispositivo';

  @override
  String get pairingTitle => 'Vincular este dispositivo';

  @override
  String get pairingExplanation =>
      'Usa tu dispositivo administrador para autorizar este perfil. La vinculación conserva tu identidad; no copia el historial anterior.';

  @override
  String get pairingRelayLabel => 'Datos del servidor';

  @override
  String get pairingRelayInvalid => 'Pega los datos completos del servidor.';

  @override
  String get pairingGenerate => 'Generar código de vinculación';

  @override
  String get pairingConfirmationSaved =>
      'La confirmación está guardada. Falta terminar la configuración en el servidor.';

  @override
  String get pairingResumeFinish => 'Reanudar finalización';

  @override
  String get pairingExpired =>
      'Esta sesión ha caducado. Cancélala y genera un código nuevo.';

  @override
  String get pairingComparisonCode => 'Código de comparación';

  @override
  String get pairingCompareHelp =>
      'Comprueba ambas pantallas. Introduce aquí el código que muestra el dispositivo administrador. Si son distintos, cancela.';

  @override
  String get pairingOtherCode => 'Código del otro dispositivo';

  @override
  String get pairingConfirmComparison => 'Confirmar comparación';

  @override
  String get pairingShareCode =>
      'En el administrador, abre «Vincular otro dispositivo» y pega este código por un canal privado.';

  @override
  String pairingExpiresIn(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: 'Caduca en $seconds segundos.',
      one: 'Caduca en 1 segundo.',
    );
    return '$_temp0';
  }

  @override
  String get pairingWaiting => 'Esperando al dispositivo administrador…';

  @override
  String get pairingWaitInterrupted =>
      'La espera se interrumpió. Cancela esta sesión y genera otro código; la comparación ya recibida se conserva al reabrir.';

  @override
  String get pairingCancel => 'Cancelar vinculación';

  @override
  String get pairingCancelNote =>
      'Cancelar detiene este alta local. Si el administrador ya emitió una autorización, no la revoca.';

  @override
  String get pairingOtherTitle => 'Vincular otro dispositivo';

  @override
  String get pairingAdminCompare =>
      'Compara este código con el del nuevo dispositivo e introdúcelo allí para terminar.';

  @override
  String get pairingAuthorizationIssued =>
      'Ya se ha emitido la autorización. Cerrar esta comparación no la revoca. Si no reconoces la solicitud, revoca ese dispositivo desde la CLI.';

  @override
  String get pairingCloseComparison => 'Cerrar comparación';

  @override
  String get pairingPasteOwnCode =>
      'Pega únicamente el código de un dispositivo tuyo que tengas delante. Este paso emite su autorización.';

  @override
  String get pairingCodeLabel => 'Código de vinculación';

  @override
  String get pairingCodeInvalid => 'Pega el código de vinculación completo.';

  @override
  String get pairingAuthorize => 'Autorizar y comparar';

  @override
  String get pairingKeepOpen =>
      'Mantén ambos dispositivos abiertos durante la espera, de hasta 90 segundos.';

  @override
  String get archiveFailed =>
      'No se pudo completar la operación. Comprueba el archivo, su clave y que pertenece a tu identidad. Máximo 10.000 registros; exportación de hasta 48 MiB de contenido e importación de archivos de hasta 64 MiB.';

  @override
  String archiveSaved(int records, int files, int missing) {
    return 'Archivo guardado: $records registros, $files adjuntos con copia, $missing sin copia.';
  }

  @override
  String archiveImported(int imported, int duplicates) {
    return '$imported registros importados; $duplicates ya existentes, conservados sin cambios.';
  }

  @override
  String get archiveFileSaved =>
      'Copia del adjunto guardada en el destino elegido.';

  @override
  String get archiveTitle => 'Historial cifrado';

  @override
  String get archiveExplanation =>
      'El historial cifrado recupera mensajes y adjuntos disponibles, sin recuperar la identidad ni las sesiones de grupo. Restaura primero tu identidad con su kit si has perdido el dispositivo.';

  @override
  String get archiveKeepApart =>
      'Guarda el archivo y su clave por separado. Juntos permiten leer esta copia del pasado. No se descargan adjuntos pendientes; los archivos antiguos de la CLI pueden figurar sin copia.';

  @override
  String get archiveConsent =>
      'Entiendo que esta copia permite leer el historial';

  @override
  String get archiveSave => 'Guardar historial cifrado';

  @override
  String get archiveRevealKey => 'Mostrar clave del archivo guardado';

  @override
  String get archiveKeyNote =>
      'Guarda esta clave por separado. Desaparece al salir o cambiar de aplicación; Arveil no la conserva.';

  @override
  String get archiveKeySaved => 'He guardado la clave';

  @override
  String get archiveImportTitle => 'Importar historial';

  @override
  String get archiveImportNote =>
      'Solo se acepta un archivo de esta identidad. Los registros se añaden como historial de solo lectura: no se reenvían ni dan acceso a los grupos. Un archivo importado no demuestra la autoría de sus mensajes.';

  @override
  String get archiveChooseFile => 'Elegir archivo cifrado';

  @override
  String get archiveFileChosen => 'Archivo seleccionado; cambiar';

  @override
  String get archiveKeyLabel => 'Clave del archivo';

  @override
  String get archiveImport => 'Importar como historial';

  @override
  String get archiveImportedTitle => 'Historial importado · solo lectura';

  @override
  String get archiveEmpty => 'Todavía no hay registros importados.';

  @override
  String archiveEntryOutgoing(String group) {
    return 'Grupo $group · Saliente';
  }

  @override
  String archiveEntryIncoming(String group) {
    return 'Grupo $group · Entrante';
  }

  @override
  String archiveEntrySender(String header, String sender) {
    return '$header · $sender, según el archivo';
  }

  @override
  String get archiveNoFileCopy => 'Sin copia del adjunto en este archivo';

  @override
  String get archiveSaveFileCopy => 'Guardar copia del adjunto';

  @override
  String get archiveOlder => 'Ver registros anteriores';

  @override
  String get archiveBackToStart => 'Volver al inicio del historial';

  @override
  String get contactsReadFailed =>
      'No se pudieron leer los contactos. Vuelve a intentarlo.';

  @override
  String get contactsChoose => 'Elegir contactos';

  @override
  String get contactsTitle => 'Contactos';

  @override
  String get contactAdd => 'Añadir contacto';

  @override
  String get retry => 'Reintentar';

  @override
  String get contactsNamesLocal =>
      'Los nombres son locales. Comprueba la identidad comparando el número de seguridad por otro canal.';

  @override
  String get contactsDeviceLimit =>
      'Se incluirán los dispositivos guardados que no consten como revocados. Máximo: 16 dispositivos.';

  @override
  String get contactsEmpty => 'Todavía no tienes contactos guardados.';

  @override
  String get verified => 'Verificado';

  @override
  String get unverified => 'Sin verificar';

  @override
  String get contactNeedsRoute => 'Añade una ruta para conversar';

  @override
  String contactDevicesAvailable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dispositivos disponibles',
      one: '1 dispositivo disponible',
    );
    return '$_temp0';
  }

  @override
  String get contactsTooMany => 'Selecciona como máximo 16 dispositivos.';

  @override
  String contactsUse(int count) {
    return 'Usar contactos ($count)';
  }

  @override
  String get contactRouteInvalid =>
      'Revisa la ruta completa del contacto. Debe ser de otro dispositivo.';

  @override
  String get contactSaved => 'Contacto guardado en este perfil.';

  @override
  String get contactSaveFailed =>
      'No se pudo guardar. Revisa el nombre y la comparación; conserva el perfil y vuelve a intentarlo.';

  @override
  String get contactVerifiedNotice => 'Identidad verificada.';

  @override
  String get contactVerifyFailed =>
      'La comparación no se pudo confirmar. Reabre el contacto y compara el número de nuevo.';

  @override
  String get contactDetails => 'Datos del contacto';

  @override
  String get contactNameLabel => 'Nombre local (opcional)';

  @override
  String get contactNameHelper =>
      'Solo se guarda en este perfil. No verifica la identidad.';

  @override
  String get contactRouteLabel => 'Ruta de contacto';

  @override
  String get contactRouteHelper =>
      'Pide la ruta de este servidor a la persona que quieres añadir.';

  @override
  String get contactPrepare => 'Preparar contacto';

  @override
  String contactIdentity(String identity) {
    return 'Identidad $identity';
  }

  @override
  String get contactCompareHelp =>
      'Compara este número con la otra persona por otro canal. El nombre local no sustituye esta comprobación.';

  @override
  String contactRoutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count rutas guardadas',
      one: '1 ruta guardada',
    );
    return '$_temp0';
  }

  @override
  String contactDevice(String id) {
    return 'Dispositivo $id';
  }

  @override
  String contactDeviceRevoked(String id) {
    return 'Dispositivo $id · Revocado';
  }

  @override
  String get contactUpdateRoute =>
      'Para añadir o actualizar una ruta, vuelve a Añadir contacto. Comprueba que la identidad coincide y conserva el nombre que quieras usar.';

  @override
  String get contactSave => 'Guardar contacto';

  @override
  String get contactSaveName => 'Guardar nombre';

  @override
  String peerUnnamed(String id) {
    return 'Sin nombre · $id';
  }

  @override
  String get nameThisPerson => 'Ponle nombre';

  @override
  String get renamePerson => 'Cambiar nombre';

  @override
  String get nameDialogTitle => 'Nombre de esta persona';

  @override
  String get nameDialogLabel => 'Nombre';

  @override
  String get nameDialogHelper =>
      'Solo lo verás tú, en este perfil. No se envía a nadie ni verifica la identidad; para eso compara el número de seguridad.';

  @override
  String get nameSaved => 'Nombre guardado en este perfil.';

  @override
  String get nameSaveFailed =>
      'No se pudo guardar el nombre. Revísalo (máximo 128 caracteres, en una línea) y vuelve a intentarlo.';

  @override
  String get nameBannerOne =>
      'Aún no le has puesto nombre a esta persona. Solo tú lo verás.';

  @override
  String nameBannerMany(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count personas de esta conversación no tienen nombre.',
      one: 'Una persona de esta conversación no tiene nombre.',
    );
    return '$_temp0 Solo tú verás los nombres.';
  }

  @override
  String get nameThem => 'Poner nombres';

  @override
  String get newConversationNamed =>
      'La conversación se creó, pero no se pudo guardar algún nombre. Pónselo desde los detalles de la conversación.';

  @override
  String numericDate(String day, String month, String year) {
    return '$day/$month/$year';
  }

  @override
  String noticeAdded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'ha añadido $count dispositivos',
      one: 'ha añadido un dispositivo',
    );
    return '$_temp0';
  }

  @override
  String noticeRemoved(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'ha retirado $count dispositivos',
      one: 'ha retirado un dispositivo',
    );
    return '$_temp0';
  }

  @override
  String noticeBoth(String first, String second) {
    return '$first y $second';
  }

  @override
  String noticeSentence(String who, String change) {
    return '$who $change.';
  }

  @override
  String get noticeSomeone => 'Un contacto';

  @override
  String previewAttachment(String name) {
    return 'Adjunto: $name';
  }

  @override
  String previewOwn(String text) {
    return 'Tú: $text';
  }

  @override
  String get conversationEvent => 'Evento de conversación';

  @override
  String conversationFallback(String id) {
    return 'Conversación $id';
  }

  @override
  String get sendFile => 'Enviar archivo';

  @override
  String attachConfirm(String name, String size, String conversation) {
    return '$name\n$size\n\nConversación: $conversation\n\nSe guardará una copia privada cifrada para completar o reanudar el envío.';
  }

  @override
  String get fileReadFailed =>
      'No se pudo leer el archivo. Elige uno accesible que ocupe menos de 25 MiB.';

  @override
  String get exportTitle => 'Guardar copia fuera de Arveil';

  @override
  String get exportWarning =>
      'La copia quedará fuera del perfil cifrado de Arveil y puede entrar en las copias de seguridad del destino. Elige dónde guardarla.';

  @override
  String get exportChoose => 'Elegir destino';

  @override
  String get exportSaved => 'Copia guardada en el destino elegido.';

  @override
  String get exportFailed =>
      'No se pudo guardar la copia. El archivo privado se conserva; vuelve a intentarlo.';

  @override
  String get participants => 'Participantes';

  @override
  String get participantsYou => 'Tu identidad';

  @override
  String identityDevice(String identity, String device) {
    return 'Identidad $identity · dispositivo $device';
  }

  @override
  String get revoked => 'Revocado';

  @override
  String get close => 'Cerrar';

  @override
  String get ownRouteTitle => 'Tu ruta de contacto';

  @override
  String get ownRouteShare =>
      'Compártela solo con las personas que quieras que puedan escribir a este dispositivo. Comparad después el número de seguridad por otro canal.';

  @override
  String get ownRouteCopy => 'Copiar ruta';

  @override
  String get ownRouteFailed =>
      'No se pudo obtener la ruta de este dispositivo.';

  @override
  String get backToConversations => 'Volver a conversaciones';

  @override
  String get newConversation => 'Nueva conversación';

  @override
  String get sync => 'Sincronizar';

  @override
  String get syncing => 'Sincronizando';

  @override
  String get chooseConversation => 'Elige una conversación para leerla.';

  @override
  String get conversationsEmpty => 'Todavía no hay conversaciones guardadas.';

  @override
  String get conversationsEmptyHelp =>
      'Crea una con una ruta de contacto o sincroniza para recibir una invitación.';

  @override
  String conversationCounts(int devices, int messages) {
    String _temp0 = intl.Intl.pluralLogic(
      devices,
      locale: localeName,
      other: '$devices dispositivos',
      one: '1 dispositivo',
    );
    String _temp1 = intl.Intl.pluralLogic(
      messages,
      locale: localeName,
      other: '$messages mensajes',
      one: '1 mensaje',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String unreadMessages(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count mensajes sin leer',
      one: '1 mensaje sin leer',
    );
    return '$_temp0';
  }

  @override
  String get savingMessage => 'Guardando mensaje';

  @override
  String get firstMessage => 'Escribe el primer mensaje.';

  @override
  String get reading => 'Leyendo…';

  @override
  String get loadOlder => 'Cargar anteriores';

  @override
  String get attachFile => 'Adjuntar archivo';

  @override
  String get messageHint => 'Mensaje';

  @override
  String get send => 'Enviar';

  @override
  String get noticeSigned =>
      'El cambio está firmado por su identidad verificada.';

  @override
  String get noticeCompare =>
      'Compara su número de seguridad si no esperabas este cambio.';

  @override
  String get legacyAttachment => 'Adjunto (consulta disponible desde la CLI)';

  @override
  String get sentFromOtherDevice => 'Enviado desde otro de tus dispositivos';

  @override
  String get receivedHere => 'Recibido en este dispositivo';

  @override
  String get newConversationRoutesInvalid =>
      'Revisa las rutas completas: entre uno y dieciséis dispositivos distintos, sin incluir este dispositivo.';

  @override
  String get newConversationChooseContacts => 'Elegir contactos guardados';

  @override
  String get newConversationRoutesHelp =>
      'O utiliza una ruta nueva. Pide a tus contactos su ruta de este servidor. Pega una ruta por línea y compara el número de seguridad con cada persona por otro canal antes de crear el grupo.';

  @override
  String get newConversationRoutesLabel => 'Rutas de contacto';

  @override
  String get newConversationPrepare => 'Preparar comparación';

  @override
  String get newConversationCompared =>
      'Hemos comparado todos los números por otro canal y coinciden.';

  @override
  String get newConversationCreate => 'Crear conversación';

  @override
  String get deliveryNone =>
      'Guardado solo en este dispositivo: no hay destinatarios disponibles';

  @override
  String get deliveryWaiting => 'Pendiente de envío';

  @override
  String get deliveryAcceptedShort => 'Aceptado por el servidor';

  @override
  String safetyNumberLabel(String groups) {
    return 'Número de seguridad: $groups';
  }

  @override
  String get today => 'Hoy';

  @override
  String get yesterday => 'Ayer';

  @override
  String get chatSearchHint => 'Buscar chats';

  @override
  String get chatSearchClear => 'Borrar la búsqueda';

  @override
  String chatSearchNone(String query) {
    return 'Ningún chat coincide con «$query»';
  }

  @override
  String get kitReminderTitle => 'Guarda tu kit de identidad';

  @override
  String get kitReminderStaleTitle => 'Actualiza tu kit de identidad';

  @override
  String get recoveryWarningTitle => 'Comprueba las revocaciones';

  @override
  String get offlineTitle => 'Sin conexión';

  @override
  String get syncRefusedTitle => 'Sincronización rechazada';

  @override
  String get conversationDetails => 'Detalles de la conversación';

  @override
  String conversationPeople(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count personas',
      one: '1 persona',
    );
    return '$_temp0';
  }

  @override
  String get detailsFiles => 'Archivos';

  @override
  String get detailsNoFiles => 'No hay archivos en el historial cargado.';

  @override
  String get messageDetails => 'Detalles del mensaje';

  @override
  String messageRecordedAt(String when) {
    return 'Registrado en este dispositivo: $when';
  }

  @override
  String get deliveryPerMailbox => 'Entrega por buzón';

  @override
  String mailboxNumber(int number) {
    return 'Buzón $number';
  }

  @override
  String get mailboxRejected => 'El buzón rechazó el mensaje';

  @override
  String get copyText => 'Copiar texto';

  @override
  String get textCopied => 'Texto copiado';

  @override
  String devicesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dispositivos',
      one: '1 dispositivo',
    );
    return '$_temp0';
  }

  @override
  String get settingsSecurity => 'Seguridad y recuperación';

  @override
  String get settingsConnection => 'Conexión';

  @override
  String get settingsApp => 'Aplicación';

  @override
  String get kitStateNever => 'Sin guardar';

  @override
  String get kitStateStale => 'Desactualizado: tus dispositivos cambiaron';

  @override
  String kitStateSaved(String date) {
    return 'Guardado el $date';
  }

  @override
  String get identityAdministrator =>
      'Este dispositivo administra tus dispositivos';

  @override
  String get identityLinked => 'Dispositivo vinculado';

  @override
  String get shareMyRouteHelp => 'Para que otras personas puedan añadirte';

  @override
  String get licenses => 'Licencias';

  @override
  String get safetyNumberTitle => 'Número de seguridad';

  @override
  String get numbersMatch => 'Coinciden';

  @override
  String get numbersDiffer => 'No coinciden';

  @override
  String get mismatchTitle => 'Los números no coinciden';

  @override
  String get mismatchBody =>
      'No verifiques este contacto. La ruta puede no ser de esa persona o haber cambiado: pídele que te la envíe otra vez por otro canal.';

  @override
  String get comparedWillVerify =>
      'Coinciden: el contacto se guardará como verificado.';

  @override
  String get startTitle => '¿Cómo quieres empezar?';

  @override
  String get startBody =>
      'Tu identidad se crea en este dispositivo y solo tú la guardas.';

  @override
  String get entryInvitation => 'Unirme con una invitación';

  @override
  String get entryInvitationHelp =>
      'Con los datos del servidor y la invitación que te dieron.';

  @override
  String get entryPairingHelp => 'Tu dispositivo administrador autoriza este.';

  @override
  String get entryRestoreHelp => 'Recupera tu identidad con el kit y su clave.';

  @override
  String enrollStep(int step, int total) {
    return 'Paso $step de $total';
  }

  @override
  String get enrollServerTitle => 'Datos del servidor';

  @override
  String get enrollNext => 'Siguiente';

  @override
  String get enrollPrevious => 'Atrás';

  @override
  String get enrollInviteTitle => 'Tu invitación';

  @override
  String get enrollInviteBody =>
      'Pega la invitación de 64 caracteres que te dio el administrador.';

  @override
  String get kitOfferTitle => 'Guarda ahora tu kit de identidad';

  @override
  String get kitOfferRiskTitle => 'Si lo dejas para más tarde';

  @override
  String get appearanceTitle => 'Apariencia';

  @override
  String get appearanceSummary =>
      'Tema, color, fondo, tamaño del texto e idioma';

  @override
  String get themeTitle => 'Tema';

  @override
  String get themeSystem => 'Sistema';

  @override
  String get themeLight => 'Claro';

  @override
  String get themeDark => 'Oscuro';

  @override
  String get accentTitle => 'Color de acento';

  @override
  String get accentPine => 'Pino';

  @override
  String get accentLake => 'Lago';

  @override
  String get accentPlum => 'Ciruela';

  @override
  String get accentClay => 'Arcilla';

  @override
  String get accentMoss => 'Musgo';

  @override
  String get accentSlate => 'Pizarra';

  @override
  String get wallpaperTitle => 'Fondo de la conversación';

  @override
  String get wallpaperPlain => 'Liso';

  @override
  String get wallpaperArcs => 'Arcos';

  @override
  String get wallpaperDots => 'Puntos';

  @override
  String get wallpaperWaves => 'Ondas';

  @override
  String get wallpaperDiamonds => 'Rombos';

  @override
  String get textSizeTitle => 'Tamaño del texto';

  @override
  String textSizeValue(int percent) {
    return '$percent %';
  }

  @override
  String get textSizeHelp => 'Se aplica sobre el tamaño de texto del sistema.';

  @override
  String get languageTitle => 'Idioma';

  @override
  String get languageSystem => 'Idioma del sistema';

  @override
  String get sampleReceived => '¿Quedamos el sábado?';

  @override
  String get sampleOwn => '¡Perfecto! Llevo el postre.';

  @override
  String get you => 'Tú';

  @override
  String bubbleSaid(String who, String text) {
    return '$who: $text';
  }

  @override
  String bubbleSaidAt(String who, String time, String text) {
    return '$who, $time: $text';
  }

  @override
  String get diagnosticsTitle => 'Diagnóstico';

  @override
  String get diagnosticsSummary => 'Un informe sin secretos para pedir ayuda';

  @override
  String get diagnosticsExplanation =>
      'Si algo falla, este informe ayuda a entender por qué. Revísalo antes de compartirlo: es exactamente lo que se guardará.';

  @override
  String get diagnosticsPrivacyTitle => 'Sin datos que te identifiquen';

  @override
  String get diagnosticsPrivacyBody =>
      'No incluye claves, identificadores, rutas, direcciones, invitaciones, nombres ni el contenido de tus conversaciones.';

  @override
  String get diagnosticsSave => 'Guardar informe';

  @override
  String get diagnosticsSaveDialog => 'Guardar informe de diagnóstico';

  @override
  String get diagnosticsSaved => 'Informe guardado';

  @override
  String get diagnosticsSaveFailed => 'No se pudo guardar el informe';

  @override
  String get languageSpanish => 'Español';

  @override
  String get languageEnglish => 'English';

  @override
  String get searchConversation => 'Buscar en la conversación';

  @override
  String get searchConversationHint => 'Buscar en esta conversación';

  @override
  String get searchConversationPrompt =>
      'Escribe para buscar entre los mensajes de esta conversación.';

  @override
  String searchNoResults(String query) {
    return 'Ningún mensaje contiene «$query»';
  }

  @override
  String get searchNothingRecent => 'Nada entre los mensajes más recientes.';

  @override
  String get searchOlder => 'Buscar más atrás';

  @override
  String get searchFailed => 'No se pudo buscar. Vuelve a intentarlo.';

  @override
  String get closeSearch => 'Cerrar la búsqueda';
}
