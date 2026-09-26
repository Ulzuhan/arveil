# Crear paquetes experimentales del cliente

Para instalar sin herramientas de desarrollo, consulta [Instalar y probar](INSTALLATION.md).
Esta página es para mantenedores. Empaquetar no publica una release en GitHub.

## Requisitos

Usa el [toolchain Flutter/Rust fijado](PLATFORMS.md), Python 3.10 o posterior y
un checkout limpio y comiteado. macOS requiere un Mac con Apple silicon,
Xcode con su licencia aceptada y CocoaPods. Android requiere Java, SDK/NDK y
las herramientas `apksigner` y `aapt2`. Configura `ANDROID_HOME` y el `PATH`
de Flutter y Java según tu instalación, y `JAVA_HOME` si Flutter no encuentra
ya un JDK (`flutter doctor -v`).

Los primeros paquetes se destinan a macOS Apple silicon y Android ARM64.
`BUILD.json` registra la versión mínima del sistema/SDK. Son experimentales:
la interfaz actual permite alta por invitación, emparejamiento y
exportación/restauración del kit de identidad, reposición de KeyPackages y
conversaciones con texto sin conexión y sincronización, contactos guardados,
adjuntos, revocación de dispositivos y exportación/importación cifrada del historial.
Cada candidato corresponde a su revisión registrada: estos cambios no
actualizan los binarios anteriores.

## Android: crear la clave de firma una sola vez

Desde la raíz del repositorio:

```sh
python3 scripts/package_clients.py init-android-key
```

Se crean `.local/signing/android-release.keystore` y
`.local/signing/android-signing.json`, con permisos privados. Git ignora ese
directorio. Las contraseñas se generan aleatoriamente y no pasan por los
argumentos de los comandos. El certificado solo contiene datos del proyecto.

Antes de publicar, conserva una copia cifrada de **ambos archivos** fuera del
checkout. Reutiliza esa clave en todas las actualizaciones: perderla impide
actualizar los APK instalados. No la regeneres por compilación ni la subas a
Git, releases o registros públicos. El comando no reemplaza un directorio de
firma existente. Referencia: [firma de aplicaciones Android](https://developer.android.com/studio/publish/app-signing).

## Compilar los paquetes

```sh
python3 scripts/package_clients.py build android \
  --signing-config .local/signing/android-signing.json
python3 scripts/package_clients.py build macos
```

La versión y el número de compilación se leen de `clients/flutter/pubspec.yaml`.
Incrementa ese número para actualizar, o usa `--build-number 3`. Los números
de Android deben aumentar. `--flutter` acepta la ruta del ejecutable Flutter.
`--allow-dirty` es solo para candidatos locales sin publicar y queda registrado
en sus metadatos. La versión y el commit también llegan a la app
(`--dart-define`), que los muestra en su informe de diagnóstico; una
compilación local sin el script dice «local build».

`apksigner` necesita un entorno Java. Sin `JAVA_HOME`, el asistente usa el JDK
con el que compila Flutter (`flutter config --jdk-dir` o el JDK incluido en
Android Studio). Si no arranca ningún entorno Java, se detiene antes de compilar
y pide `JAVA_HOME`, por ejemplo el JDK de Android Studio (`/Applications/Android
Studio.app/Contents/jbr/Contents/Home`).

Las compilaciones Android ejecutan Gradle sin daemon y compilan Kotlin dentro
del proceso de Gradle, así que no hace falta limpiar daemons entre dos
empaquetados. Cada compilación accede al SDK de Android mediante un directorio
temporal que se borra al terminar: un daemon que siguiera vivo con él rompía la
compilación siguiente con errores de classpath de Kotlin, y detener en su lugar
daemons compartidos puede interrumpir una compilación en otro checkout.

La compilación Android de producción rechaza la ausencia de firma. CI puede
usar las variables privadas `ARVEIL_ANDROID_KEYSTORE`,
`ARVEIL_ANDROID_STORE_PASSWORD`, `ARVEIL_ANDROID_KEY_ALIAS` y
`ARVEIL_ANDROID_KEY_PASSWORD` en lugar del JSON. Una clave de depuración o una
clave desechable de CI no sirve para publicar APK.

El asistente copia las fuentes visibles para Git a un directorio temporal aislado,
resuelve el lockfile comiteado, compila `lib/main.dart` en modo release,
sustituye rutas de fuentes, elimina símbolos nativos de depuración y
revisa el contenido descomprimido para detectar rutas personales y marcas de
configuración de pruebas. Si falla la compilación o revisión, no entrega un
paquete. Esta comprobación complementa el escaneo del repositorio; no es un
detector exhaustivo de secretos ni de malware.

La salida está en `dist/clients/<versión>+<compilación>/<plataforma>/`:

- `.apk` o `.zip` con `arveil.app`.
- `BUILD.json`: revisión, versión, arquitectura, sistema mínimo y estado de firma.
- `SHA256SUMS.txt`: hashes del paquete y sus metadatos.

Los registros, símbolos y candidatos sin verificar permanecen en `.local/client-builds/`. Solo los tres
archivos de salida deben adjuntarse a una release. Los directorios de salida
no se sobrescriben. macOS tiene firma ad hoc, sin Developer ID ni notarización.
En Android se verifican certificado de release, código nativo solo ARM64
(`arm64-v8a`), permiso de red y que el manifiesto no permita depuración.

CI comprueba ambas rutas de empaquetado. Su clave Android es desechable y su
APK de prueba no se sube como descarga. Los APK públicos siempre deben usar
la clave de firma mantenida.

`clients/flutter/integration_test/profile_upgrade_acceptance.dart` permite
probar en modo release una instalación Android desechable. Compílalo con
`ARVEIL_TEST_UPGRADE=create`, instala y arranca; después compila con
`ARVEIL_TEST_UPGRADE=reopen` y un número superior usando la misma firma.
Instala con `adb install -r` y arranca de nuevo. La señal fija
`ARVEIL_TEST_UPGRADE_OK:<fase>` confirma que SQLCipher abre la misma identidad
con la clave del sistema conservada entre procesos y reemplazos del APK.
No publiques esta compilación: genera después la app normal con el asistente.

## Preparar el borrador en GitHub

Las releases del cliente usan tags **`clients-v<versión>`**, por ejemplo
`clients-v0.1.0-alpha.1`. Los tags `v*` corresponden al workflow de CLI/relay;
los del cliente no activan ese filtro, tampoco en revisiones antiguas.
El [filtro de tags de GitHub](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushbranchestagsbranches-ignoretags-ignore)
y el script de publicación mantienen separadas ambas releases.

1. Verifica el `SHA256SUMS.txt` local de cada plataforma desde su directorio de
   salida con `shasum -a 256 --check SHA256SUMS.txt`. Comprueba que ambos
   `BUILD.json` indican el mismo commit y versión/compilación, con `dirty_source: false`.
2. Copia el ZIP y el APK probados a un directorio de preparación nuevo y vacío.
   Copia sus metadatos como `BUILD-macos.json` y `BUILD-android.json`, conservando
   el contenido. Deja fuera los registros, archivos de firma y símbolos de depuración.
3. Desde ese directorio, genera y verifica el manifiesto conjunto del cliente:

   ```sh
   shasum -a 256 arveil-*-macos-arm64.zip arveil-*-android-arm64.apk \
     BUILD-macos.json BUILD-android.json > SHA256SUMS-clients.txt
   shasum -a 256 --check SHA256SUMS-clients.txt
   ```

4. Crea una **prerelease en borrador** con el tag del cliente. Su destino debe
   ser el commit exacto de ambos metadatos, no una rama que pueda avanzar.
   Adjunta solo los dos paquetes, los dos metadatos y `SHA256SUMS-clients.txt`.
   Registra en las notas el alcance y las pruebas de aceptación descritas debajo.

El workflow de CLI/relay publica `SHA256SUMS-cli-relay.txt` con una lista
explícita de binarios y rechaza sobrescribir archivos de la release. Repetir
una subida con nombres duplicados falla: revisa la release existente antes
de reintentar. No uses `--clobber` para sustituir un paquete distribuido por
una compilación diferente.

Si un borrador aún sin publicar se preparó con `v*`, confirma primero que el
tag no existe, cambia el tag previsto a `clients-v*` y renombra su manifiesto
conjunto a `SHA256SUMS-clients.txt`. Actualiza las notas y verifica los hashes
remotos. Conserva los bytes originales y su revisión de origen. Corregir un
workflow en una rama posterior no modifica el guardado en el commit antiguo
de la release. No muevas un tag publicado para aparentar un origen más reciente.

## Aceptación antes de publicar

Registra commit, checksum, sistema/dispositivo y resultado de cada paso:

1. Sigue [la guía de instalación](INSTALLATION.md) en un entorno de usuario limpio.
2. Abre un perfil, completa el alta en un relay de prueba y cierra perfil y app.
3. Vuelve a abrir y comprueba el mismo alta sin introducir otra invitación.
4. Compila la siguiente versión, actualiza sobre la app existente y abre el perfil.
5. En macOS, registra los avisos de Keychain y si el usuario puede dar permiso.
   No autorices el acceso a todas las aplicaciones para forzar una prueba correcta.
6. En Android, verifica el mismo certificado y un número de compilación mayor.
   No desinstales ni borres datos para superar una prueba de actualización.
7. Revisa metadatos, checksums, contenido, documentación e higiene de Git.
   Publica solo artefactos comiteados y probados, con notas que expliquen su
   alcance experimental y los resultados reales.

El emulador no sustituye la aceptación en teléfono físico. Probar macOS en
local no acredita Gatekeeper en una descarga nueva. Conserva en privado las
invitaciones, endpoints reales, capturas que los muestren y compilaciones de
pruebas. La [matriz de plataformas](PLATFORMS.md) recoge los resultados.
