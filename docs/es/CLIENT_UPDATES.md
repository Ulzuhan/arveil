# Actualizaciones Android firmadas

Arveil puede buscar actualizaciones, descargar un APK verificado y pedir a
Android que lo instale encima de la app existente. La identidad y las
conversaciones se quedan en el almacenamiento de la app. **Nunca desinstales ni
borres el almacenamiento para actualizar.** Un cliente anterior sin esta
pantalla necesita una instalación manual por encima de la app existente para
incorporarla.

Las actualizaciones son independientes del realm. Quien distribuye la app elige
al compilarla un manifiesto HTTPS y una clave pública Ed25519. Una compilación
normal desde el código no tiene manifiesto y no contacta con ningún servicio
operado por el proyecto. macOS sigue usando la sustitución manual; este cambio
no implementa Sparkle ni la rotación automática de la clave de actualización.

*English: [Signed Android updates](../CLIENT_UPDATES.md).*

## Experiencia de uso y privacidad

Abre **Ajustes → Actualizaciones**, o el icono de actualización en la pantalla
con el perfil cerrado. La búsqueda es manual por defecto. La comprobación
opcional en primer plano se ejecuta como máximo una vez al día, contando los
intentos fallidos y los reinicios. Muestra un aviso dentro de la app; no hay
servicio push, consultas periódicas en segundo plano ni notificaciones con la
app cerrada. Activar la opción no instala nada.

Una comprobación pide el manifiesto completo sin versión instalada, ID de
perfil, cookie ni un User-Agent identificativo. El alojamiento o la CDN del
manifiesto siguen viendo la IP y la hora. Descargar una actualización contacta
además con el alojamiento del APK. Ambas acciones funcionan sin abrir un perfil
ni conectar con un realm.

La app verifica el anuncio antes de mostrar sus notas de la versión. El tamaño
y el SHA-256 de la descarga deben coincidir. **Instalar actualización** puede
pedir primero el permiso de Android para que esta app instale paquetes; vuelve
a Arveil y pulsa **Instalar actualización** otra vez. Antes de crear una sesión
de `PackageInstaller`, la app comprueba el ID del paquete, que el número de
compilación sea mayor y el certificado de firma actual, y vuelve a calcular el
hash de los bytes mientras los copia a la sesión. En Android 12 o posterior, la
sesión exige explícitamente una acción del usuario. Android hace la verificación final del APK y pide confirmación al
usuario. No se ofrece como alternativa desinstalar, volver a una versión
anterior ni borrar los datos. Un anuncio caducado debe renovarse antes de
instalar.

## Configurar una distribución

Usa el [empaquetado del cliente](CLIENT_RELEASES.md) y conserva la clave de
release de Android existente. Crea una sola vez, con OpenSSL 3, una clave de
actualización **distinta** que se guarde sin conexión:

```sh
python3 scripts/client_updates.py init-key --key .local/update-signing/update.pem
```

Haz una copia cifrada, separada de la clave del APK. Nunca debe estar en la
web, el relay ni la CI. El comando se niega a sobrescribirla, avisando de que
la clave ya existe, y solo imprime la clave pública.

El comando pide dos veces en el terminal una frase de contraseña de al menos
12 caracteres y guarda la clave cifrada con ella (PKCS#8, AES-256 y
PBKDF2-HMAC-SHA256 con 600 000 iteraciones); al firmar vuelve a pedirla. Ni la
frase de contraseña ni la clave pasan por argumentos de la línea de órdenes ni
por variables de entorno. Genera una frase larga y aleatoria y guárdala en un
gestor de contraseñas, nunca junto a la clave. **Perder la frase de contraseña
es perder la clave:** la única salida es rotar la clave de actualización (véase
más abajo), lo que exige una build nueva firmada con la clave de Android. Para
usos automatizados, `--passphrase-fd N` lee la frase de contraseña de la
primera línea del descriptor de archivo heredado N en lugar del terminal; por
ejemplo, a través de una tubería desde la herramienta de línea de órdenes de un
gestor de contraseñas. Sin terminal ni esa opción, la herramienta se detiene en
vez de leer una frase de contraseña que se vería en pantalla.

Una clave creada antes de que existiera este cifrado es un PEM sin cifrar. La
firma todavía la acepta, con un aviso. Cífrala una vez; el comando comprueba
que la clave pública no cambia y la imprime. Después sustituye el archivo y
destruye la clave sin cifrar y todas sus copias sin cifrar:

```sh
python3 scripts/client_updates.py encrypt-key \
  --key .local/update-signing/update.pem \
  --output .local/update-signing/update-encrypted.pem
mv .local/update-signing/update-encrypted.pem .local/update-signing/update.pem
```

Guarda el siguiente archivo en `.local/distribution.json`, con modo 0600:

```json
{
  "ARVEIL_UPDATE_URL": "https://project.example.org/updates/clients-beta.json",
  "ARVEIL_UPDATE_PUBLIC_KEY": "BASE64_32_BYTE_PUBLIC_KEY",
  "ARVEIL_UPDATE_CHANNEL": "beta"
}
```

Sustituye el marcador de la clave pública por el valor impreso. Solo se aceptan
estos tres campos. Usa `stable` o `beta`; cada canal tiene su propio manifiesto
y su propia secuencia. Nunca añadas a este archivo el nombre de host de un
realm, un bootstrap, una invitación, una clave privada ni un token del túnel.
La URL, la clave **pública** y el canal se incrustan en la app y constan en su
`BUILD.json` público; la ruta local de este archivo, no.

```sh
python3 scripts/package_clients.py build android \
  --signing-config .local/signing/android-signing.json \
  --update-config .local/distribution.json --build-number 18
```

El número de compilación es un ejemplo: elige siempre uno mayor que el de todas
las compilaciones ya distribuidas con esa clave de firma de Android. El
asistente de empaquetado comprueba que el `versionCode` del APK coincide con
este número de compilación, que `BUILD.json` registra y el anuncio transmite, y
que el APK pide el permiso de Android para instalar paquetes solo cuando se
compila con `--update-config`. Rechaza `--update-config` para macOS, que
todavía no tiene actualizador firmado. Haz antes commit del código; los
candidatos con cambios sin confirmar pueden probarse en local, pero el comando
de firma no puede anunciarlos. El manifiesto es una opción de distribución, no
una dependencia del autoalojamiento.

## Anunciar una versión

Prepara la release inmutable `clients-v*` de GitHub y verifica sus artefactos
como se describe en la [guía de releases](CLIENT_RELEASES.md). Escribe unas
notas de la versión breves, en texto plano, en un archivo privado. Firma un
anuncio nuevo en local:

```sh
python3 scripts/client_updates.py sign \
  --key .local/update-signing/update.pem \
  --config .local/distribution.json \
  --package dist/clients/0.1.0+18/android \
  --sequence 1 --valid-days 30 \
  --notes .local/release-notes.txt \
  --asset-url https://github.com/example/arveil/releases/download/clients-v0.1.0-beta.1/arveil-0.1.0-18-android-arm64.apk \
  --notes-url https://github.com/example/arveil/releases/tag/clients-v0.1.0-beta.1 \
  --output .local/releases/clients-beta-1.json
```

**Cualquier cambio en la carga útil, incluida una ampliación de la caducidad
para el mismo APK, necesita una secuencia superior.** La herramienta lleva ese
registro por sí misma: `sequences.json`, junto a la clave (aquí en
`.local/update-signing/`, que Git ignora), guarda por canal cada secuencia
firmada con su versión, su compilación, su caducidad y el SHA-256 del archivo
firmado. Pasa `--sequence` solo en el primer anuncio de un canal: 1 si el canal
es nuevo o, si ya se firmaron anuncios antes de que existiera el registro, uno
más que el último publicado. Después, omítelo: la herramienta usa el número
siguiente y lo imprime. Un `--sequence` explícito debe ser mayor que el último
registrado. Si falta el registro, o un canal no tiene entradas, no hay ningún
anuncio anterior. Un registro con formato no válido detiene la firma y nunca se
restablece: recupéralo de una copia de seguridad o corrígelo a mano. La
entrada se escribe de forma atómica, con modo 0600, solo después de verificar
la firma y antes del archivo de salida, así que un fallo al escribir puede
saltarse un número, pero nunca reutilizarlo; los clientes aceptan huecos. Haz
copia de seguridad del registro junto con la clave.

La herramienta comprueba los hashes del paquete, los metadatos de compilación
limpia, que la distribución y la clave concuerden y que la URL del recurso de
GitHub sea inmutable; después verifica su propia firma con OpenSSL. Solo
escribe archivos nuevos, en modo exclusivo; nunca publica ni sobrescribe uno
existente.

Publica primero el APK verificado, adjunta el anuncio firmado con su nombre de
archivo único por secuencia y sirve de forma atómica esos mismos bytes en la
URL fija del manifiesto. No redirijas el manifiesto ni pongas delante un inicio
de sesión o un desafío de navegador. El cliente pide `Accept-Encoding: identity`
y rechaza las respuestas comprimidas, para que sus límites y hashes se apliquen
a los bytes exactos. Usa `Content-Type: application/json`, sin
compresión del contenido, y `Cache-Control: no-cache` o una vida de caché
corta; al publicar, purga el manifiesto antiguo que siga en caché. Las
descargas pueden seguir como máximo cinco redirecciones HTTPS, porque los
recursos de GitHub se sirven desde un host de almacenamiento. Nunca uses
`releases/latest` ni sustituyas un APK ya publicado. Después de publicar,
compara el manifiesto público con los bytes firmados en local. Sirve el
manifiesto por separado de cualquier realm personal.

Si Browser Integrity Check de Cloudflare rechaza el perfil de cabeceras del
actualizador, aplica la
[excepción de ruta exacta y su procedimiento de reactivación](TUNNEL.md#browser-integrity-check-excepcion-y-vuelta-atras).
Guarda el ID real de la regla, su alcance, la aprobación y el historial de
reversiones en notas privadas de operación. Volver a activar BIC puede bloquear
de nuevo las comprobaciones de actualizaciones; la app debe seguir rechazando
las firmas no válidas en lugar de saltarse la verificación para recuperar el
acceso.

La caducidad por defecto es de 30 días (máximo 90). Renueva el anuncio con una
secuencia nueva antes de que caduque, aunque no haya un APK nuevo. La caducidad
impide ofrecer actualizaciones a partir de un anuncio obsoleto; no desactiva la
mensajería. Un alojamiento todavía puede ocultar un anuncio más reciente
mientras siga siendo válido uno anterior firmado, y la manipulación del reloj
del dispositivo queda fuera de la protección contra retrocesos.

## Formato de transmisión y estado local

El sobre es un JSON con `schema: 1`, `payload` en base64 y `signature` en
base64. Firma con Ed25519 los bytes UTF-8 `arveil-client-updates-v1\n` seguidos
de los **bytes exactos de la carga útil decodificada**. La verificación no
vuelve a serializar el JSON. La carga útil contiene:

```json
{
  "schema": 1,
  "channel": "beta",
  "sequence": 1,
  "expires": "2030-01-01T00:00:00Z",
  "platforms": {
    "android-arm64": {
      "version": "0.1.0",
      "build": 18,
      "minimum_sdk": 24,
      "application_id": "io.github.ulzuhan.arveil",
      "url": "https://github.com/example/arveil/releases/download/clients-v0.1.0-beta.1/app.apk",
      "size": 123,
      "sha256": "64-lowercase-hex-characters",
      "notes": "Plain-text release notes.",
      "notes_url": "https://example.org/releases/18"
    }
  }
}
```

El manifiesto está limitado a 64 KiB y el APK a 512 MiB. Las notas de la
versión son texto plano de como mucho 8000 code points Unicode; el firmador y
la app las cuentan igual, y
`clients/flutter/test/fixtures/update-manifest-vectors.json` mantiene sus
reglas alineadas. Los tiempos de espera
y las comprobaciones de tamaño durante la transmisión acotan las descargas. Las
descargas no válidas o incompletas se eliminan. Android vuelve a calcular el
hash de los bytes mientras los copia a la sesión de instalación.

`updates.json`, en el directorio de soporte de la aplicación, guarda si
activaste la comprobación, el último intento y, para cada clave de
actualización y canal, la secuencia más alta aceptada junto con el resumen
(digest) de su carga útil. Una build con otra clave u otro canal empieza su
propio historial en cero; los demás conservan su protección. No contiene
información del perfil. La sustitución
atómica de ese archivo debe completarse antes de ofrecer un anuncio. Se permite
repetir exactamente el mismo anuncio; no se permite una secuencia menor ni una
carga útil distinta con la misma secuencia. Si falla la lectura o la escritura,
se bloquea en vez de restablecer esa protección. No borres los datos de la app
para recuperarlo: también borra el perfil cifrado. Borrar el almacenamiento de
la app o un atacante local con privilegios puede restablecer este estado.

Cambiar una instalación de canal no necesita nada más: el canal nuevo conserva
su propio historial. Rotar la clave de actualización exige publicar una build
con la clave pública nueva, que la gente instala a mano una vez, como explica
la [ADR-010](adr/ADR-010-distribution-and-updates.md); nunca restablezcas el
estado de actualización ni pidas a la gente que reinstale desde cero. Perder la
clave de actualización o su frase de contraseña solo deja esta rotación, y esa
build debe firmarse con la clave de Android existente. La comprobación actual del certificado Android exige a
propósito los mismos firmantes actuales y no implementa la migración por
linaje de la clave de firma del APK.

## Verificación

`flutter test test/updates_test.dart test/update_transport_test.dart` cubre las
firmas (incluido un vector OpenSSL independiente), la caducidad, la
reutilización de secuencias y los retrocesos, las comprobaciones desactivadas,
la programación diaria, la manipulación del paquete y las redirecciones.
`python3 -m unittest discover -s scripts -p 'test_client_updates.py'` prueba la
frontera de la firma sin conexión, incluidos el registro de secuencias y las
claves cifradas; `test_package_clients.py` comprueba el `versionCode` del APK y
el permiso del instalador. En Android, `app:testDebugUnitTest`
comprueba los bytes exactos de la sesión, el ID de aplicación, la versión y la
política de certificados.

Para el instalador real del sistema, usa el punto de entrada privado
`integration_test/update_installer_acceptance.dart` en un emulador desechable.
Compila un APK de depuración con `ARVEIL_TEST_UPDATER=before` y después otro con
`ARVEIL_TEST_UPDATER=after` y un número de compilación mayor, ambos firmados con
la misma clave de prueba. El primero crea un perfil nativo cifrado y conserva su
clave en Android Keystore. Pon el segundo APK en `cache/updates/update.apk`,
dentro del almacenamiento privado de la app, y su `build`, `size` y `sha256` en
`cache/updates/acceptance.json`. Concede el permiso de instalación para esta
app, pulsa **Install test update** y verifica la confirmación del sistema.
Después de la instalación, vuelve a abrir la app y exige
`ARVEIL_TEST_UPDATER_OK:profile:after`. Prueba también la denegación, la
cancelación, un certificado erróneo y la manipulación; en todos los casos debe
conservarse la app instalada. No uses `adb install -r` para el segundo APK en
esta prueba: se trata de ejercitar la ruta propia de `PackageInstaller` de la
app. Nunca distribuyas ninguno de los dos APK de aceptación.
