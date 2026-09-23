# Matriz de plataformas

Qué está fijado, qué se ha compilado y qué se ha ejecutado de verdad. [English version](../PLATFORMS.md).

Una plataforma cuenta como **probada** solo donde el flujo de aceptación se ejecutó en ese sistema. Compilar para un target demuestra el toolchain, no el producto; la distribución es una afirmación distinta que aquí todavía no se hace.

## Toolchain fijado

| Componente | Versión | Dónde se fija |
|---|---|---|
| Toolchain de Rust | 1.98.1 | `core/rust-toolchain.toml` |
| SDK de Flutter | 3.44.1 (canal stable) | este documento, hasta que lo fije CI |
| Dart | 3.12.1 | incluido en el SDK de Flutter |
| flutter_rust_bridge | 2.13.0 (runtime y generador) | `core/crates/arveil-flutter/Cargo.toml` (`=2.13.0`) |
| NDK de Android | 28.2.13676358, API mínima 24 | instalación del SDK de Android |
| SDK de Android | compile SDK 37, mínimo API 24 | instalación del SDK de Android |
| Xcode | 27.0 | instalación del anfitrión; mínimo macOS 12.0 |
| `openssl-src` | 300.6.1+3.6.3 | `core/Cargo.lock` |
| `libsqlite3-sys` | 0.38.2 (`bundled-sqlcipher-vendored-openssl`) | `core/Cargo.lock` |

## Matriz

| Plataforma | Target de Rust | Compilado | Probado | Distribuido |
|---|---|---|---|---|
| macOS (Apple silicon) | `aarch64-apple-darwin` | sí | sí — aceptación ejecutada en el anfitrión | no |
| Android | `aarch64-linux-android`, `x86_64-linux-android` | sí — aplicación y puente | solo emulador — Android 15 (API 35), arm64; falta dispositivo físico | no |
| iOS | `aarch64-apple-ios` | solo núcleo y capa de aplicación | no | no |
| Linux | — | no | no | no |
| Windows | — | no | no | no |

SQLCipher y su OpenSSL vendorizado cruzan a Android sin recurrir a la alternativa que ADR-009 dejó en reserva: los objetos resultantes son `elf64-littleaarch64` tanto para `libcrypto` como para `sqlite3`.

## Protección del perfil, y qué recupera cada cosa

Tres cosas deliberadamente separadas, porque confundirlas es como una
promesa se vuelve falsa:

| | Protege | Recupera |
|---|---|---|
| **Clave del perfil** | la base local en reposo | nada. Perderla pierde el historial local, y eso se acepta a propósito |
| **Kit de identidad** | la raíz de la identidad, exportada por la persona | la identidad. Ni conversaciones ni estado de grupo MLS |
| **Exportación de historial** | un archivo cifrado que la persona pide explícitamente | conversaciones, importadas en un perfil **nuevo** con una clave local **nueva**. Es un hito posterior; nada de lo de aquí depende de él |

La clave del perfil son 32 bytes aleatorios del generador del sistema,
producidos en Rust con la misma llamada que usa el resto del cliente, y
entregados al almacén de la plataforma. Nunca se deriva de nada que se
teclee y Arveil no la sincroniza. La futura exportación de historial tendrá
su propia clave. En macOS, las copias o migraciones manuales del llavero clásico
quedan fuera del control de la aplicación; no se promete vinculación al dispositivo.

Las copias de seguridad se rechazan en lugar de confiar en ellas:

- **Android** — `android:allowBackup="false"`, `fullBackupContent="false"` y
  un fichero `data-extraction-rules` que excluye todos los dominios tanto de
  la copia en nube como de la transferencia entre dispositivos. Una
  transferencia es tan copia como una copia. La clave almacenada tampoco
  viaja en una copia.
- **Apple** — el directorio del perfil se marca `isExcludedFromBackup` en
  cada arranque, porque un atributo puesto una vez no sobrevive a que se
  sustituya el directorio. iOS utiliza Data Protection ligado al dispositivo. macOS
  utiliza el llavero clásico de inicio de sesión con control de acceso por app.
  No se solicita sincronización en ninguno. Las copias/migraciones manuales del
  llavero clásico quedan fuera del control de Arveil; ese backend no ofrece
  la misma vinculación al dispositivo. [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
  describe los modelos de protección.

Excluir no es cifrar ni lo sustituye. Mantiene una base ya cifrada fuera de
una cuenta cuya protección este proyecto no controla.

### Estado del almacén de claves

| Situación | Cómo se comprueba | Estado |
|---|---|---|
| Primera instalación: sin clave y sin perfil | `integration_test/profile_key_test.dart` | verificado en el emulador Android |
| Segundo arranque: la clave vuelve | la misma prueba | verificado en el emulador Android |
| Clave ausente con perfil presente | la misma prueba | verificado: se informa, nunca se sustituye en silencio |
| Otra clave sobre un perfil existente | la misma prueba | verificado: se rechaza al abrir |
| Reinstalación | manual: desinstalar, instalar, arrancar | **sin hacer.** Desinstalar no se lleva necesariamente las entradas del almacén seguro, y las dos plataformas difieren; hay que observarlo, no suponerlo |
| Restauración desde copia o transferencia | manual, en hardware | **sin hacer** |
| Llavero clásico de macOS | `profile_key_test.dart` con `ARVEIL_REQUIRE_SECURE_STORAGE=true`, firma ad hoc | verificado en el Mac Apple silicon local: guardar/leer, reabrir el perfil cifrado y rechazar claves ausentes/incorrectas; descarga nueva y actualización son pruebas separadas |

## Cómo reproducirlo

El workspace de Rust, en el anfitrión:

```bash
cargo fmt --all --manifest-path core/Cargo.toml -- --check
cargo clippy --manifest-path core/Cargo.toml --workspace --all-targets --locked -- -D warnings
cargo test --manifest-path core/Cargo.toml --workspace --locked
```

Compilación cruzada de la capa de aplicación para Android, nombrando el toolchain del NDK de forma explícita:

```bash
NDK=$HOME/Library/Android/sdk/ndk/28.2.13676358
BIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
ANDROID_NDK_ROOT=$NDK PATH="$BIN:$PATH" \
  CC_aarch64_linux_android=$BIN/aarch64-linux-android24-clang \
  AR_aarch64_linux_android=$BIN/llvm-ar \
  CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$BIN/aarch64-linux-android24-clang \
  cargo build --manifest-path core/Cargo.toml -p arveil-app --target aarch64-linux-android --locked
```

Regeneración de los bindings, desde `core/crates/arveil-flutter`:

```bash
flutter_rust_bridge_codegen generate
```

El cliente, desde `clients/flutter`:

```bash
flutter analyze
flutter test integration_test/profile_test.dart -d macos
flutter build apk --debug --target-platform android-arm64
```

## Qué cubre la aceptación

`integration_test/profile_test.dart` se ejecuta en el propio sistema: un perfil abre con clave explícita de 64 caracteres hexadecimales, una consulta responde con un fallo tipado `Domain` que nombra `query-conversations` porque un perfil recién creado no tiene dispositivo, una segunda apertura independiente se rechaza con `AlreadyOpen`, una clave mal formada se rechaza con `BadKey` antes de crear nada, y tras `close` el mismo directorio vuelve a abrir mientras una clave incorrecta falla en la apertura con `Unusable`.

Registrar cada ejecución contra un commit, un sistema operativo y un dispositivo. Una ejecución en emulador se anota como emulador: ejercita los mismos binarios, no el mismo hardware, y M3b.5 sigue debiendo un dispositivo físico.

## Aceptación del alta desde la interfaz (15 de septiembre de 2026)

Los cambios del alta por invitación quedan registrados en el commit que
acompaña este documento. `integration_test/onboarding_test.dart` pasó en
un emulador Android 15/API 35 arm64 contra un relay de staging ARM64 con
Podman. Recorre el formulario, el almacén seguro real, Rust/SQLCipher nativo,
un endpoint inaccesible, cierre/reapertura, reintento con la misma identidad
y reapertura del perfil ya inscrito. No cubre teléfono físico, reinicio del
sistema, reinstalación ni restauración desde la nube. Emparejamiento y kit
de recuperación no formaron parte de esa aceptación. Los comandos y el manejo
de datos privados están en el [README de Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md).

## Aceptación de paquetes experimentales (15 de septiembre de 2026)

Los paquetes `0.1.0+2` se compilaron desde el commit limpio
`a1d954c7a13ae9a2f189ba19e49d2f52e8fd5b19`. Incluyen revisión y checksums; pasaron
las comprobaciones de firma, arquitectura y privacidad del contenido ZIP/APK.
El ZIP macOS tiene firma ad hoc, sin Developer ID ni notarización. El APK
Android usa una clave privada de release persistente.

- macOS Apple silicon, Xcode 27: pasó la aceptación nativa del llavero clásico
  exigiendo que estuviera disponible. La app empaquetada abrió el perfil cifrado,
  lo reabrió tras salir y abrió el mismo perfil después de sustituir la
  compilación 1 por la 2 en la misma ubicación. El llavero puede pedir permiso
  para una app recompilada. Falta una descarga nueva en otro Mac.
- Emulador Android 15/API 35 ARM64: el APK de release se instaló y arrancó.
  La prueba nativa de actualización crea una identidad de prueba con clave
  del sistema y comprueba esa identidad tras reemplazar el APK; no lee ni
  sustituye el perfil normal. Ambas señales de crear/reabrir pasaron al cambiar
  de compilación 1 → APK de producción 2 → verificador 2, sin desinstalar ni
  borrar datos. Sigue pendiente el teléfono físico.

Son resultados locales experimentales, no aceptación de beta ni revisión de
seguridad de producción. La [guía de empaquetado](CLIENT_RELEASES.md) explica
cómo reproducirlos y la [guía de instalación](INSTALLATION.md) cubre al usuario final.

## Aceptación de emparejamiento y recuperación (23 de septiembre de 2026)

`integration_test/pairing_recovery_test.dart` pasó de forma nativa en macOS
Apple silicon con Xcode 27 y llavero clásico, y en un emulador temporal
Android 15/API 35 ARM64 con Keystore, contra un relay local desechable.
Tres perfiles cifrados recorren alta, vinculación, comparación incorrecta,
reapertura antes de confirmar, exportación del kit, clave incorrecta,
restauración, repetición, reapertura y ausencia de historial recuperado.
El código actual identifica el cliente como `0.1.0+3`; esta prueba no recompila
ni publica la alfa `0.1.0+2`.

Las 16 pruebas de widgets/unidad cubren la presentación con un sustituto del
diálogo de archivos. La interacción nativa guardar/abrir/cancelar, vinculación
entre Mac y Android, teléfono físico y descarga limpia quedan fuera de esta
prueba.
