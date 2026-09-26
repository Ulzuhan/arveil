import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
  ];

  /// Application name; never translated.
  ///
  /// In es, this message translates to:
  /// **'Arveil'**
  String get appTitle;

  /// Main navigation destination with the conversation list.
  ///
  /// In es, this message translates to:
  /// **'Chats'**
  String get navChats;

  /// No description provided for @navContacts.
  ///
  /// In es, this message translates to:
  /// **'Contactos'**
  String get navContacts;

  /// No description provided for @navSettings.
  ///
  /// In es, this message translates to:
  /// **'Ajustes'**
  String get navSettings;

  /// No description provided for @profileClose.
  ///
  /// In es, this message translates to:
  /// **'Cerrar perfil'**
  String get profileClose;

  /// No description provided for @profileStateUnreadable.
  ///
  /// In es, this message translates to:
  /// **'No se pudo leer el estado del perfil.'**
  String get profileStateUnreadable;

  /// No description provided for @profileReadAgain.
  ///
  /// In es, this message translates to:
  /// **'Volver a leer'**
  String get profileReadAgain;

  /// No description provided for @enrollBack.
  ///
  /// In es, this message translates to:
  /// **'Volver al alta'**
  String get enrollBack;

  /// No description provided for @operationInProgress.
  ///
  /// In es, this message translates to:
  /// **'Operación en curso'**
  String get operationInProgress;

  /// No description provided for @operationInProgressDetail.
  ///
  /// In es, this message translates to:
  /// **'Operación en curso. El avance confirmado queda guardado en el perfil.'**
  String get operationInProgressDetail;

  /// No description provided for @welcomeTitle.
  ///
  /// In es, this message translates to:
  /// **'Tu identidad, en este dispositivo'**
  String get welcomeTitle;

  /// No description provided for @welcomeBody.
  ///
  /// In es, this message translates to:
  /// **'Abre tu perfil o prepara uno nuevo para unirte con una invitación.'**
  String get welcomeBody;

  /// No description provided for @welcomeKeyNote.
  ///
  /// In es, this message translates to:
  /// **'El perfil se cifra con una clave guardada en el almacén seguro del dispositivo. Si pierdes esa clave, no podrás recuperar el historial local.'**
  String get welcomeKeyNote;

  /// No description provided for @profileOpen.
  ///
  /// In es, this message translates to:
  /// **'Abrir perfil'**
  String get profileOpen;

  /// No description provided for @enrollTitleRetry.
  ///
  /// In es, this message translates to:
  /// **'Retoma tu alta'**
  String get enrollTitleRetry;

  /// No description provided for @enrollBodyRetry.
  ///
  /// In es, this message translates to:
  /// **'Tu avance está guardado. Usa la misma invitación para continuar con tu identidad.'**
  String get enrollBodyRetry;

  /// No description provided for @enrollBody.
  ///
  /// In es, this message translates to:
  /// **'Pide al administrador los datos del servidor y una invitación. Tu identidad se crea en este dispositivo al continuar.'**
  String get enrollBody;

  /// No description provided for @setupRedeeming.
  ///
  /// In es, this message translates to:
  /// **'Pendiente de confirmar la invitación.'**
  String get setupRedeeming;

  /// No description provided for @setupRedeemed.
  ///
  /// In es, this message translates to:
  /// **'Invitación aceptada. Falta recibir la configuración.'**
  String get setupRedeemed;

  /// No description provided for @setupPublishing.
  ///
  /// In es, this message translates to:
  /// **'Configuración recibida. Falta terminar el buzón y las claves de mensajería.'**
  String get setupPublishing;

  /// No description provided for @setupIdentityReady.
  ///
  /// In es, this message translates to:
  /// **'Tu identidad local ya está creada.'**
  String get setupIdentityReady;

  /// No description provided for @setupNew.
  ///
  /// In es, this message translates to:
  /// **'Listo para crear tu identidad.'**
  String get setupNew;

  /// No description provided for @enrollRelayLabel.
  ///
  /// In es, this message translates to:
  /// **'Datos del servidor'**
  String get enrollRelayLabel;

  /// No description provided for @enrollRelayInvalid.
  ///
  /// In es, this message translates to:
  /// **'Pega los datos completos del servidor.'**
  String get enrollRelayInvalid;

  /// No description provided for @enrollInviteLabel.
  ///
  /// In es, this message translates to:
  /// **'Invitación'**
  String get enrollInviteLabel;

  /// No description provided for @enrollInviteHelper.
  ///
  /// In es, this message translates to:
  /// **'No se guarda. Consérvala hasta completar el alta.'**
  String get enrollInviteHelper;

  /// No description provided for @enrollInviteInvalid.
  ///
  /// In es, this message translates to:
  /// **'La invitación debe contener 64 caracteres hexadecimales.'**
  String get enrollInviteInvalid;

  /// No description provided for @enrollRetry.
  ///
  /// In es, this message translates to:
  /// **'Reintentar alta'**
  String get enrollRetry;

  /// No description provided for @enrollSubmit.
  ///
  /// In es, this message translates to:
  /// **'Crear identidad y unirme'**
  String get enrollSubmit;

  /// No description provided for @enrollPair.
  ///
  /// In es, this message translates to:
  /// **'Vincular con mi otro dispositivo'**
  String get enrollPair;

  /// No description provided for @enrollRestore.
  ///
  /// In es, this message translates to:
  /// **'Restaurar desde un kit'**
  String get enrollRestore;

  /// No description provided for @kitReminderNever.
  ///
  /// In es, this message translates to:
  /// **'Sin kit ni otro dispositivo vinculado, perder este dispositivo significa perder tu identidad.'**
  String get kitReminderNever;

  /// No description provided for @kitReminderStale.
  ///
  /// In es, this message translates to:
  /// **'Tus dispositivos cambiaron después de guardar el kit. Guarda uno nuevo para que una recuperación los conozca.'**
  String get kitReminderStale;

  /// No description provided for @kitSave.
  ///
  /// In es, this message translates to:
  /// **'Guardar kit'**
  String get kitSave;

  /// No description provided for @later.
  ///
  /// In es, this message translates to:
  /// **'Más tarde'**
  String get later;

  /// No description provided for @recoveryRollbackWarning.
  ///
  /// In es, this message translates to:
  /// **'El servidor conocía un manifiesto anterior al de tu kit. Comprueba las revocaciones con un contacto o dispositivo superviviente antes de confiar en su estado.'**
  String get recoveryRollbackWarning;

  /// No description provided for @manageDevices.
  ///
  /// In es, this message translates to:
  /// **'Gestionar dispositivos'**
  String get manageDevices;

  /// No description provided for @encryptedHistory.
  ///
  /// In es, this message translates to:
  /// **'Historial cifrado'**
  String get encryptedHistory;

  /// No description provided for @linkedDeviceKitNote.
  ///
  /// In es, this message translates to:
  /// **'Este dispositivo está vinculado. El kit de identidad se exporta desde el dispositivo administrador.'**
  String get linkedDeviceKitNote;

  /// No description provided for @errorSecureStorageUnavailable.
  ///
  /// In es, this message translates to:
  /// **'El almacén seguro del dispositivo no está disponible. Desbloquea el dispositivo y comprueba el permiso de acceso al almacén seguro.'**
  String get errorSecureStorageUnavailable;

  /// No description provided for @errorProfileKeyMissing.
  ///
  /// In es, this message translates to:
  /// **'Falta la clave de este perfil. No se puede abrir su historial local. Conserva el perfil hasta recuperar la clave.'**
  String get errorProfileKeyMissing;

  /// No description provided for @errorEnrollmentUnreadable.
  ///
  /// In es, this message translates to:
  /// **'El alta terminó, pero no se pudo leer el perfil. Ciérralo y vuelve a abrirlo.'**
  String get errorEnrollmentUnreadable;

  /// No description provided for @errorOperationUnreadable.
  ///
  /// In es, this message translates to:
  /// **'La operación terminó, pero no se pudo leer el perfil. Ciérralo y vuelve a abrirlo.'**
  String get errorOperationUnreadable;

  /// No description provided for @pairingConfirmationStarted.
  ///
  /// In es, this message translates to:
  /// **'La confirmación ya empezó. Reanuda la finalización de la vinculación.'**
  String get pairingConfirmationStarted;

  /// No description provided for @errorBadKey.
  ///
  /// In es, this message translates to:
  /// **'La clave del perfil no tiene un formato válido.'**
  String get errorBadKey;

  /// No description provided for @errorNoRandomness.
  ///
  /// In es, this message translates to:
  /// **'El sistema no pudo generar una clave segura.'**
  String get errorNoRandomness;

  /// No description provided for @errorProfileInUse.
  ///
  /// In es, this message translates to:
  /// **'El perfil está abierto en otra sesión. Ciérrala e inténtalo de nuevo.'**
  String get errorProfileInUse;

  /// No description provided for @errorProfileClosing.
  ///
  /// In es, this message translates to:
  /// **'El perfil aún se está cerrando. Vuelve a intentarlo.'**
  String get errorProfileClosing;

  /// No description provided for @errorProfileTooNew.
  ///
  /// In es, this message translates to:
  /// **'Una versión más reciente de Arveil guardó este perfil. Actualiza la app para abrirlo; el perfil no se ha modificado.'**
  String get errorProfileTooNew;

  /// No description provided for @errorProfileUnusable.
  ///
  /// In es, this message translates to:
  /// **'No se pudo descifrar el perfil. Conserva los datos y comprueba su clave.'**
  String get errorProfileUnusable;

  /// No description provided for @errorProfileIo.
  ///
  /// In es, this message translates to:
  /// **'No se pudo acceder al perfil. Comprueba el espacio y los permisos del dispositivo.'**
  String get errorProfileIo;

  /// No description provided for @errorSecureStoragePrepare.
  ///
  /// In es, this message translates to:
  /// **'No se pudo preparar el almacenamiento seguro del perfil. Vuelve a intentarlo.'**
  String get errorSecureStoragePrepare;

  /// No description provided for @errorTransport.
  ///
  /// In es, this message translates to:
  /// **'No se pudo conectar con el servidor. Comprueba la conexión y sigue las indicaciones de la operación pendiente.'**
  String get errorTransport;

  /// No description provided for @errorDomain.
  ///
  /// In es, this message translates to:
  /// **'Revisa los datos y la vigencia de la operación. Conserva el perfil; no empieces un alta diferente para reintentar.'**
  String get errorDomain;

  /// No description provided for @errorProtocol.
  ///
  /// In es, this message translates to:
  /// **'El servidor no aceptó la operación. Comprueba los datos con su administrador; una recuperación puede necesitar un kit más reciente.'**
  String get errorProtocol;

  /// No description provided for @errorBusy.
  ///
  /// In es, this message translates to:
  /// **'Hay otra operación en curso. Espera y vuelve a intentarlo.'**
  String get errorBusy;

  /// No description provided for @errorStorage.
  ///
  /// In es, this message translates to:
  /// **'No se pudo guardar el avance. Comprueba el almacenamiento y vuelve a intentarlo.'**
  String get errorStorage;

  /// No description provided for @errorInterrupted.
  ///
  /// In es, this message translates to:
  /// **'La operación se interrumpió. Puedes volver a intentarlo.'**
  String get errorInterrupted;

  /// No description provided for @errorUnknown.
  ///
  /// In es, this message translates to:
  /// **'No se pudo completar la operación. Cierra el perfil y vuelve a abrirlo.'**
  String get errorUnknown;

  /// No description provided for @syncWhenNow.
  ///
  /// In es, this message translates to:
  /// **'ahora'**
  String get syncWhenNow;

  /// No description provided for @syncWhenMinutes.
  ///
  /// In es, this message translates to:
  /// **'hace {minutes} min'**
  String syncWhenMinutes(int minutes);

  /// A time of day such as 16:05.
  ///
  /// In es, this message translates to:
  /// **'a las {time}'**
  String syncWhenTime(String time);

  /// Appended to offline or refused states; {when} is syncWhen*.
  ///
  /// In es, this message translates to:
  /// **' · última sincronización {when}'**
  String syncLastSuffix(String when);

  /// No description provided for @syncNever.
  ///
  /// In es, this message translates to:
  /// **'Aún sin sincronizar'**
  String get syncNever;

  /// No description provided for @syncSyncing.
  ///
  /// In es, this message translates to:
  /// **'Sincronizando…'**
  String get syncSyncing;

  /// {when} is syncWhenNow, syncWhenMinutes or syncWhenTime.
  ///
  /// In es, this message translates to:
  /// **'Sincronizado {when}'**
  String syncSynced(String when);

  /// {last} is empty or syncLastSuffix.
  ///
  /// In es, this message translates to:
  /// **'Sin conexión con tu servidor{last}'**
  String syncOffline(String last);

  /// {last} is empty or syncLastSuffix.
  ///
  /// In es, this message translates to:
  /// **'El servidor rechazó la sincronización{last}'**
  String syncRefused(String last);

  /// No description provided for @chatErrorHistory.
  ///
  /// In es, this message translates to:
  /// **'No se pudo leer el historial local. Conserva el perfil y vuelve a abrirlo.'**
  String get chatErrorHistory;

  /// No description provided for @chatErrorConversation.
  ///
  /// In es, this message translates to:
  /// **'No se pudo leer esta conversación. Vuelve a intentarlo.'**
  String get chatErrorConversation;

  /// No description provided for @chatErrorOlder.
  ///
  /// In es, this message translates to:
  /// **'No se pudieron leer los mensajes anteriores. Puedes reintentar.'**
  String get chatErrorOlder;

  /// No description provided for @chatSyncPending.
  ///
  /// In es, this message translates to:
  /// **'Sincronización pendiente. Puedes leer y escribir sin conexión; usa Sincronizar para reintentar.'**
  String get chatSyncPending;

  /// No description provided for @chatSyncRefused.
  ///
  /// In es, this message translates to:
  /// **'El servidor no aceptó la sincronización. Tus mensajes siguen guardados en este dispositivo; comprueba los datos del servidor con quien lo administra.'**
  String get chatSyncRefused;

  /// No description provided for @chatMessageTooLong.
  ///
  /// In es, this message translates to:
  /// **'Escribe un mensaje de hasta 32 KiB.'**
  String get chatMessageTooLong;

  /// No description provided for @chatSavedRetrySync.
  ///
  /// In es, this message translates to:
  /// **'Mensaje guardado. Reintenta la sincronización; no vuelvas a enviarlo.'**
  String get chatSavedRetrySync;

  /// No description provided for @chatSaveUnconfirmed.
  ///
  /// In es, this message translates to:
  /// **'No se confirmó el guardado. Conserva el borrador y consulta el historial antes de reintentar.'**
  String get chatSaveUnconfirmed;

  /// No description provided for @chatFileSaveUnconfirmed.
  ///
  /// In es, this message translates to:
  /// **'No se confirmó el guardado del archivo. Consulta el historial antes de volver a adjuntarlo.'**
  String get chatFileSaveUnconfirmed;

  /// No description provided for @chatTransferIncomplete.
  ///
  /// In es, this message translates to:
  /// **'La operación no se completó. Consulta el estado del archivo: reanuda su transferencia o sincroniza si ya está preparado.'**
  String get chatTransferIncomplete;

  /// No description provided for @chatCancelFailed.
  ///
  /// In es, this message translates to:
  /// **'No se pudo cancelar. La transferencia puede haber terminado; consulta su estado.'**
  String get chatCancelFailed;

  /// No description provided for @chatCreatedSyncPending.
  ///
  /// In es, this message translates to:
  /// **'Conversación guardada. Sincroniza para completar el envío de la invitación; no la crees de nuevo.'**
  String get chatCreatedSyncPending;

  /// No description provided for @chatCreateUnconfirmed.
  ///
  /// In es, this message translates to:
  /// **'No se confirmó la creación. Comprueba las rutas, la conexión y que tus contactos tengan claves disponibles. Consulta la lista antes de reintentar.'**
  String get chatCreateUnconfirmed;

  /// No description provided for @dialogSaveHistory.
  ///
  /// In es, this message translates to:
  /// **'Guardar historial cifrado'**
  String get dialogSaveHistory;

  /// No description provided for @dialogOpenHistory.
  ///
  /// In es, this message translates to:
  /// **'Abrir historial cifrado'**
  String get dialogOpenHistory;

  /// No description provided for @dialogSaveKit.
  ///
  /// In es, this message translates to:
  /// **'Guardar kit de identidad cifrado'**
  String get dialogSaveKit;

  /// No description provided for @dialogOpenKit.
  ///
  /// In es, this message translates to:
  /// **'Abrir kit de identidad'**
  String get dialogOpenKit;

  /// No description provided for @kitTooLarge.
  ///
  /// In es, this message translates to:
  /// **'El kit supera el tamaño máximo de 4 MiB.'**
  String get kitTooLarge;

  /// No description provided for @dialogChooseFile.
  ///
  /// In es, this message translates to:
  /// **'Elegir archivo'**
  String get dialogChooseFile;

  /// No description provided for @dialogSaveFileCopy.
  ///
  /// In es, this message translates to:
  /// **'Guardar copia del archivo'**
  String get dialogSaveFileCopy;

  /// No description provided for @recoveryIncomplete.
  ///
  /// In es, this message translates to:
  /// **'Selecciona el kit, introduce su clave y los datos del servidor, y confirma las consecuencias de la recuperación.'**
  String get recoveryIncomplete;

  /// No description provided for @kitTitle.
  ///
  /// In es, this message translates to:
  /// **'Kit de identidad'**
  String get kitTitle;

  /// No description provided for @kitExplanation.
  ///
  /// In es, this message translates to:
  /// **'El kit recupera tu identidad, no el historial ni el estado de los grupos. Guarda el archivo cifrado y su clave por separado; juntos permiten tomar el control de la identidad.'**
  String get kitExplanation;

  /// No description provided for @kitRevealSavedKey.
  ///
  /// In es, this message translates to:
  /// **'Mostrar clave del kit guardado'**
  String get kitRevealSavedKey;

  /// No description provided for @kitSavedKeyNow.
  ///
  /// In es, this message translates to:
  /// **'Archivo guardado. Guarda ahora esta clave por separado, por ejemplo en tu gestor de contraseñas. Arveil no la conserva.'**
  String get kitSavedKeyNow;

  /// No description provided for @kitKeyDisappears.
  ///
  /// In es, this message translates to:
  /// **'La clave desaparece al salir de esta pantalla o cambiar de aplicación. Si la pierdes, crea un kit nuevo.'**
  String get kitKeyDisappears;

  /// No description provided for @kitKeySavedConfirm.
  ///
  /// In es, this message translates to:
  /// **'He guardado la clave por separado'**
  String get kitKeySavedConfirm;

  /// No description provided for @kitSavedByConfirmation.
  ///
  /// In es, this message translates to:
  /// **'Kit y clave guardados según tu confirmación. Exporta uno nuevo después de cambiar tus dispositivos.'**
  String get kitSavedByConfirmation;

  /// No description provided for @kitDeferredWarning.
  ///
  /// In es, this message translates to:
  /// **'Kit pospuesto: perder el dispositivo administrador sin un kit puede impedir recuperar tu identidad.'**
  String get kitDeferredWarning;

  /// No description provided for @kitSaveEncrypted.
  ///
  /// In es, this message translates to:
  /// **'Guardar kit cifrado'**
  String get kitSaveEncrypted;

  /// No description provided for @kitPostpone.
  ///
  /// In es, this message translates to:
  /// **'Posponer el kit'**
  String get kitPostpone;

  /// No description provided for @recoveryTitle.
  ///
  /// In es, this message translates to:
  /// **'Recuperar mi identidad'**
  String get recoveryTitle;

  /// No description provided for @recoveryExplanation.
  ///
  /// In es, this message translates to:
  /// **'Usa el kit más reciente y su clave. Esta recuperación crea un dispositivo administrador nuevo y revoca los dispositivos anteriores incluidos en el manifiesto. El historial no se recupera; tendrás que incorporarte de nuevo a los grupos.'**
  String get recoveryExplanation;

  /// No description provided for @recoveryRelayLabel.
  ///
  /// In es, this message translates to:
  /// **'Datos del servidor original'**
  String get recoveryRelayLabel;

  /// No description provided for @recoveryChooseKit.
  ///
  /// In es, this message translates to:
  /// **'Seleccionar kit cifrado'**
  String get recoveryChooseKit;

  /// No description provided for @recoveryKitChosen.
  ///
  /// In es, this message translates to:
  /// **'Kit seleccionado: cambiar archivo'**
  String get recoveryKitChosen;

  /// No description provided for @recoveryKitKey.
  ///
  /// In es, this message translates to:
  /// **'Clave del kit'**
  String get recoveryKitKey;

  /// No description provided for @recoveryConsent.
  ///
  /// In es, this message translates to:
  /// **'Entiendo que se revocarán los dispositivos anteriores y no se recuperará su historial.'**
  String get recoveryConsent;

  /// No description provided for @recoveryRestore.
  ///
  /// In es, this message translates to:
  /// **'Restaurar identidad y revocar dispositivos'**
  String get recoveryRestore;

  /// No description provided for @recoveryResumeTitle.
  ///
  /// In es, this message translates to:
  /// **'Continúa la recuperación'**
  String get recoveryResumeTitle;

  /// No description provided for @recoveryResumeBody.
  ///
  /// In es, this message translates to:
  /// **'La identidad y las claves del nuevo dispositivo están guardadas. El servidor puede haber aceptado ya la revocación de los anteriores. Reanuda esta misma operación; no necesitas volver a abrir el kit ni crear otro perfil.'**
  String get recoveryResumeBody;

  /// No description provided for @recoveryResume.
  ///
  /// In es, this message translates to:
  /// **'Reanudar recuperación'**
  String get recoveryResume;

  /// No description provided for @keyPackagesTitle.
  ///
  /// In es, this message translates to:
  /// **'Claves para grupos nuevos'**
  String get keyPackagesTitle;

  /// No description provided for @keyPackagesExplanation.
  ///
  /// In es, this message translates to:
  /// **'Este dispositivo publica claves de un solo uso para que otras personas puedan iniciar conversaciones con él. Las conversaciones existentes conservan sus propias claves.'**
  String get keyPackagesExplanation;

  /// No description provided for @keyPackagesUnknown.
  ///
  /// In es, this message translates to:
  /// **'Disponibilidad sin comprobar'**
  String get keyPackagesUnknown;

  /// No description provided for @keyPackagesEmpty.
  ///
  /// In es, this message translates to:
  /// **'Última consulta: sin claves disponibles'**
  String get keyPackagesEmpty;

  /// No description provided for @keyPackagesLow.
  ///
  /// In es, this message translates to:
  /// **'Última consulta: quedan pocas claves'**
  String get keyPackagesLow;

  /// No description provided for @keyPackagesReady.
  ///
  /// In es, this message translates to:
  /// **'Última consulta: claves disponibles'**
  String get keyPackagesReady;

  /// No description provided for @keyPackagesCount.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{1 clave disponible según el servidor.} other{{count} claves disponibles según el servidor.}}'**
  String keyPackagesCount(int count);

  /// No description provided for @keyPackagesCheckedAt.
  ///
  /// In es, this message translates to:
  /// **'Consultado el {date} a las {time}. Puede cambiar cuando otra persona use una clave.'**
  String keyPackagesCheckedAt(String date, String time);

  /// No description provided for @keyPackagesNoneWarning.
  ///
  /// In es, this message translates to:
  /// **'Otros dispositivos no podrán iniciar nuevas conversaciones con este dispositivo hasta que haya claves disponibles.'**
  String get keyPackagesNoneWarning;

  /// No description provided for @keyPackagesReplenishSoon.
  ///
  /// In es, this message translates to:
  /// **'Repón las claves antes de que se agoten.'**
  String get keyPackagesReplenishSoon;

  /// No description provided for @keyPackagesPending.
  ///
  /// In es, this message translates to:
  /// **'Hay una publicación pendiente de confirmar. Reanudar enviará el mismo lote guardado; no regenerará esas claves.'**
  String get keyPackagesPending;

  /// No description provided for @keyPackagesUnavailable.
  ///
  /// In es, this message translates to:
  /// **'No se pudo actualizar la disponibilidad. El último dato guardado no confirma el estado actual.'**
  String get keyPackagesUnavailable;

  /// No description provided for @keyPackagesCheck.
  ///
  /// In es, this message translates to:
  /// **'Comprobar disponibilidad'**
  String get keyPackagesCheck;

  /// No description provided for @keyPackagesResume.
  ///
  /// In es, this message translates to:
  /// **'Reanudar publicación de claves'**
  String get keyPackagesResume;

  /// No description provided for @keyPackagesReplenish.
  ///
  /// In es, this message translates to:
  /// **'Reponer claves'**
  String get keyPackagesReplenish;

  /// No description provided for @attachmentSavedPending.
  ///
  /// In es, this message translates to:
  /// **'Guardado en este dispositivo · pendiente de envío'**
  String get attachmentSavedPending;

  /// No description provided for @attachmentDownloadInterrupted.
  ///
  /// In es, this message translates to:
  /// **'Descarga interrumpida'**
  String get attachmentDownloadInterrupted;

  /// No description provided for @attachmentDownloadAwaiting.
  ///
  /// In es, this message translates to:
  /// **'Descarga pendiente de tu autorización'**
  String get attachmentDownloadAwaiting;

  /// No description provided for @attachmentTransferring.
  ///
  /// In es, this message translates to:
  /// **'Transfiriendo…'**
  String get attachmentTransferring;

  /// No description provided for @attachmentTransferInterrupted.
  ///
  /// In es, this message translates to:
  /// **'Transferencia interrumpida · puedes reanudar'**
  String get attachmentTransferInterrupted;

  /// No description provided for @attachmentDownloaded.
  ///
  /// In es, this message translates to:
  /// **'Descargado y verificado · copia privada cifrada'**
  String get attachmentDownloaded;

  /// No description provided for @deliveryNoRecipients.
  ///
  /// In es, this message translates to:
  /// **'Guardado localmente · sin destinatarios disponibles'**
  String get deliveryNoRecipients;

  /// No description provided for @deliveryAccepted.
  ///
  /// In es, this message translates to:
  /// **'Aceptado por el servidor · lectura sin confirmar'**
  String get deliveryAccepted;

  /// No description provided for @deliveryRejected.
  ///
  /// In es, this message translates to:
  /// **'Algún buzón rechazó el mensaje'**
  String get deliveryRejected;

  /// No description provided for @deliveryExpired.
  ///
  /// In es, this message translates to:
  /// **'Entrega caducada o desconocida'**
  String get deliveryExpired;

  /// No description provided for @attachmentReady.
  ///
  /// In es, this message translates to:
  /// **'Archivo preparado · envío pendiente de sincronización'**
  String get attachmentReady;

  /// No description provided for @attachmentCancelled.
  ///
  /// In es, this message translates to:
  /// **'Transferencia cancelada · copia incompleta eliminada'**
  String get attachmentCancelled;

  /// No description provided for @attachmentUnavailable.
  ///
  /// In es, this message translates to:
  /// **'Archivo no disponible o acceso rechazado. Puedes reintentar o pedir otra copia.'**
  String get attachmentUnavailable;

  /// No description provided for @attachmentExpiredOnRelay.
  ///
  /// In es, this message translates to:
  /// **'Archivo caducado en el servidor. Pide que lo envíen de nuevo.'**
  String get attachmentExpiredOnRelay;

  /// No description provided for @attachmentUnverified.
  ///
  /// In es, this message translates to:
  /// **'No se pudo verificar el archivo. No se permite guardarlo fuera de Arveil.'**
  String get attachmentUnverified;

  /// No description provided for @attachmentLegacy.
  ///
  /// In es, this message translates to:
  /// **'Adjunto de una versión anterior; no está disponible en esta pantalla.'**
  String get attachmentLegacy;

  /// No description provided for @attachmentSendResume.
  ///
  /// In es, this message translates to:
  /// **'Enviar / reanudar'**
  String get attachmentSendResume;

  /// No description provided for @attachmentResumeDownload.
  ///
  /// In es, this message translates to:
  /// **'Reanudar descarga'**
  String get attachmentResumeDownload;

  /// No description provided for @attachmentDownload.
  ///
  /// In es, this message translates to:
  /// **'Descargar'**
  String get attachmentDownload;

  /// No description provided for @attachmentCancel.
  ///
  /// In es, this message translates to:
  /// **'Cancelar transferencia'**
  String get attachmentCancel;

  /// No description provided for @attachmentSaveCopy.
  ///
  /// In es, this message translates to:
  /// **'Guardar copia…'**
  String get attachmentSaveCopy;

  /// No description provided for @devicesOperationFailed.
  ///
  /// In es, this message translates to:
  /// **'No se pudo completar la operación. Consulta el estado guardado y vuelve a sincronizar.'**
  String get devicesOperationFailed;

  /// No description provided for @devicesReadFailed.
  ///
  /// In es, this message translates to:
  /// **'No se pudo leer el estado de los dispositivos. Vuelve a intentarlo.'**
  String get devicesReadFailed;

  /// No description provided for @devicesRevokeTitle.
  ///
  /// In es, this message translates to:
  /// **'¿Revocar este dispositivo?'**
  String get devicesRevokeTitle;

  /// No description provided for @devicesRevokeCheckId.
  ///
  /// In es, this message translates to:
  /// **'Comprueba el identificador completo en el otro dispositivo antes de continuar.'**
  String get devicesRevokeCheckId;

  /// No description provided for @devicesRevokeConsequences.
  ///
  /// In es, this message translates to:
  /// **'La revocación es permanente. Se guardará aquí y se publicará al conectar. El servidor bloqueará el dispositivo cuando acepte el cambio; las conversaciones también necesitan retirarlo de su grupo. No borra las copias ni el historial que ya tenga.'**
  String get devicesRevokeConsequences;

  /// No description provided for @cancel.
  ///
  /// In es, this message translates to:
  /// **'Cancelar'**
  String get cancel;

  /// No description provided for @devicesRevokeConfirm.
  ///
  /// In es, this message translates to:
  /// **'Revocar definitivamente'**
  String get devicesRevokeConfirm;

  /// No description provided for @devicesTitle.
  ///
  /// In es, this message translates to:
  /// **'Dispositivos'**
  String get devicesTitle;

  /// No description provided for @devicesKnownState.
  ///
  /// In es, this message translates to:
  /// **'Estado conocido por este perfil. Estar autorizado no indica que un dispositivo esté conectado.'**
  String get devicesKnownState;

  /// No description provided for @devicesSync.
  ///
  /// In es, this message translates to:
  /// **'Sincronizar dispositivos'**
  String get devicesSync;

  /// No description provided for @devicesReadLocal.
  ///
  /// In es, this message translates to:
  /// **'Volver a leer el estado local'**
  String get devicesReadLocal;

  /// No description provided for @devicesAdministrator.
  ///
  /// In es, this message translates to:
  /// **'Este perfil puede administrar sus dispositivos.'**
  String get devicesAdministrator;

  /// No description provided for @devicesLinked.
  ///
  /// In es, this message translates to:
  /// **'Este dispositivo está vinculado. Revoca dispositivos desde el perfil administrador.'**
  String get devicesLinked;

  /// No description provided for @devicesManifestVersion.
  ///
  /// In es, this message translates to:
  /// **'Versión local del manifiesto: {sequence}'**
  String devicesManifestVersion(String sequence);

  /// No description provided for @devicesPartialInventory.
  ///
  /// In es, this message translates to:
  /// **'Inventario parcial: el manifiesto incluye {active} credenciales autorizadas y {revoked} revocadas cuyos identificadores de dispositivo no conoce este perfil. Consulta el administrador para gestionarlas.'**
  String devicesPartialInventory(int active, int revoked);

  /// No description provided for @devicesThis.
  ///
  /// In es, this message translates to:
  /// **'Este dispositivo'**
  String get devicesThis;

  /// No description provided for @devicesLinkedDevice.
  ///
  /// In es, this message translates to:
  /// **'Dispositivo vinculado'**
  String get devicesLinkedDevice;

  /// No description provided for @devicesRevokedLocally.
  ///
  /// In es, this message translates to:
  /// **'Revocado según el estado local'**
  String get devicesRevokedLocally;

  /// No description provided for @devicesNotRevoked.
  ///
  /// In es, this message translates to:
  /// **'No consta revocado en este perfil'**
  String get devicesNotRevoked;

  /// No description provided for @devicesRevocationAccepted.
  ///
  /// In es, this message translates to:
  /// **'Revocación aceptada por el servidor'**
  String get devicesRevocationAccepted;

  /// No description provided for @devicesRevocationPending.
  ///
  /// In es, this message translates to:
  /// **'Pendiente de publicar la revocación en el servidor'**
  String get devicesRevocationPending;

  /// No description provided for @devicesGroupsWaiting.
  ///
  /// In es, this message translates to:
  /// **'Conversaciones locales pendientes de retirarlo: {count}'**
  String devicesGroupsWaiting(int count);

  /// No description provided for @devicesGroupsWaitingHelp.
  ///
  /// In es, this message translates to:
  /// **'Sincroniza para recibir los cambios. La retirada corresponde al dispositivo que coordina los cambios del grupo; mientras tanto, el envío permanece bloqueado en quienes conocen la revocación.'**
  String get devicesGroupsWaitingHelp;

  /// No description provided for @devicesNoticesPending.
  ///
  /// In es, this message translates to:
  /// **'Avisos pendientes de publicar: {count}'**
  String devicesNoticesPending(int count);

  /// No description provided for @devicesNoticesUnconfirmed.
  ///
  /// In es, this message translates to:
  /// **'Avisos rechazados o caducados sin confirmación: {count}. Comprueba el estado con los otros participantes.'**
  String devicesNoticesUnconfirmed(int count);

  /// No description provided for @devicesNoticesWithoutRoute.
  ///
  /// In es, this message translates to:
  /// **'Avisos que no pudieron prepararse por falta de ruta: {count}. Requieren revisar las rutas; no se reenvían automáticamente.'**
  String devicesNoticesWithoutRoute(int count);

  /// No description provided for @devicesAcceptanceCaveat.
  ///
  /// In es, this message translates to:
  /// **'La aceptación del servidor no confirma que los demás dispositivos hayan recibido el aviso.'**
  String get devicesAcceptanceCaveat;

  /// No description provided for @devicesRevoke.
  ///
  /// In es, this message translates to:
  /// **'Revocar dispositivo'**
  String get devicesRevoke;

  /// No description provided for @pairingTitle.
  ///
  /// In es, this message translates to:
  /// **'Vincular este dispositivo'**
  String get pairingTitle;

  /// No description provided for @pairingExplanation.
  ///
  /// In es, this message translates to:
  /// **'Usa tu dispositivo administrador para autorizar este perfil. La vinculación conserva tu identidad; no copia el historial anterior.'**
  String get pairingExplanation;

  /// No description provided for @pairingRelayLabel.
  ///
  /// In es, this message translates to:
  /// **'Datos del servidor'**
  String get pairingRelayLabel;

  /// No description provided for @pairingRelayInvalid.
  ///
  /// In es, this message translates to:
  /// **'Pega los datos completos del servidor.'**
  String get pairingRelayInvalid;

  /// No description provided for @pairingGenerate.
  ///
  /// In es, this message translates to:
  /// **'Generar código de vinculación'**
  String get pairingGenerate;

  /// No description provided for @pairingConfirmationSaved.
  ///
  /// In es, this message translates to:
  /// **'La confirmación está guardada. Falta terminar la configuración en el servidor.'**
  String get pairingConfirmationSaved;

  /// No description provided for @pairingResumeFinish.
  ///
  /// In es, this message translates to:
  /// **'Reanudar finalización'**
  String get pairingResumeFinish;

  /// No description provided for @pairingExpired.
  ///
  /// In es, this message translates to:
  /// **'Esta sesión ha caducado. Cancélala y genera un código nuevo.'**
  String get pairingExpired;

  /// No description provided for @pairingComparisonCode.
  ///
  /// In es, this message translates to:
  /// **'Código de comparación'**
  String get pairingComparisonCode;

  /// No description provided for @pairingCompareHelp.
  ///
  /// In es, this message translates to:
  /// **'Comprueba ambas pantallas. Introduce aquí el código que muestra el dispositivo administrador. Si son distintos, cancela.'**
  String get pairingCompareHelp;

  /// No description provided for @pairingOtherCode.
  ///
  /// In es, this message translates to:
  /// **'Código del otro dispositivo'**
  String get pairingOtherCode;

  /// No description provided for @pairingConfirmComparison.
  ///
  /// In es, this message translates to:
  /// **'Confirmar comparación'**
  String get pairingConfirmComparison;

  /// No description provided for @pairingShareCode.
  ///
  /// In es, this message translates to:
  /// **'En el administrador, abre «Vincular otro dispositivo» y pega este código por un canal privado.'**
  String get pairingShareCode;

  /// No description provided for @pairingExpiresIn.
  ///
  /// In es, this message translates to:
  /// **'{seconds, plural, =1{Caduca en 1 segundo.} other{Caduca en {seconds} segundos.}}'**
  String pairingExpiresIn(int seconds);

  /// No description provided for @pairingWaiting.
  ///
  /// In es, this message translates to:
  /// **'Esperando al dispositivo administrador…'**
  String get pairingWaiting;

  /// No description provided for @pairingWaitInterrupted.
  ///
  /// In es, this message translates to:
  /// **'La espera se interrumpió. Cancela esta sesión y genera otro código; la comparación ya recibida se conserva al reabrir.'**
  String get pairingWaitInterrupted;

  /// No description provided for @pairingCancel.
  ///
  /// In es, this message translates to:
  /// **'Cancelar vinculación'**
  String get pairingCancel;

  /// No description provided for @pairingCancelNote.
  ///
  /// In es, this message translates to:
  /// **'Cancelar detiene este alta local. Si el administrador ya emitió una autorización, no la revoca.'**
  String get pairingCancelNote;

  /// No description provided for @pairingOtherTitle.
  ///
  /// In es, this message translates to:
  /// **'Vincular otro dispositivo'**
  String get pairingOtherTitle;

  /// No description provided for @pairingAdminCompare.
  ///
  /// In es, this message translates to:
  /// **'Compara este código con el del nuevo dispositivo e introdúcelo allí para terminar.'**
  String get pairingAdminCompare;

  /// No description provided for @pairingAuthorizationIssued.
  ///
  /// In es, this message translates to:
  /// **'Ya se ha emitido la autorización. Cerrar esta comparación no la revoca. Si no reconoces la solicitud, revoca ese dispositivo desde la CLI.'**
  String get pairingAuthorizationIssued;

  /// No description provided for @pairingCloseComparison.
  ///
  /// In es, this message translates to:
  /// **'Cerrar comparación'**
  String get pairingCloseComparison;

  /// No description provided for @pairingPasteOwnCode.
  ///
  /// In es, this message translates to:
  /// **'Pega únicamente el código de un dispositivo tuyo que tengas delante. Este paso emite su autorización.'**
  String get pairingPasteOwnCode;

  /// No description provided for @pairingCodeLabel.
  ///
  /// In es, this message translates to:
  /// **'Código de vinculación'**
  String get pairingCodeLabel;

  /// No description provided for @pairingCodeInvalid.
  ///
  /// In es, this message translates to:
  /// **'Pega el código de vinculación completo.'**
  String get pairingCodeInvalid;

  /// No description provided for @pairingAuthorize.
  ///
  /// In es, this message translates to:
  /// **'Autorizar y comparar'**
  String get pairingAuthorize;

  /// No description provided for @pairingKeepOpen.
  ///
  /// In es, this message translates to:
  /// **'Mantén ambos dispositivos abiertos durante la espera, de hasta 90 segundos.'**
  String get pairingKeepOpen;

  /// No description provided for @archiveFailed.
  ///
  /// In es, this message translates to:
  /// **'No se pudo completar la operación. Comprueba el archivo, su clave y que pertenece a tu identidad. Máximo 10.000 registros; exportación de hasta 48 MiB de contenido e importación de archivos de hasta 64 MiB.'**
  String get archiveFailed;

  /// No description provided for @archiveSaved.
  ///
  /// In es, this message translates to:
  /// **'Archivo guardado: {records} registros, {files} adjuntos con copia, {missing} sin copia.'**
  String archiveSaved(int records, int files, int missing);

  /// No description provided for @archiveImported.
  ///
  /// In es, this message translates to:
  /// **'{imported} registros importados; {duplicates} ya existentes, conservados sin cambios.'**
  String archiveImported(int imported, int duplicates);

  /// No description provided for @archiveFileSaved.
  ///
  /// In es, this message translates to:
  /// **'Copia del adjunto guardada en el destino elegido.'**
  String get archiveFileSaved;

  /// No description provided for @archiveTitle.
  ///
  /// In es, this message translates to:
  /// **'Historial cifrado'**
  String get archiveTitle;

  /// No description provided for @archiveExplanation.
  ///
  /// In es, this message translates to:
  /// **'El historial cifrado recupera mensajes y adjuntos disponibles, sin recuperar la identidad ni las sesiones de grupo. Restaura primero tu identidad con su kit si has perdido el dispositivo.'**
  String get archiveExplanation;

  /// No description provided for @archiveKeepApart.
  ///
  /// In es, this message translates to:
  /// **'Guarda el archivo y su clave por separado. Juntos permiten leer esta copia del pasado. No se descargan adjuntos pendientes; los archivos antiguos de la CLI pueden figurar sin copia.'**
  String get archiveKeepApart;

  /// No description provided for @archiveConsent.
  ///
  /// In es, this message translates to:
  /// **'Entiendo que esta copia permite leer el historial'**
  String get archiveConsent;

  /// No description provided for @archiveSave.
  ///
  /// In es, this message translates to:
  /// **'Guardar historial cifrado'**
  String get archiveSave;

  /// No description provided for @archiveRevealKey.
  ///
  /// In es, this message translates to:
  /// **'Mostrar clave del archivo guardado'**
  String get archiveRevealKey;

  /// No description provided for @archiveKeyNote.
  ///
  /// In es, this message translates to:
  /// **'Guarda esta clave por separado. Desaparece al salir o cambiar de aplicación; Arveil no la conserva.'**
  String get archiveKeyNote;

  /// No description provided for @archiveKeySaved.
  ///
  /// In es, this message translates to:
  /// **'He guardado la clave'**
  String get archiveKeySaved;

  /// No description provided for @archiveImportTitle.
  ///
  /// In es, this message translates to:
  /// **'Importar historial'**
  String get archiveImportTitle;

  /// No description provided for @archiveImportNote.
  ///
  /// In es, this message translates to:
  /// **'Solo se acepta un archivo de esta identidad. Los registros se añaden como historial de solo lectura: no se reenvían ni dan acceso a los grupos. Un archivo importado no demuestra la autoría de sus mensajes.'**
  String get archiveImportNote;

  /// No description provided for @archiveChooseFile.
  ///
  /// In es, this message translates to:
  /// **'Elegir archivo cifrado'**
  String get archiveChooseFile;

  /// No description provided for @archiveFileChosen.
  ///
  /// In es, this message translates to:
  /// **'Archivo seleccionado; cambiar'**
  String get archiveFileChosen;

  /// No description provided for @archiveKeyLabel.
  ///
  /// In es, this message translates to:
  /// **'Clave del archivo'**
  String get archiveKeyLabel;

  /// No description provided for @archiveImport.
  ///
  /// In es, this message translates to:
  /// **'Importar como historial'**
  String get archiveImport;

  /// No description provided for @archiveImportedTitle.
  ///
  /// In es, this message translates to:
  /// **'Historial importado · solo lectura'**
  String get archiveImportedTitle;

  /// No description provided for @archiveEmpty.
  ///
  /// In es, this message translates to:
  /// **'Todavía no hay registros importados.'**
  String get archiveEmpty;

  /// No description provided for @archiveEntryOutgoing.
  ///
  /// In es, this message translates to:
  /// **'Grupo {group} · Saliente'**
  String archiveEntryOutgoing(String group);

  /// No description provided for @archiveEntryIncoming.
  ///
  /// In es, this message translates to:
  /// **'Grupo {group} · Entrante'**
  String archiveEntryIncoming(String group);

  /// No description provided for @archiveEntrySender.
  ///
  /// In es, this message translates to:
  /// **'{header} · {sender}, según el archivo'**
  String archiveEntrySender(String header, String sender);

  /// No description provided for @archiveNoFileCopy.
  ///
  /// In es, this message translates to:
  /// **'Sin copia del adjunto en este archivo'**
  String get archiveNoFileCopy;

  /// No description provided for @archiveSaveFileCopy.
  ///
  /// In es, this message translates to:
  /// **'Guardar copia del adjunto'**
  String get archiveSaveFileCopy;

  /// No description provided for @archiveOlder.
  ///
  /// In es, this message translates to:
  /// **'Ver registros anteriores'**
  String get archiveOlder;

  /// No description provided for @archiveBackToStart.
  ///
  /// In es, this message translates to:
  /// **'Volver al inicio del historial'**
  String get archiveBackToStart;

  /// No description provided for @contactsReadFailed.
  ///
  /// In es, this message translates to:
  /// **'No se pudieron leer los contactos. Vuelve a intentarlo.'**
  String get contactsReadFailed;

  /// No description provided for @contactsChoose.
  ///
  /// In es, this message translates to:
  /// **'Elegir contactos'**
  String get contactsChoose;

  /// No description provided for @contactsTitle.
  ///
  /// In es, this message translates to:
  /// **'Contactos'**
  String get contactsTitle;

  /// No description provided for @contactAdd.
  ///
  /// In es, this message translates to:
  /// **'Añadir contacto'**
  String get contactAdd;

  /// No description provided for @retry.
  ///
  /// In es, this message translates to:
  /// **'Reintentar'**
  String get retry;

  /// No description provided for @contactsNamesLocal.
  ///
  /// In es, this message translates to:
  /// **'Los nombres son locales. Comprueba la identidad comparando el número de seguridad por otro canal.'**
  String get contactsNamesLocal;

  /// No description provided for @contactsDeviceLimit.
  ///
  /// In es, this message translates to:
  /// **'Se incluirán los dispositivos guardados que no consten como revocados. Máximo: 16 dispositivos.'**
  String get contactsDeviceLimit;

  /// No description provided for @contactsEmpty.
  ///
  /// In es, this message translates to:
  /// **'Todavía no tienes contactos guardados.'**
  String get contactsEmpty;

  /// No description provided for @verified.
  ///
  /// In es, this message translates to:
  /// **'Verificado'**
  String get verified;

  /// No description provided for @unverified.
  ///
  /// In es, this message translates to:
  /// **'Sin verificar'**
  String get unverified;

  /// No description provided for @contactNeedsRoute.
  ///
  /// In es, this message translates to:
  /// **'Añade una ruta para conversar'**
  String get contactNeedsRoute;

  /// No description provided for @contactDevicesAvailable.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{1 dispositivo disponible} other{{count} dispositivos disponibles}}'**
  String contactDevicesAvailable(int count);

  /// No description provided for @contactsTooMany.
  ///
  /// In es, this message translates to:
  /// **'Selecciona como máximo 16 dispositivos.'**
  String get contactsTooMany;

  /// No description provided for @contactsUse.
  ///
  /// In es, this message translates to:
  /// **'Usar contactos ({count})'**
  String contactsUse(int count);

  /// No description provided for @contactRouteInvalid.
  ///
  /// In es, this message translates to:
  /// **'Revisa la ruta completa del contacto. Debe ser de otro dispositivo.'**
  String get contactRouteInvalid;

  /// No description provided for @contactSaved.
  ///
  /// In es, this message translates to:
  /// **'Contacto guardado en este perfil.'**
  String get contactSaved;

  /// No description provided for @contactSaveFailed.
  ///
  /// In es, this message translates to:
  /// **'No se pudo guardar. Revisa el nombre y la comparación; conserva el perfil y vuelve a intentarlo.'**
  String get contactSaveFailed;

  /// No description provided for @contactVerifiedNotice.
  ///
  /// In es, this message translates to:
  /// **'Identidad verificada.'**
  String get contactVerifiedNotice;

  /// No description provided for @contactVerifyFailed.
  ///
  /// In es, this message translates to:
  /// **'La comparación no se pudo confirmar. Reabre el contacto y compara el número de nuevo.'**
  String get contactVerifyFailed;

  /// No description provided for @contactDetails.
  ///
  /// In es, this message translates to:
  /// **'Datos del contacto'**
  String get contactDetails;

  /// No description provided for @contactNameLabel.
  ///
  /// In es, this message translates to:
  /// **'Nombre local (opcional)'**
  String get contactNameLabel;

  /// No description provided for @contactNameHelper.
  ///
  /// In es, this message translates to:
  /// **'Solo se guarda en este perfil. No verifica la identidad.'**
  String get contactNameHelper;

  /// No description provided for @contactRouteLabel.
  ///
  /// In es, this message translates to:
  /// **'Ruta de contacto'**
  String get contactRouteLabel;

  /// No description provided for @contactRouteHelper.
  ///
  /// In es, this message translates to:
  /// **'Pide la ruta de este servidor a la persona que quieres añadir.'**
  String get contactRouteHelper;

  /// No description provided for @contactPrepare.
  ///
  /// In es, this message translates to:
  /// **'Preparar contacto'**
  String get contactPrepare;

  /// No description provided for @contactIdentity.
  ///
  /// In es, this message translates to:
  /// **'Identidad {identity}'**
  String contactIdentity(String identity);

  /// No description provided for @contactCompareHelp.
  ///
  /// In es, this message translates to:
  /// **'Compara este número con la otra persona por otro canal. El nombre local no sustituye esta comprobación.'**
  String get contactCompareHelp;

  /// No description provided for @contactRoutes.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{1 ruta guardada} other{{count} rutas guardadas}}'**
  String contactRoutes(int count);

  /// No description provided for @contactDevice.
  ///
  /// In es, this message translates to:
  /// **'Dispositivo {id}'**
  String contactDevice(String id);

  /// No description provided for @contactDeviceRevoked.
  ///
  /// In es, this message translates to:
  /// **'Dispositivo {id} · Revocado'**
  String contactDeviceRevoked(String id);

  /// No description provided for @contactUpdateRoute.
  ///
  /// In es, this message translates to:
  /// **'Para añadir o actualizar una ruta, vuelve a Añadir contacto. Comprueba que la identidad coincide y conserva el nombre que quieras usar.'**
  String get contactUpdateRoute;

  /// No description provided for @contactSave.
  ///
  /// In es, this message translates to:
  /// **'Guardar contacto'**
  String get contactSave;

  /// No description provided for @contactSaveName.
  ///
  /// In es, this message translates to:
  /// **'Guardar nombre'**
  String get contactSaveName;

  /// A date in digits, in the order the language writes it.
  ///
  /// In es, this message translates to:
  /// **'{day}/{month}/{year}'**
  String numericDate(String day, String month, String year);

  /// No description provided for @noticeAdded.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{ha añadido un dispositivo} other{ha añadido {count} dispositivos}}'**
  String noticeAdded(int count);

  /// No description provided for @noticeRemoved.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{ha retirado un dispositivo} other{ha retirado {count} dispositivos}}'**
  String noticeRemoved(int count);

  /// No description provided for @noticeBoth.
  ///
  /// In es, this message translates to:
  /// **'{first} y {second}'**
  String noticeBoth(String first, String second);

  /// Who changed which devices, e.g. «Lucía ha añadido un dispositivo.»
  ///
  /// In es, this message translates to:
  /// **'{who} {change}.'**
  String noticeSentence(String who, String change);

  /// No description provided for @noticeSomeone.
  ///
  /// In es, this message translates to:
  /// **'Un contacto'**
  String get noticeSomeone;

  /// No description provided for @previewAttachment.
  ///
  /// In es, this message translates to:
  /// **'Adjunto: {name}'**
  String previewAttachment(String name);

  /// No description provided for @previewOwn.
  ///
  /// In es, this message translates to:
  /// **'Tú: {text}'**
  String previewOwn(String text);

  /// No description provided for @conversationEvent.
  ///
  /// In es, this message translates to:
  /// **'Evento de conversación'**
  String get conversationEvent;

  /// No description provided for @conversationFallback.
  ///
  /// In es, this message translates to:
  /// **'Conversación {id}'**
  String conversationFallback(String id);

  /// No description provided for @sendFile.
  ///
  /// In es, this message translates to:
  /// **'Enviar archivo'**
  String get sendFile;

  /// No description provided for @attachConfirm.
  ///
  /// In es, this message translates to:
  /// **'{name}\n{size}\n\nConversación: {conversation}\n\nSe guardará una copia privada cifrada para completar o reanudar el envío.'**
  String attachConfirm(String name, String size, String conversation);

  /// No description provided for @fileReadFailed.
  ///
  /// In es, this message translates to:
  /// **'No se pudo leer el archivo. Elige uno accesible que ocupe menos de 25 MiB.'**
  String get fileReadFailed;

  /// No description provided for @exportTitle.
  ///
  /// In es, this message translates to:
  /// **'Guardar copia fuera de Arveil'**
  String get exportTitle;

  /// No description provided for @exportWarning.
  ///
  /// In es, this message translates to:
  /// **'La copia quedará fuera del perfil cifrado de Arveil y puede entrar en las copias de seguridad del destino. Elige dónde guardarla.'**
  String get exportWarning;

  /// No description provided for @exportChoose.
  ///
  /// In es, this message translates to:
  /// **'Elegir destino'**
  String get exportChoose;

  /// No description provided for @exportSaved.
  ///
  /// In es, this message translates to:
  /// **'Copia guardada en el destino elegido.'**
  String get exportSaved;

  /// No description provided for @exportFailed.
  ///
  /// In es, this message translates to:
  /// **'No se pudo guardar la copia. El archivo privado se conserva; vuelve a intentarlo.'**
  String get exportFailed;

  /// No description provided for @participants.
  ///
  /// In es, this message translates to:
  /// **'Participantes'**
  String get participants;

  /// No description provided for @participantsYou.
  ///
  /// In es, this message translates to:
  /// **'Tu identidad'**
  String get participantsYou;

  /// No description provided for @identityDevice.
  ///
  /// In es, this message translates to:
  /// **'Identidad {identity} · dispositivo {device}'**
  String identityDevice(String identity, String device);

  /// No description provided for @revoked.
  ///
  /// In es, this message translates to:
  /// **'Revocado'**
  String get revoked;

  /// No description provided for @close.
  ///
  /// In es, this message translates to:
  /// **'Cerrar'**
  String get close;

  /// No description provided for @ownRouteTitle.
  ///
  /// In es, this message translates to:
  /// **'Tu ruta de contacto'**
  String get ownRouteTitle;

  /// No description provided for @ownRouteShare.
  ///
  /// In es, this message translates to:
  /// **'Compártela solo con las personas que quieras que puedan escribir a este dispositivo. Comparad después el número de seguridad por otro canal.'**
  String get ownRouteShare;

  /// No description provided for @ownRouteCopy.
  ///
  /// In es, this message translates to:
  /// **'Copiar ruta'**
  String get ownRouteCopy;

  /// No description provided for @ownRouteFailed.
  ///
  /// In es, this message translates to:
  /// **'No se pudo obtener la ruta de este dispositivo.'**
  String get ownRouteFailed;

  /// No description provided for @backToConversations.
  ///
  /// In es, this message translates to:
  /// **'Volver a conversaciones'**
  String get backToConversations;

  /// No description provided for @newConversation.
  ///
  /// In es, this message translates to:
  /// **'Nueva conversación'**
  String get newConversation;

  /// No description provided for @sync.
  ///
  /// In es, this message translates to:
  /// **'Sincronizar'**
  String get sync;

  /// No description provided for @syncing.
  ///
  /// In es, this message translates to:
  /// **'Sincronizando'**
  String get syncing;

  /// No description provided for @chooseConversation.
  ///
  /// In es, this message translates to:
  /// **'Elige una conversación para leerla.'**
  String get chooseConversation;

  /// No description provided for @conversationsEmpty.
  ///
  /// In es, this message translates to:
  /// **'Todavía no hay conversaciones guardadas.'**
  String get conversationsEmpty;

  /// No description provided for @conversationsEmptyHelp.
  ///
  /// In es, this message translates to:
  /// **'Crea una con una ruta de contacto o sincroniza para recibir una invitación.'**
  String get conversationsEmptyHelp;

  /// No description provided for @conversationCounts.
  ///
  /// In es, this message translates to:
  /// **'{devices, plural, =1{1 dispositivo} other{{devices} dispositivos}} · {messages, plural, =1{1 mensaje} other{{messages} mensajes}}'**
  String conversationCounts(int devices, int messages);

  /// No description provided for @unreadMessages.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{1 mensaje sin leer} other{{count} mensajes sin leer}}'**
  String unreadMessages(int count);

  /// No description provided for @savingMessage.
  ///
  /// In es, this message translates to:
  /// **'Guardando mensaje'**
  String get savingMessage;

  /// No description provided for @firstMessage.
  ///
  /// In es, this message translates to:
  /// **'Escribe el primer mensaje.'**
  String get firstMessage;

  /// No description provided for @reading.
  ///
  /// In es, this message translates to:
  /// **'Leyendo…'**
  String get reading;

  /// No description provided for @loadOlder.
  ///
  /// In es, this message translates to:
  /// **'Cargar anteriores'**
  String get loadOlder;

  /// No description provided for @attachFile.
  ///
  /// In es, this message translates to:
  /// **'Adjuntar archivo'**
  String get attachFile;

  /// No description provided for @messageHint.
  ///
  /// In es, this message translates to:
  /// **'Mensaje'**
  String get messageHint;

  /// No description provided for @send.
  ///
  /// In es, this message translates to:
  /// **'Enviar'**
  String get send;

  /// No description provided for @noticeSigned.
  ///
  /// In es, this message translates to:
  /// **'El cambio está firmado por su identidad verificada.'**
  String get noticeSigned;

  /// No description provided for @noticeCompare.
  ///
  /// In es, this message translates to:
  /// **'Compara su número de seguridad si no esperabas este cambio.'**
  String get noticeCompare;

  /// No description provided for @legacyAttachment.
  ///
  /// In es, this message translates to:
  /// **'Adjunto (consulta disponible desde la CLI)'**
  String get legacyAttachment;

  /// No description provided for @sentFromOtherDevice.
  ///
  /// In es, this message translates to:
  /// **'Enviado desde otro de tus dispositivos'**
  String get sentFromOtherDevice;

  /// No description provided for @receivedHere.
  ///
  /// In es, this message translates to:
  /// **'Recibido en este dispositivo'**
  String get receivedHere;

  /// No description provided for @newConversationRoutesInvalid.
  ///
  /// In es, this message translates to:
  /// **'Revisa las rutas completas: entre uno y dieciséis dispositivos distintos, sin incluir este dispositivo.'**
  String get newConversationRoutesInvalid;

  /// No description provided for @newConversationChooseContacts.
  ///
  /// In es, this message translates to:
  /// **'Elegir contactos guardados'**
  String get newConversationChooseContacts;

  /// No description provided for @newConversationRoutesHelp.
  ///
  /// In es, this message translates to:
  /// **'O utiliza una ruta nueva. Pide a tus contactos su ruta de este servidor. Pega una ruta por línea y compara el número de seguridad con cada persona por otro canal antes de crear el grupo.'**
  String get newConversationRoutesHelp;

  /// No description provided for @newConversationRoutesLabel.
  ///
  /// In es, this message translates to:
  /// **'Rutas de contacto'**
  String get newConversationRoutesLabel;

  /// No description provided for @newConversationPrepare.
  ///
  /// In es, this message translates to:
  /// **'Preparar comparación'**
  String get newConversationPrepare;

  /// No description provided for @newConversationCompared.
  ///
  /// In es, this message translates to:
  /// **'Hemos comparado todos los números por otro canal y coinciden.'**
  String get newConversationCompared;

  /// No description provided for @newConversationCreate.
  ///
  /// In es, this message translates to:
  /// **'Crear conversación'**
  String get newConversationCreate;

  /// No description provided for @deliveryNone.
  ///
  /// In es, this message translates to:
  /// **'Guardado solo en este dispositivo: no hay destinatarios disponibles'**
  String get deliveryNone;

  /// No description provided for @deliveryWaiting.
  ///
  /// In es, this message translates to:
  /// **'Pendiente de envío'**
  String get deliveryWaiting;

  /// No description provided for @deliveryAcceptedShort.
  ///
  /// In es, this message translates to:
  /// **'Aceptado por el servidor'**
  String get deliveryAcceptedShort;

  /// No description provided for @safetyNumberLabel.
  ///
  /// In es, this message translates to:
  /// **'Número de seguridad: {groups}'**
  String safetyNumberLabel(String groups);

  /// No description provided for @today.
  ///
  /// In es, this message translates to:
  /// **'Hoy'**
  String get today;

  /// No description provided for @yesterday.
  ///
  /// In es, this message translates to:
  /// **'Ayer'**
  String get yesterday;

  /// No description provided for @chatSearchHint.
  ///
  /// In es, this message translates to:
  /// **'Buscar chats'**
  String get chatSearchHint;

  /// No description provided for @chatSearchClear.
  ///
  /// In es, this message translates to:
  /// **'Borrar la búsqueda'**
  String get chatSearchClear;

  /// No description provided for @chatSearchNone.
  ///
  /// In es, this message translates to:
  /// **'Ningún chat coincide con «{query}»'**
  String chatSearchNone(String query);

  /// No description provided for @kitReminderTitle.
  ///
  /// In es, this message translates to:
  /// **'Guarda tu kit de identidad'**
  String get kitReminderTitle;

  /// No description provided for @kitReminderStaleTitle.
  ///
  /// In es, this message translates to:
  /// **'Actualiza tu kit de identidad'**
  String get kitReminderStaleTitle;

  /// No description provided for @recoveryWarningTitle.
  ///
  /// In es, this message translates to:
  /// **'Comprueba las revocaciones'**
  String get recoveryWarningTitle;

  /// No description provided for @offlineTitle.
  ///
  /// In es, this message translates to:
  /// **'Sin conexión'**
  String get offlineTitle;

  /// No description provided for @syncRefusedTitle.
  ///
  /// In es, this message translates to:
  /// **'Sincronización rechazada'**
  String get syncRefusedTitle;

  /// No description provided for @conversationDetails.
  ///
  /// In es, this message translates to:
  /// **'Detalles de la conversación'**
  String get conversationDetails;

  /// No description provided for @conversationPeople.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{1 persona} other{{count} personas}}'**
  String conversationPeople(int count);

  /// No description provided for @detailsFiles.
  ///
  /// In es, this message translates to:
  /// **'Archivos'**
  String get detailsFiles;

  /// No description provided for @detailsNoFiles.
  ///
  /// In es, this message translates to:
  /// **'No hay archivos en el historial cargado.'**
  String get detailsNoFiles;

  /// No description provided for @messageDetails.
  ///
  /// In es, this message translates to:
  /// **'Detalles del mensaje'**
  String get messageDetails;

  /// No description provided for @messageRecordedAt.
  ///
  /// In es, this message translates to:
  /// **'Registrado en este dispositivo: {when}'**
  String messageRecordedAt(String when);

  /// No description provided for @deliveryPerMailbox.
  ///
  /// In es, this message translates to:
  /// **'Entrega por buzón'**
  String get deliveryPerMailbox;

  /// No description provided for @mailboxNumber.
  ///
  /// In es, this message translates to:
  /// **'Buzón {number}'**
  String mailboxNumber(int number);

  /// No description provided for @mailboxRejected.
  ///
  /// In es, this message translates to:
  /// **'El buzón rechazó el mensaje'**
  String get mailboxRejected;

  /// No description provided for @copyText.
  ///
  /// In es, this message translates to:
  /// **'Copiar texto'**
  String get copyText;

  /// No description provided for @textCopied.
  ///
  /// In es, this message translates to:
  /// **'Texto copiado'**
  String get textCopied;

  /// No description provided for @devicesCount.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{1 dispositivo} other{{count} dispositivos}}'**
  String devicesCount(int count);

  /// No description provided for @settingsSecurity.
  ///
  /// In es, this message translates to:
  /// **'Seguridad y recuperación'**
  String get settingsSecurity;

  /// No description provided for @settingsConnection.
  ///
  /// In es, this message translates to:
  /// **'Conexión'**
  String get settingsConnection;

  /// No description provided for @settingsApp.
  ///
  /// In es, this message translates to:
  /// **'Aplicación'**
  String get settingsApp;

  /// No description provided for @kitStateNever.
  ///
  /// In es, this message translates to:
  /// **'Sin guardar'**
  String get kitStateNever;

  /// No description provided for @kitStateStale.
  ///
  /// In es, this message translates to:
  /// **'Desactualizado: tus dispositivos cambiaron'**
  String get kitStateStale;

  /// No description provided for @kitStateSaved.
  ///
  /// In es, this message translates to:
  /// **'Guardado el {date}'**
  String kitStateSaved(String date);

  /// No description provided for @identityAdministrator.
  ///
  /// In es, this message translates to:
  /// **'Este dispositivo administra tus dispositivos'**
  String get identityAdministrator;

  /// No description provided for @identityLinked.
  ///
  /// In es, this message translates to:
  /// **'Dispositivo vinculado'**
  String get identityLinked;

  /// No description provided for @shareMyRouteHelp.
  ///
  /// In es, this message translates to:
  /// **'Para que otras personas puedan añadirte'**
  String get shareMyRouteHelp;

  /// No description provided for @licenses.
  ///
  /// In es, this message translates to:
  /// **'Licencias'**
  String get licenses;

  /// No description provided for @safetyNumberTitle.
  ///
  /// In es, this message translates to:
  /// **'Número de seguridad'**
  String get safetyNumberTitle;

  /// No description provided for @numbersMatch.
  ///
  /// In es, this message translates to:
  /// **'Coinciden'**
  String get numbersMatch;

  /// No description provided for @numbersDiffer.
  ///
  /// In es, this message translates to:
  /// **'No coinciden'**
  String get numbersDiffer;

  /// No description provided for @mismatchTitle.
  ///
  /// In es, this message translates to:
  /// **'Los números no coinciden'**
  String get mismatchTitle;

  /// No description provided for @mismatchBody.
  ///
  /// In es, this message translates to:
  /// **'No verifiques este contacto. La ruta puede no ser de esa persona o haber cambiado: pídele que te la envíe otra vez por otro canal.'**
  String get mismatchBody;

  /// No description provided for @comparedWillVerify.
  ///
  /// In es, this message translates to:
  /// **'Coinciden: el contacto se guardará como verificado.'**
  String get comparedWillVerify;

  /// No description provided for @startTitle.
  ///
  /// In es, this message translates to:
  /// **'¿Cómo quieres empezar?'**
  String get startTitle;

  /// No description provided for @startBody.
  ///
  /// In es, this message translates to:
  /// **'Tu identidad se crea en este dispositivo y solo tú la guardas.'**
  String get startBody;

  /// No description provided for @entryInvitation.
  ///
  /// In es, this message translates to:
  /// **'Unirme con una invitación'**
  String get entryInvitation;

  /// No description provided for @entryInvitationHelp.
  ///
  /// In es, this message translates to:
  /// **'Con los datos del servidor y la invitación que te dieron.'**
  String get entryInvitationHelp;

  /// No description provided for @entryPairingHelp.
  ///
  /// In es, this message translates to:
  /// **'Tu dispositivo administrador autoriza este.'**
  String get entryPairingHelp;

  /// No description provided for @entryRestoreHelp.
  ///
  /// In es, this message translates to:
  /// **'Recupera tu identidad con el kit y su clave.'**
  String get entryRestoreHelp;

  /// No description provided for @enrollStep.
  ///
  /// In es, this message translates to:
  /// **'Paso {step} de {total}'**
  String enrollStep(int step, int total);

  /// No description provided for @enrollServerTitle.
  ///
  /// In es, this message translates to:
  /// **'Datos del servidor'**
  String get enrollServerTitle;

  /// No description provided for @enrollNext.
  ///
  /// In es, this message translates to:
  /// **'Siguiente'**
  String get enrollNext;

  /// No description provided for @enrollPrevious.
  ///
  /// In es, this message translates to:
  /// **'Atrás'**
  String get enrollPrevious;

  /// No description provided for @enrollInviteTitle.
  ///
  /// In es, this message translates to:
  /// **'Tu invitación'**
  String get enrollInviteTitle;

  /// No description provided for @enrollInviteBody.
  ///
  /// In es, this message translates to:
  /// **'Pega la invitación de 64 caracteres que te dio el administrador.'**
  String get enrollInviteBody;

  /// No description provided for @kitOfferTitle.
  ///
  /// In es, this message translates to:
  /// **'Guarda ahora tu kit de identidad'**
  String get kitOfferTitle;

  /// No description provided for @kitOfferRiskTitle.
  ///
  /// In es, this message translates to:
  /// **'Si lo dejas para más tarde'**
  String get kitOfferRiskTitle;

  /// No description provided for @appearanceTitle.
  ///
  /// In es, this message translates to:
  /// **'Apariencia'**
  String get appearanceTitle;

  /// No description provided for @appearanceSummary.
  ///
  /// In es, this message translates to:
  /// **'Tema, color, fondo, tamaño del texto e idioma'**
  String get appearanceSummary;

  /// No description provided for @themeTitle.
  ///
  /// In es, this message translates to:
  /// **'Tema'**
  String get themeTitle;

  /// No description provided for @themeSystem.
  ///
  /// In es, this message translates to:
  /// **'Sistema'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In es, this message translates to:
  /// **'Claro'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In es, this message translates to:
  /// **'Oscuro'**
  String get themeDark;

  /// No description provided for @accentTitle.
  ///
  /// In es, this message translates to:
  /// **'Color de acento'**
  String get accentTitle;

  /// No description provided for @accentPine.
  ///
  /// In es, this message translates to:
  /// **'Pino'**
  String get accentPine;

  /// No description provided for @accentLake.
  ///
  /// In es, this message translates to:
  /// **'Lago'**
  String get accentLake;

  /// No description provided for @accentPlum.
  ///
  /// In es, this message translates to:
  /// **'Ciruela'**
  String get accentPlum;

  /// No description provided for @accentClay.
  ///
  /// In es, this message translates to:
  /// **'Arcilla'**
  String get accentClay;

  /// No description provided for @accentMoss.
  ///
  /// In es, this message translates to:
  /// **'Musgo'**
  String get accentMoss;

  /// No description provided for @accentSlate.
  ///
  /// In es, this message translates to:
  /// **'Pizarra'**
  String get accentSlate;

  /// No description provided for @wallpaperTitle.
  ///
  /// In es, this message translates to:
  /// **'Fondo de la conversación'**
  String get wallpaperTitle;

  /// No description provided for @wallpaperPlain.
  ///
  /// In es, this message translates to:
  /// **'Liso'**
  String get wallpaperPlain;

  /// No description provided for @wallpaperArcs.
  ///
  /// In es, this message translates to:
  /// **'Arcos'**
  String get wallpaperArcs;

  /// No description provided for @wallpaperDots.
  ///
  /// In es, this message translates to:
  /// **'Puntos'**
  String get wallpaperDots;

  /// No description provided for @wallpaperWaves.
  ///
  /// In es, this message translates to:
  /// **'Ondas'**
  String get wallpaperWaves;

  /// No description provided for @wallpaperDiamonds.
  ///
  /// In es, this message translates to:
  /// **'Rombos'**
  String get wallpaperDiamonds;

  /// No description provided for @textSizeTitle.
  ///
  /// In es, this message translates to:
  /// **'Tamaño del texto'**
  String get textSizeTitle;

  /// No description provided for @textSizeValue.
  ///
  /// In es, this message translates to:
  /// **'{percent} %'**
  String textSizeValue(int percent);

  /// No description provided for @textSizeHelp.
  ///
  /// In es, this message translates to:
  /// **'Se aplica sobre el tamaño de texto del sistema.'**
  String get textSizeHelp;

  /// No description provided for @languageTitle.
  ///
  /// In es, this message translates to:
  /// **'Idioma'**
  String get languageTitle;

  /// No description provided for @languageSystem.
  ///
  /// In es, this message translates to:
  /// **'Idioma del sistema'**
  String get languageSystem;

  /// No description provided for @sampleReceived.
  ///
  /// In es, this message translates to:
  /// **'¿Quedamos el sábado?'**
  String get sampleReceived;

  /// No description provided for @sampleOwn.
  ///
  /// In es, this message translates to:
  /// **'¡Perfecto! Llevo el postre.'**
  String get sampleOwn;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
