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
| SDK de Android | 36.1.0 | instalación del SDK de Android |
| Xcode | 26.6 | instalación del anfitrión |
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
teclee ni sale del dispositivo. Eso último es justo lo que permite que la
futura exportación de historial no necesite esta clave: llevará la suya, y
así la recuperación nunca exigió debilitar esta.

Las copias de seguridad se rechazan en lugar de confiar en ellas:

- **Android** — `android:allowBackup="false"`, `fullBackupContent="false"` y
  un fichero `data-extraction-rules` que excluye todos los dominios tanto de
  la copia en nube como de la transferencia entre dispositivos. Una
  transferencia es tan copia como una copia. La clave almacenada tampoco
  viaja en una copia.
- **Apple** — el directorio del perfil se marca `isExcludedFromBackup` en
  cada arranque, porque un atributo puesto una vez no sobrevive a que se
  sustituya el directorio. La clave se guarda ligada al dispositivo y no
  sincronizable, así que nunca llega a iCloud Keychain.

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
| Keychain de macOS | exige `keychain-access-groups`, que exige firma de desarrollo | **no disponible en una compilación sin firmar.** La aplicación lo dice en lugar de guardar la clave en un sitio más débil; la firma es una decisión de empaquetado de M3b.5 |

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
