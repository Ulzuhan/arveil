# Instalar y probar Arveil

[English](../INSTALLATION.md).

¿Solo te han invitado a un realm? La web tiene una guía más corta pensada
para ti: [Instalar Arveil](https://arveil.kaicorplabs.com/es/instalar/).
Esta página es la referencia completa, también para poner en marcha un relay
y compilar desde el código.

**Disponibilidad actual (1 de octubre de 2026):** [beta 6, 0.1.0+27](https://github.com/Ulzuhan/arveil/releases/tag/clients-v0.1.0-beta.6) ofrece ZIP macOS ARM64 y APK Android ARM64, sumas, metadatos y anuncio firmado (secuencia 8). Homebrew distribuye `0.1.0-beta.6,27`. Google Play ofrece la build 27 en pruebas internas, sin revisión de producción. Actualiza por el mismo canal, sin desinstalar ni borrar datos.

**Compatibilidad del servidor.** Los binarios públicos relay/CLI v0.1.0 son anteriores a `CredentialGet` y a las invitaciones personales. Para esta beta utiliza el relay de `e4011f3f2781aa48888d7da35114aa475d6ff71e` o una revisión posterior compatible y probada. El entorno de prueba ya está actualizado; la distribución versionada de relay/CLI y la matriz completa siguen en [#133](https://github.com/Ulzuhan/arveil/issues/133). Conserva copias consistentes antes de migrar. No abras bases de relay 5 o perfil 8 con binarios anteriores.

## Invitaciones personales en beta 6

**Invitar a alguien** reúne admisión y contacto en un enlace/QR privado. El emisor necesita permiso `owner`, concedido por el administrador del host a su identidad existente. El receptor instala la app, vuelve al enlace (o escanea/pega), revisa y acepta. Crea una identidad independiente y una conversación; un miembro del mismo servidor conserva su identidad. No se copia historial ni se verifica automáticamente al contacto. Sigue disponible el alta antigua por servidor/token.

[Invitaciones](INVITATIONS.md) explica permiso, migraciones y recuperación. La primera conversación llega al dispositivo que emitió el enlace cuando vuelve a sincronizar. La invitación no concede acceso al canal interno de Play: la persona necesita también ser tester. Tras instalar, debe volver al enlace original.

Los paquetes siguen siendo experimentales, sin auditoría independiente. La aceptación de cámara, instalación limpia y notificaciones en dispositivos reales sigue pendiente en [#134](https://github.com/Ulzuhan/arveil/issues/134) y [#140](https://github.com/Ulzuhan/arveil/issues/140). Consulta la [matriz de plataformas](PLATFORMS.md).

## Elige por dónde empezar

| Quiero… | Ruta disponible | Aceptación pendiente |
|---|---|---|
| Desplegar un relay | Código compatible de beta 6 con Docker Compose/Podman | Registrar instalación y actualización en un host limpio compatible; el cliente de código actual necesita un relay actualizado |
| Probar la app en macOS | ZIP beta 6 o Homebrew | Instalación limpia descargada en otro Mac y VoiceOver |
| Probar la app en Android | APK beta 6 o Play interno (tester autorizado) | Instalación/actualización en teléfono físico, cámara, enlaces, TalkBack y Doze/reconexión |
| Usar un iPhone | Hito posterior y separado | Aceptación nativa y firma/distribución compatible |

## Relay: primer arranque local con Docker Compose

Requisitos: Git, Docker y el complemento Docker Compose. Desde la raíz del
repositorio después de clonarlo:

```sh
git clone https://github.com/Ulzuhan/arveil.git
cd arveil
docker compose -f relay/compose.yaml up -d --build
docker compose -f relay/compose.yaml ps
docker compose -f relay/compose.yaml exec arveil-relay /arveil-relay healthcheck -admin http://127.0.0.1:9090
```

Si el relay funciona, la comprobación devuelve `ok`. Obtén los datos de
conexión y crea una invitación de un solo uso para un perfil de prueba:

```sh
docker compose -f relay/compose.yaml logs --no-log-prefix arveil-relay
docker compose -f relay/compose.yaml exec arveil-relay /arveil-relay invite -data-dir /data
```

`invite` imprime el token de la invitación y después una línea `link:`: un
único enlace https que lleva a la vez los datos del relay y la invitación
([ADR-012](adr/ADR-012-qr-codes-and-links.md)). En una terminal también dibuja
ese enlace como código QR. Comparte el enlace por un canal privado con la
persona prevista; pegado en el formulario de alta, o abierto en un teléfono
con la app instalada, rellena los dos campos. La invitación va detrás del `#`,
que los navegadores nunca envían a la página, así que no llega al registro de
ningún servidor web.

`-link-base` cambia la página que abre el enlace (por defecto
`https://arveil.kaicorplabs.com`), `-url` el endpoint que nombra (por defecto,
el primero que anuncia el relay en marcha) y `-qr` si se dibuja el QR (`auto`,
`always`, `never`). La forma anterior sigue funcionando: la línea `bootstrap:`
del registro y el token `invite:`, enviados juntos en un mensaje y pegados
enteros en los datos del servidor.

**La configuración predeterminada es solo local.** El puerto publicado y la
dirección anunciada usan loopback. En un teléfono, `127.0.0.1` es el propio
teléfono. Antes de probar desde otro dispositivo, configura un endpoint
alcanzable siguiendo [Poner en marcha un realm](OPERATIONS.md). La ruta privada
con SSH autenticado, Tailscale y Podman persistente sin root está en la
[guía de staging](../PODMAN.md). Todos los dispositivos deben poder acceder
a la red elegida.

Detén el relay local con `docker compose -f relay/compose.yaml stop` y arráncalo
con `up -d`. Los datos permanecen en su volumen. Antes de cambiar de versión,
sigue las instrucciones de [copias](OPERATIONS.md#copias-de-seguridad) y
[actualización](OPERATIONS.md#actualizaciones). Las copias contienen claves privadas
del realm.

## Instalar un paquete experimental

Las releases del cliente usan tags `clients-v…` e incluyen `BUILD-macos.json`,
`BUILD-android.json` y `SHA256SUMS-clients.txt`. Un candidato local de una sola
plataforma incluye `BUILD.json` y `SHA256SUMS.txt`.
Descarga el ZIP o APK de la
[beta 6](https://github.com/Ulzuhan/arveil/releases/tag/clients-v0.1.0-beta.6).
Para instalar estos paquetes no necesitas Flutter, Rust, Xcode ni Android Studio.

### macOS: Apple silicon, macOS 12 o posterior

1. Abre el archivo `macos-arm64.zip` y arrastra `arveil.app` a Aplicaciones.
2. Abre Arveil. Esta compilación tiene firma ad hoc y **no está notarizada por
   Apple**. Si macOS bloquea una descarga de confianza, usa **Abrir igualmente**
   para esta app en Ajustes del Sistema → Privacidad y seguridad, siguiendo las
   [instrucciones de Apple](https://support.apple.com/guide/mac-help/mh40616/mac).
3. Pulsa **Abrir perfil**. La clave se guarda en el llavero de inicio de sesión.
   Si macOS lo pide, autoriza el acceso de esta app; una recompilación puede
   volver a solicitarlo. Un llavero bloqueado o sin permiso se informa en la
   interfaz y no se sustituye por un archivo de clave en texto plano.
4. Pega los datos del relay y la invitación de un solo uso para completar el alta.

**Actualizar:** cierra Arveil, reemplaza la app en Aplicaciones por la nueva
versión y vuelve a abrirla. Conserva el perfil y la entrada del llavero. No uses
un limpiador de aplicaciones para borrar sus datos. Si no puede acceder a la
clave, conserva el perfil y resuelve el permiso del llavero antes de continuar.
No sustituyas la app por una versión más antigua: las builds nuevas pueden
cambiar el perfil de formas que una anterior no sabe leer. Las builds
posteriores a `0.1.0+11` detectan un perfil de una versión más reciente y se
niegan a abrirlo sin modificarlo; las anteriores no lo comprueban.

El llavero clásico no ofrece la misma vinculación al dispositivo que Data
Protection en iOS. Arveil no lo sincroniza, pero las copias o migraciones
manuales del llavero quedan fuera de su control. No se migran automáticamente
perfiles creados con el anterior backend Data Protection. Consulta las
[garantías y pruebas por plataforma](PLATFORMS.md).

### Android: ARM64, Android 7.0 / API 24 o posterior

El APK solo contiene código ARM64. Android lo rechaza en teléfonos solo de 32
bits y en emuladores x86-64; `clients-v0.1.0-beta.1` se instala igualmente en
ellos y se cierra al abrirse.

1. Descarga el archivo `android-arm64.apk` en el teléfono y ábrelo.
2. Si lo pide, permite **Instalar aplicaciones desconocidas** al navegador o
   gestor de archivos que abre ese APK. Instala Arveil; después puedes retirar
   ese permiso.
3. Abre Arveil, pulsa **Abrir perfil** y después **Unirme con una invitación**, e
   introduce los datos del servidor (relay) y luego la invitación. Si te llegaron
   en un mismo mensaje, pégalo entero en el primer paso. Si el relay es privado,
   el teléfono debe estar conectado a su red.

**Actualizar desde la app:** las builds con un canal configurado ofrecen
**Ajustes → Actualizaciones** y un icono con el perfil cerrado. Pulsa **Buscar
actualizaciones**, descarga el paquete verificado y elige **Instalar
actualización**. Si Android pide permitir a Arveil instalar paquetes, activa
ese permiso y vuelve para pulsar Instalar. Confirma el diálogo de Android.
La comprobación al abrir la app es opcional y está desactivada inicialmente;
no instala por su cuenta. Véase [actualizaciones y privacidad](CLIENT_UPDATES.md).

**Actualización manual:** en builds anteriores o sin canal configurado, abre
el APK nuevo e instálalo sobre la app existente. Debe usar
el mismo certificado y un número de compilación superior. **No desinstales ni
borres el almacenamiento para actualizar:** perderías el perfil y su clave.
Un APK con otra firma, incluida la de depuración, no puede actualizar esta
instalación. Conserva la app actual si Android informa de un conflicto.
`BUILD.json` identifica la versión y el certificado.

### Primer uso y límites

La interfaz sigue el idioma del sistema (inglés si el sistema lo prefiere y
español en los demás casos) salvo que elijas uno en **Ajustes → Apariencia**,
donde también se eligen el tema, el color de acento, el fondo de las
conversaciones y el tamaño del texto. El alta completada abre **Chats**, con
**Contactos** y **Ajustes** en la barra inferior del móvil o en el raíl lateral
de una ventana ancha. Si falla la conexión, cierra/reabre y reintenta con el
**mismo relay y la misma invitación**. Al reabrir un alta completada no
necesitas otra invitación. El código actual también permite emparejamiento, kits
y conversaciones.

Para probar conversaciones con perfiles desechables del mismo relay usando
el código actual o un paquete que lo incluya:

1. En **Contactos**, pulsa **Tu ruta de contacto** para compartir en privado la
   ruta de este dispositivo con tu contacto. Cada persona obtiene aquí su ruta.
2. Entra en **Contactos → Añadir contacto**, pega una ruta, asigna un nombre local
   opcional y pulsa **Preparar contacto**. Comparad el número completo por otro
   canal; ambos podéis previsualizar la ruta de la otra persona.
3. Pulsa **Coinciden** si los números coinciden y después **Guardar contacto**;
   si no, pulsa **No coinciden** y no lo verifiques. También puedes guardarlo sin
   verificar y pulsar **Coinciden** más tarde en sus datos. Un nombre no verifica
   una identidad.
   **Guardar nombre** cambia el alias local; un nombre vacío lo elimina. Importa
   otra ruta desde **Añadir contacto**; dejar el nombre vacío conserva el alias existente.
4. Abre **Nueva conversación → Elegir contactos guardados**, selecciona contactos
   verificados y pulsa **Usar contactos**. Se crea el grupo con sus dispositivos
   guardados que no consten como revocados (máximo 16). Tu contacto pulsa
   **Sincronizar** para recibirlo. Sigue disponible el flujo de pegar y comparar rutas.
5. Abre la conversación y envía texto. Sin conexión queda guardado localmente;
   **Sincronizar** reintenta su publicación. Aceptación del relay no confirma lectura.

La sincronización automática funciona con Arveil en primer plano. El incremento
de código descrito abajo añade segundo plano opcional en Mac; siguen pendientes
push Android y la gestión general de miembros.
Los paquetes experimentales anteriores pueden preceder estos cambios:
comprueba su revisión antes de esperar estas pantallas.

### Adjuntos (disponibles desde `0.1.0+7`)

Dentro de una conversación, pulsa **Adjuntar archivo** (clip), selecciona un
archivo de menos de 25 MiB y confirma. La copia privada pendiente sobrevive al
reinicio. Si no hay red, usa **Enviar / reanudar** al recuperar conexión;
adjuntarlo otra vez crearía otro mensaje. Los recibidos solo se descargan al
pulsar **Descargar**. **Guardar copia…** permite elegir explícitamente un
destino externo. Esa copia queda fuera del perfil cifrado de Arveil y puede
entrar en las copias de seguridad del destino. Cancelar una transferencia
incompleta elimina sus datos locales; no retira un mensaje enviado. Pide otra
copia si el relay indica caducidad.

### Visor y notificaciones (incremento en código, no incluido en build 25)

En un cliente compilado con este incremento, pulsa **Descargar y abrir** para
un adjunto recibido o **Abrir** si ya está disponible. Las imágenes PNG/JPEG/WebP
se ven dentro de Arveil con zoom, también sin red tras reabrir el perfil.
PDF y otros archivos ofrecen **Abrir con…**: confirma que la aplicación elegida
recibirá una copia temporal descifrada. No hace falta buscarla en Downloads.
**Guardar copia…** sigue siendo una exportación independiente. El visor externo
puede conservar copias; Arveil limpia sus temporales caducados durante la
ejecución o al siguiente arranque.

En Mac, **Ajustes → Notificaciones** ofrece avisos genéricos y la opción
independiente **Mantener Arveil en segundo plano**. Activar avisos solicita
permiso al sistema; denegarlo no impide enviar mensajes. El segundo plano
mantiene el perfil desbloqueado, oculta la ventana al cerrarla y ofrece abrir
o salir desde la barra de menús. Salir, cerrar el perfil o suspender el Mac
detiene los avisos locales. Si se deniega el permiso, habilita Arveil en los
ajustes de notificaciones de macOS y vuelve a activar la opción.

Android añade **Ajustes → Notificaciones** experimental. Requiere ntfy de
F-Droid con tu servidor HTTPS propio; introduce la misma dirección base en
Arveil y concede permiso para avisar. Se rechaza ntfy.sh. Los avisos son genéricos
y pueden llegar con el perfil cerrado, sin desbloquearlo. Desactiva la opción
para detenerlos. Mantén Arveil abierto con conexión para completar altas/bajas
pendientes. El cierre forzado y las restricciones de batería pueden impedir o
retrasar la entrega.

Se han ejecutado builds debug, instrumentación del receptor Android y aceptación
de adjuntos Mac con perfiles desechables. También pasan la entrega y retirada del
aviso en el centro de notificaciones Mac debug con el permiso activado. La app
oficial ntfy F-Droid pasa la entrega en emulador con un servidor local desechable.
Quedan el recorrido completo relay-móvil, avisos Mac empaquetados y Android físico antes de publicar; consulta
[alcance y evidencia](CLIENT_FILES_NOTIFICATIONS.md). Estas pruebas no despliegan
un servidor de notificaciones permanente.
Los cambios no requieren migrar ni reinstalar el perfil: conserva el perfil
y su llavero al actualizar mediante el procedimiento habitual.

## Compilar desde el código

El [README de Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md)
y la [matriz de plataformas](PLATFORMS.md) describen la compilación nativa y su
alcance probado. Actualmente requiere Flutter, Rust y los SDK de cada
plataforma; los paquetes descargables deben evitar esa instalación al usuario
final.

- **macOS:** desde `clients/flutter`, ejecuta `flutter pub get` y
  `flutter run -d macos`. Arrancar una compilación local no requiere una cuenta
  Apple de pago para arrancar y abrir un perfil: utiliza el llavero clásico
  explicado arriba. Para compilar, Xcode debe tener su licencia aceptada.
- **Android:** para desarrollo, habilita la depuración USB, conecta y autoriza
  el teléfono; ejecuta `flutter devices` y `flutter run` desde `clients/flutter`.
  Instala antes el SDK/NDK requerido por el proyecto. Elige el dispositivo
  Android si Flutter lo pregunta. La aceptación en emulador pasó; falta el
  teléfono físico. Esta ruta de desarrollo todavía requiere compilar; el
  objetivo de distribución es descargar e instalar un APK.
- **iOS:** disponer del proyecto Flutter no acredita una release para iPhone.
  Tiene un hito separado en el [plan del cliente](PHASE3B.md).

Las invitaciones, endpoints, material de firma y registros de pruebas quedan
fuera de Git y de capturas públicas. El repositorio contiene ejemplos genéricos,
no la configuración de las máquinas del mantenedor.

## La instalación forma parte de la entrega

Cada release dirigida a usuarios debe ofrecer una ruta en español e inglés
desde el README hasta el artefacto y la guía correctos:

1. **Servidor:** una ruta recomendada con Docker/Podman, requisitos explícitos,
   imágenes versionadas x86-64 y ARM64, persistencia, endpoint alcanzable,
   invitación, comprobación de salud, arranque tras reiniciar, copia,
   actualización y recuperación.
2. **macOS:** app empaquetada, por ejemplo ZIP/DMG, sistemas y arquitecturas
   compatibles, primera apertura y estado de firma/notarización documentados,
   reapertura del perfil cifrado y actualización que conserve su acceso. La
   ruta inicial de desarrollo debe funcionar sin comprar Apple Developer.
   No atribuir al llavero clásico las mismas garantías de vinculación al
   dispositivo del llavero Data Protection; registrar lo que se haya verificado.
3. **Android:** APK instalable, versiones y ABI compatibles, permisos de
   instalación explicados, clave privada de firma de release estable y prueba
   de actualización sobre la versión anterior. La firma de depuración queda
   para desarrollo.
4. **Primer uso:** crear/unir un perfil de prueba desde la interfaz usando los
   datos del relay y la invitación, mostrar errores comprensibles y enlazar la
   guía de recuperación.
5. **Verificación:** una persona parte de una máquina/teléfono limpios y sigue
   únicamente la guía publicada; instala, se da de alta, reinicia y actualiza
   correctamente. Se registran release, sistema, arquitectura e impedimentos.
   Instalar la app como usuario no debe exigir Flutter, Rust, Xcode ni Android
   Studio.

Los artefactos deben incluir versión, checksums y notas de release. CI debe
verificar lo que empaqueta. La configuración privada queda fuera del
repositorio. Son criterios de entrega, no una afirmación de que los paquetes
o todas esas pruebas existan ya; véase la [fase 3b](PHASE3B.md).


## Vincular un móvil Android a tu identidad

En el dispositivo administrador, abre **Ajustes → Vincular otro dispositivo →
Mostrar código**. En el móvil, elige **Vincular con mi otro dispositivo → Escanear
el código**, encuadra el QR completo y mantén el móvil quieto. Compara los números
y autoriza desde el administrador. Si pegas o abres el enlace desde otra app,
también debes confirmar el número en el móvil. La vinculación conserva la
identidad; no copia el historial anterior.

Los QR de contacto, los enlaces de contacto compartidos y los datos del servidor
recuperados también usan el endpoint no administrativo preferido de la lista
guardada y verificada por firma. Sincroniza antes de generar una tarjeta si el
operador ha cambiado las direcciones; sin conexión se usa la última lista
verificada. Los enlaces ya compartidos conservan su contenido original: genera
y comparte uno nuevo después del cambio. Los servidores exclusivamente privados
siguen admitidos; el operador debe configurar y dar prioridad a una ruta pública
para que el código funcione fuera de su red privada.

El código usa el endpoint de cliente prioritario de la lista firmada y verificada
del relay. Si el administrador se dio de alta por una red privada, el relay debe
anunciar ahora una ruta accesible desde el móvil. Da la máxima prioridad a la
ruta WSS pública si el móvil se conectará sin esa red privada. Actualiza la app
del administrador para incorporar la selección de ruta corregida; actualizar
solo el móvil no cambia un código que ya se generó.

Un código caducado se sustituye con **Mostrar un código nuevo**. No reutilices
el enlace anterior. El escáner muestra un marco y un indicador de actividad; si
deniegas el permiso o la cámara no está disponible, puedes pegar el enlace.
La aceptación con una cámara física sigue siendo necesaria aunque pasen las
pruebas automatizadas de vinculación y ciclo de vida de la cámara. Actualiza
sobre la instalación existente para conservar el perfil y su clave.

## Gestionar tus dispositivos (disponible desde `0.1.0+8`)

Abre **Gestionar dispositivos** en **Ajustes**. Compara el identificador
completo con el del otro dispositivo antes de revocarlo. Solo el administrador
puede revocar otro dispositivo; el actual no puede revocarse a sí mismo. Un
perfil vinculado puede mostrar un inventario parcial al desconocer otros IDs.

**Sincronizar dispositivos** reanuda revocaciones confirmadas tras un fallo de
red o reinicio. Hasta que el relay acepte el manifiesto, el dispositivo puede
seguir conectándose; las conversaciones también deben retirar su pertenencia
MLS. La pantalla informa de estas etapas por separado. Revocar no borra copias
ni historial ni confirma que otros participantes recibieran el aviso. Consulta
[la implementación y sus límites](CLIENT_FOUNDATION.md#dispositivos-propios-y-revocación-reanudable-tercera-entrega-de-m3b4).

Actualiza el relay desde la misma revisión del código al probar esta función.
Los relays anteriores devuelven 409 al repetir un manifiesto; esta versión
acepta el reintento idéntico y guarda la revocación y el manifiesto juntos.

## Guardar y recuperar el historial (disponible desde `0.1.0+9`)

1. En **Ajustes**, abre **Historial cifrado**, confirma que la copia permite leer
   mensajes antiguos y pulsa **Guardar historial cifrado**. Si el selector nativo
   termina antes de que la app recupere el foco, pulsa **Mostrar clave del archivo
   guardado** al volver (corregido en `0.1.0+10`). Guarda su clave por separado,
   por ejemplo en un gestor de contraseñas. Desaparece al salir o
   cambiar de app; exporta otra copia si la pierdes. Revisa los adjuntos sin
   copia: no se descargan pendientes ni se buscan archivos antiguos de la CLI.
2. Tras perder un dispositivo, recupera primero la misma identidad con su kit
   más reciente y la clave de ese kit. El archivo de historial no recupera la
   identidad.
3. Abre **Historial cifrado**, elige el archivo, introduce su propia clave y pulsa
   **Importar como historial**. Los registros existentes se conservan sin cambios.
   Los adjuntos siguen cifrados en el perfil hasta **Guardar copia del adjunto**;
   el destino elegido puede conservar o respaldar esa copia legible.
4. Consulta los registros en esta pantalla separada. Importar no reenvía mensajes
   ni reincorpora a grupos antiguos. Comparte la ruta del dispositivo recuperado
   con un contacto y cread expresamente una conversación nueva para hablar.

Incluido en los candidatos `0.1.0+10`. Límite de 64 MiB y 10.000 registros por
archivo; consulta
[los límites de implementación](CLIENT_FOUNDATION.md#historial-cifrado-y-recuperación-tras-pérdida-cuarta-entrega-de-m3b4).

Al guardar un kit de identidad, la acción equivalente es **Mostrar clave del kit
guardado**. Si el guardado termina en segundo plano, mostrar la clave requiere
esta acción explícita al volver. Una vez de vuelta, cambiar de app descarta la clave
pendiente; exporta otra copia si hace falta. Arveil no guarda ninguna de ellas.

## Si algo falla (código posterior a `0.1.0+11`)

Abre **Ajustes → Diagnóstico**. Muestra un informe breve (versión, commit,
sistema, idioma, la fase y los recuentos del perfil, y códigos de los últimos
fallos) antes de que salga del dispositivo, y **Guardar informe** lo guarda
como archivo de texto para adjuntarlo a una petición de ayuda. El informe no
contiene claves, identificadores, rutas, direcciones, invitaciones, nombres ni
el contenido de los mensajes; léelo igualmente antes de compartirlo.
