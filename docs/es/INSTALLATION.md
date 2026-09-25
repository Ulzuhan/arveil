# Instalar y probar Arveil

[English](../INSTALLATION.md).

**Disponibilidad actual (25 de septiembre de 2026):** todavía no hay releases
publicadas en GitHub. El [comando de empaquetado](CLIENT_RELEASES.md) prepara
candidatos experimentales: ZIP para macOS y APK para Android. El código actual permite
alta por invitación, emparejamiento y exportación/restauración del kit cifrado
de identidad, creación verificada de conversaciones, historial paginado, texto
sin conexión y sincronización, contactos guardados, adjuntos, revocación de
dispositivos y exportación/importación cifrada del historial. Los candidatos
`0.1.0+10` incluyen estas funciones y la corrección de la clave tras el selector
nativo. El emulador Android conservó el perfil al actualizar y pasó guardado,
apertura, importación repetida y reinicio; falta verificar la reapertura del
perfil macOS en esta versión. Consulta el
[registro de aceptación](PLATFORMS.md#aceptación-del-paquete-corregido-y-sus-selectores-25-de-septiembre-de-2026).
Los candidatos anteriores `0.1.0+5` pasaron conversación Mac ↔ emulador Android.
Los paquetes anteriores pueden incluir solo el alta: comprueba la revisión
y sus notas. En esta fase, utiliza perfiles de prueba desechables.

## Elige por dónde empezar

| Quiero… | Ruta disponible | Qué falta para una versión descargable |
|---|---|---|
| Desplegar un relay | Compilar con Docker Compose o usar el asistente de staging con Podman sin root | Imágenes versionadas para Linux x86-64/ARM64 y guía de instalación/actualización probada |
| Probar la app en macOS | ZIP experimental del mantenedor o compilar desde el código | Release pública y aceptación de una instalación nueva descargada |
| Probar la app en Android | APK experimental del mantenedor o compilar desde el código | Release pública y aceptación de instalación/actualización en teléfono físico |
| Usar un iPhone | Hito posterior y separado | Aceptación nativa y una vía compatible de firma/distribución |

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

La línea `bootstrap:` identifica el relay. Comparte esa cadena y la invitación
por un canal privado con el cliente previsto. El formulario de alta pide ambas.

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
Las descargas públicas aparecerán en
[GitHub Releases](https://github.com/Ulzuhan/arveil/releases) cuando se publiquen.
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

1. Descarga el archivo `android-arm64.apk` en el teléfono y ábrelo.
2. Si lo pide, permite **Instalar aplicaciones desconocidas** al navegador o
   gestor de archivos que abre ese APK. Instala Arveil; después puedes retirar
   ese permiso.
3. Abre Arveil, pulsa **Abrir perfil** e introduce datos del relay e invitación.
   Si el relay es privado, el teléfono debe estar conectado a su red.

**Actualizar:** abre el APK nuevo e instálalo sobre la app existente. Debe usar
el mismo certificado y un número de compilación superior. **No desinstales ni
borres el almacenamiento para actualizar:** perderías el perfil y su clave.
Un APK con otra firma, incluida la de depuración, no puede actualizar esta
instalación. Conserva la app actual si Android informa de un conflicto.
`BUILD.json` identifica la versión y el certificado.

### Primer uso y límites

La interfaz sigue el idioma del sistema: inglés si el sistema lo prefiere y
español en los demás casos. El alta completada muestra el resumen del
perfil. Si falla la conexión, cierra/reabre y reintenta con el **mismo relay y
la misma invitación**. Al reabrir un alta completada no necesitas otra
invitación. El código actual también permite emparejamiento, kits y conversaciones.

Para probar conversaciones con perfiles desechables del mismo relay usando
el código actual o un paquete que lo incluya:

1. Pulsa **Abrir conversaciones** y **Mi ruta** para compartir en privado la ruta
   de este dispositivo con tu contacto. Cada persona obtiene aquí su ruta.
2. Entra en **Contactos → Añadir contacto**, pega una ruta, asigna un nombre local
   opcional y pulsa **Preparar contacto**. Comparad el número completo por otro
   canal; ambos podéis previsualizar la ruta de la otra persona.
3. Confirma la comparación y pulsa **Guardar contacto**, o guárdalo sin verificar
   y utiliza **Verificar contacto** después. Un nombre no verifica una identidad.
   **Guardar nombre** cambia el alias local; un nombre vacío lo elimina. Importa
   otra ruta desde **Añadir contacto**; dejar el nombre vacío conserva el alias existente.
4. Abre **Nueva conversación → Elegir contactos guardados**, selecciona contactos
   verificados y pulsa **Usar contactos**. Se crea el grupo con sus dispositivos
   guardados que no consten como revocados (máximo 16). Tu contacto pulsa
   **Sincronizar** para recibirlo. Sigue disponible el flujo de pegar y comparar rutas.
5. Abre la conversación y envía texto. Sin conexión queda guardado localmente;
   **Sincronizar** reintenta su publicación. Aceptación del relay no confirma lectura.

La sincronización automática funciona con la pantalla de conversaciones en primer
plano. Faltan push, recepción en segundo plano y gestión general de miembros.
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


## Gestionar tus dispositivos (disponible desde `0.1.0+8`)

Abre **Gestionar dispositivos** desde el perfil. Compara el identificador
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

1. En el perfil, abre **Historial cifrado**, confirma que la copia permite leer
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
