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
| Llavero clásico de macOS | `profile_key_test.dart` con `ARVEIL_REQUIRE_SECURE_STORAGE=true`, firma ad hoc | verificado en el Mac Apple silicon local: guardar/leer, reabrir el perfil cifrado y rechazar claves ausentes/incorrectas; actualización de paquetes verificada más abajo, descarga nueva pendiente |

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

## Aceptación GUI de KeyPackages (23 de septiembre de 2026)

El código `0.1.0+4` que acompaña este registro pasó
`integration_test/key_packages_test.dart` en macOS Apple silicon con Xcode 27
y el llavero clásico, y en un emulador desechable Android 15/API 35 ARM64 con
Keystore, contra un relay local desechable. La GUI real comprueba
agotamiento, repone y reabre el recuento persistido con su fecha. El entorno
de prueba marca como consumidos los cinco paquetes iniciales en su propia base;
el inventario final tiene 15 paquetes, cinco consumidos y diez disponibles.
La fase 4 comprueba por separado el consumo real por grupos MLS y la reposición
CLI. El [README de Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md)
aporta un script que prepara todo el entorno. Esta ejecución y las pruebas de
widgets no cubren teléfono físico, emparejamiento entre plataformas ni
interacción con los diálogos nativos de archivos.

## Aceptación de conversaciones GUI (23 de septiembre de 2026)

El código `0.1.0+5` que acompaña este registro pasó
`integration_test/conversations_test.dart` de forma nativa en macOS Apple
silicon con Xcode 27 y llavero de inicio de sesión, y en un emulador desechable
Android 15/API 35 ARM64 con Keystore. El asistente aislado crea
dos perfiles cifrados y comprueba creación verificada de grupo, texto en ambos
sentidos, parada del relay, aceptación sin conexión, reapertura del perfil,
paginación y reconexión con 55 eventos sin duplicados. También verifica la
cancelación antes de arrancar el observador.

El interlocutor utiliza el bridge nativo dentro de la app de prueba. Flutter
inyecta el texto mediante su canal de pruebas. No es aceptación cruzada
Mac–Android, teléfono físico, teclado/IME nativo ni instalación recién descargada.
Los paquetes experimentales anteriores `0.1.0+2` siguen iguales. Reproducción en
el [README Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md).

## Aceptación cruzada de paquetes (24 de septiembre de 2026)

Los paquetes normales de release `0.1.0+5`, compilados desde el commit limpio
`4d4362b5f27d3782d992254fc494cd9967f37417`, pasaron una prueba de conversación
entre dos apps independientes: macOS 26.6.2 en Apple silicon (Xcode 27.0,
build 27A266a) y un emulador Android 15/API 35 ARM64 (definición Pixel 7).
Ambas utilizaron un relay de staging ARM64 con Podman a través de una red
privada. Se ejecutaron las apps empaquetadas con `lib/main.dart`, sin puntos
de entrada de pruebas de integración.

| Paquete | SHA-256 |
|---|---|
| `arveil-0.1.0-5-macos-arm64.zip` | `5ac26a37b64c82c7d2a58427739de4e4a5056bf29b9215babd984a5a36997ae9` |
| `arveil-0.1.0-5-android-arm64.apk` | `c275634f32f91d7fa25c35603ca52493d232149c1de0aaafb43ec2f3f9bc17e3` |

Los paquetes mantienen la firma ad hoc de macOS (sin Developer ID ni
notarización) y el certificado de release persistente de Android usado en
el build 2. Ambos metadatos indican `dirty_source: false`. Pasaron las
comprobaciones de firma, arquitectura, checksums y privacidad del contenido
descomprimido. Son candidatos sin publicación; los paquetes anteriores
`0.1.0+2` siguen iguales.

### Procedimiento y resultados observados

Utilizar identidades de prueba desechables y un relay accesible. Mantener
privados invitaciones, datos de conexión, rutas de contacto y diagnósticos
sin filtrar de la interfaz.

1. Dar de alta una identidad distinta desde el formulario de cada app con
   build 2. Sustituir la app de Mac en la misma ubicación e instalar APK 5
   sobre APK 2, sin desinstalar ni borrar datos. Ambas reabrieron sus perfiles
   inscritos tras actualizar. macOS pidió acceso al llavero de inicio de
   sesión para la app actualizada; el usuario lo autorizó localmente. Un
   reinicio posterior de la app no volvió a pedir autorización.
2. Intercambiar rutas de contacto desde la GUI. Comparar los números de
   seguridad de ambas pantallas antes de confirmar y crear una conversación
   desde el Mac. Los números coincidieron y ambas apps abrieron la misma
   conversación.
3. Enviar un texto desde cada app y comprobar su recepción. Activar modo
   avión y desactivar Wi-Fi/datos móviles solo en el emulador. Enviar otro
   texto desde Android: aparece en el historial local con sincronización
   pendiente. Enviar otro texto desde el Mac mientras Android está sin red.
4. Detener y reabrir el proceso Android todavía sin conexión. Se conservaron
   perfil, historial previo y texto pendiente; el nuevo texto del Mac aún no
   había llegado. Recuperar conexión y sincronizar: ambas apps mostraron
   exactamente cuatro mensajes. Dos sincronizaciones Android adicionales
   completadas no crearon duplicados ni dejaron el aviso de envío pendiente.
5. Salir de la app Mac y abrirla de nuevo. El perfil y los cuatro mensajes
   siguieron accesibles. Funcionaron el teclado nativo y el pegado en Mac.
   Pulsar el teclado en pantalla de Android permitió escribir y borrar un
   borrador sin enviarlo.

Quedan verificadas la conversación entre apps Mac ↔ emulador Android,
conservación del perfil al actualizar, persistencia sin red y entrega al
reconectar. No cubre teléfono físico, pairing entre dispositivos, reinicio
del sistema/Doze, cobertura amplia de teclados/IME, diálogos nativos de
guardar/abrir/cancelar kits ni Gatekeeper en una descarga nueva en otro Mac.
Esas pruebas siguen abiertas; no supone aceptación de beta ni revisión
externa de seguridad.

## Aceptación de contactos guardados (24 de septiembre de 2026)

El cliente `0.1.0+6` pasó la prueba nativa de integración de conversaciones en:

| Plataforma | Commit del código | Ejecutor |
|---|---|---|
| macOS 26.6.2 Apple silicon, Xcode 27.0, llavero de inicio de sesión | `b176ab4f55a90f8e3b6e273081f8244bb945afd6` | `flutter test` |
| Emulador Android 15/API 35 ARM64, Keystore | `77206b85b4c24ff3b6abb7a652d28cba1388c23f` | `flutter drive --no-dds` |

El segundo commit cambia el ejecutor de pruebas del anfitrión y su
documentación; conserva la implementación del cliente y el escenario de
prueba. El asistente aislado crea un relay local desechable y dos perfiles
cifrados. Comprueba guardar un contacto sin
verificar, comparar explícitamente su número de seguridad, reabrir el perfil
cifrado, crear una conversación desde el contacto guardado sin volver a
pegar su ruta y renombrarlo con el nuevo alias visible en la conversación.
También pasaron el texto en ambos sentidos, la persistencia de la cola sin
red, la paginación de 55 eventos y la reconexión sin duplicados en ambas
plataformas.

El interlocutor utiliza el bridge nativo dentro de la misma app de
integración; Flutter inyecta el texto mediante su canal de pruebas. Este
registro cubre aceptación del código, no paquetes de release en apps
separadas, teclado/IME nativo, teléfono físico ni descarga nueva del build 6.
Los candidatos `0.1.0+5` y el borrador de release siguen iguales. La
aceptación de los diálogos nativos de kits sigue abierta. Los comandos de
reproducción y ajustes locales de las herramientas Android están en el
[README Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md).


## Aceptación de adjuntos en la GUI (25 de septiembre de 2026)

El cliente fuente `0.1.0+7` pasó estas comprobaciones nativas:

| Plataforma y escenario | Revisión de la implementación del cliente |
|---|---|
| macOS 26.6.2 Apple silicon, Xcode 27.0, llavero de inicio de sesión: transferencias | `234406740fac64852d7583f77530305638987100` |
| Emulador Android 15/API 35 ARM64, Keystore: transferencias | `b943594b222c09a5c495b5c6c8fac3ab0f5303f7` |
| El mismo emulador Android: diálogos reales de abrir/guardar adjuntos | `6771842c387854f06abbebf5fe443e81c2403911` |

El escenario de transferencias usa dos perfiles cifrados, Rust/SQLCipher nativo
y un relay local aislado. Comprueba confirmación, cola sin red, reapertura cifrada,
reanudación de subida sin otro evento, descarga voluntaria, exportación verificada,
dos archivos con el mismo nombre, cancelación y sincronización repetida sin
duplicados. Sus selectores son sustitutos en memoria; no escribe descargas de
adjuntos en claro. El ejecutor Android espera a la finalización de la transferencia,
sin asumir que una pantalla estabilizada implica haber terminado la E/S nativa.

La prueba interactiva Android separada usa diálogos reales del sistema y un
archivo sintético de 37 bytes, sin perfil, relay ni kit de identidad. Pasaron
selección, cancelar al abrir, cancelar al guardar y guardado explícito. El archivo
exportado coincidió byte a byte con el original y no se creó caché en claro de
`file_picker`. Después se retiraron ambos documentos desechables. Android lee
la URI de origen directamente con un flujo acotado; tres regresiones JVM cubren
entrada vacía/al límite, flujo demasiado grande de longitud desconocida y
cancelación antes de leer.

Pasaron los 43 tests Flutter y 99 tests Rust (uno sigue ignorado), además del
análisis estático y las comprobaciones de privacidad. Los comandos están en el
[README Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md).
Es aceptación del código: siguen sin verificar los diálogos nativos de adjuntos
en macOS, Android físico, descarga nueva y adjuntos entre apps de release
independientes. Los candidatos `0.1.0+5` y el borrador de release siguen iguales.


## Aceptación de gestión de dispositivos (25 de septiembre de 2026)

El cliente fuente `0.1.0+8`, commit de implementación
`a17ba9d392616e74f92f039c96fcda56c1e54ef8`, pasó el escenario nativo `devices` en:

| Plataforma | Almacenamiento y transporte |
|---|---|
| macOS 26.6.2 Apple silicon, Xcode 27.0 | Llavero de inicio de sesión, SQLCipher, relay local desechable |
| Emulador Android 15/API 35 ARM64 | Keystore, SQLCipher, relay local desechable |

Tres perfiles desechables recorren el inventario del administrador y del
dispositivo vinculado, aviso de inventario parcial, emparejamiento, confirmación
y cancelación explícitas, revocación sin red, reapertura cifrada y reanudación
desde la interfaz. Después, el relay rechaza el handshake del dispositivo
revocado; el administrador retira su hoja MLS e intercambia texto con el
participante restante. La sincronización repetida conserva la versión del
manifiesto y no duplica mensajes. No se exporta ningún kit ni archivo de
historial. Al terminar se limpian los perfiles y se cierra el emulador.

Pasaron los 102 tests Rust y 47 tests Flutter (uno de Rust sigue ignorado),
Clippy, análisis Flutter, aceptación de fase 2 de la CLI, documentación estricta
y controles de higiene de publicación. Rust simula además respuestas perdidas
de manifiesto y sobres, transacciones locales fallidas y una vinculación nueva
mientras queda revocación pendiente. Los comandos están en el
[README Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md#device-management-acceptance).

Es aceptación del código con varios perfiles dentro de cada app de pruebas;
no acredita un teléfono físico ni apps de release independientes. Los
candidatos de instalador `0.1.0+5` y el borrador de release siguen iguales.

Después de esa prueba nativa, el rechazo de solicitudes antiguas y la publicación
atómica y repetible del relay se verificaron con 103 tests Rust, la suite Go y
la aceptación de fase 2. El escenario con relay real borra solo el recibo de
publicación del cliente desechable para simular un acuse perdido y comprueba
el reintento sin otro manifiesto. Estas comprobaciones requieren el relay
actualizado; se conserva explícita la revisión nativa anterior.

## Aceptación de historial y recuperación (25 de septiembre de 2026)

El código `0.1.0+9` pasó el escenario nativo `archives` en macOS 26.6.2 Apple
silicon / Xcode 27.0 y el emulador Android 15 / API 35 ARM64. Cada app utilizó
tres perfiles desechables, SQLCipher, su Keychain/Keystore nativo y un relay local.
Se exportaron texto y un adjunto disponible, se borraron el perfil original y su
clave local, se restauró la identidad con su kit de prueba y se importó el
historial desde la interfaz bajo una clave local nueva.

El adjunto importado coincidió con los bytes originales. Importar de nuevo y
reabrir conservó exactamente dos registros. Sincronizar no duplicó mensajes ni
recuperó el grupo MLS antiguo; se creó expresamente una conversación nueva con
la ruta recuperada y se intercambió texto. Kits, archivos y copias de adjuntos
permanecieron en memoria. Los selectores eran sustitutos de prueba: esto no
verifica los diálogos nativos de archivos. No se exportó ningún perfil ni kit real.

Los cambios finales de límites al decodificar, instantánea transaccional y lector
compartido de adjuntos tienen regresiones Rust. La extracción del lector siguió
a las pruebas nativas y comprueba además la configuración CLI sobre un perfil
creado por la GUI. Pasan 108 tests Rust (uno ignorado), 51 Flutter, Clippy,
análisis Flutter, documentación estricta y la aceptación CLI de recuperación de
fase 2. Los comandos están en el [README Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md#encrypted-history-acceptance).

Siguen sin verificar Android físico, diálogos nativos de archivos de historial,
instalación limpia y este flujo entre apps de release independientes. No se han
reemplazado los candidatos `0.1.0+5` ni el borrador de release.
