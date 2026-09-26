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
| **Exportación de historial** | un archivo cifrado que la persona pide explícitamente | mensajes de solo lectura y adjuntos disponibles de la misma identidad, también tras recuperar la identidad en un perfil **nuevo** con una clave local **nueva**. No recupera sesiones MLS |

La clave del perfil son 32 bytes aleatorios del generador del sistema,
producidos en Rust con la misma llamada que usa el resto del cliente, y
entregados al almacén de la plataforma. Nunca se deriva de nada que se
teclee y Arveil no la sincroniza. La exportación de historial tiene
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


## Aceptación del paquete corregido y sus selectores (25 de septiembre de 2026)

Los paquetes normales de release `0.1.0+10` se compilaron desde el commit limpio
`8b4f5ef06b810ce07adc82e69bd0e6e28d86c5c6`. Ambos pasaron las comprobaciones
de firma, arquitectura, checksums y privacidad del contenido descomprimido.
El ZIP macOS tiene firma ad hoc; el APK conserva el certificado de las versiones
2 y 5. Son candidatos sin publicar para el borrador `clients-v0.1.0-alpha.3`.

| Paquete | SHA-256 |
|---|---|
| `arveil-0.1.0-10-macos-arm64.zip` | `80e8f93f11449c2e160030f850d96914287089cff0a57d32b28f3e2d31fcfc3d` |
| `arveil-0.1.0-10-android-arm64.apk` | `33f0accdc43ebe7c54724f27ee403fc72535ba1bb262999b5ecc7dce8fbcd030` |

Se usó la app normal instalada en el emulador Android 15/API 35 ARM64, con el
teclado y los selectores nativos, sobre su perfil desechable existente. No se
usó una app de integración ni se desinstaló o borró el almacenamiento.

1. La actualización APK 5 → 9 conservó el alta y los cinco mensajes de prueba.
   Un mensaje nuevo elevó la conversación a seis. Después se instaló APK 10
   sobre APK 9 con el mismo certificado, conservando ese perfil.
2. La versión 9 reveló un fallo real: el selector terminaba de guardar antes
   de que Flutter volviera a primer plano y se descartaba la clave. Ese candidato
   no debe distribuirse. La versión 10 mantiene el resultado oculto hasta pedir
   expresamente mostrarlo; volver a perder el foco descarta claves pendientes y
   visibles. El kit comparte la corrección y tiene cobertura de regresión widget.
3. En APK 10, cancelar el guardado no mostró una clave. Guardar otro archivo
   informó de seis registros; **Mostrar clave del archivo guardado** mostró su
   clave. Cambiar de app y volver la borró sin mostrarla de nuevo.
4. Cancelar la apertura no seleccionó un archivo. Elegir el archivo guardado e
   introducir su clave importó seis registros de solo lectura. Repetirlo informó
   de cero registros nuevos y seis existentes. La conversación conservó seis
   mensajes: importar no los reenvió. Los seis textos importados siguieron
   disponibles después de detener y reiniciar el proceso de la app.

Pasan los 55 tests Flutter, análisis, formato y documentación bilingüe estricta.
Los archivos de prueba, claves y capturas de interfaz quedan privados. El ZIP
macOS arrancó en macOS 26.6.2 Apple silicon / Xcode 27.0, pero falta verificar
reapertura del perfil, selectores nativos y conversación Mac–Android con la
versión 10. También siguen pendientes Android físico, instalación descargada
limpia, selectores del kit y recuperación entre apps de release separadas.
Los borradores alpha anteriores no se han modificado.

## Accesibilidad del rediseño (25 de septiembre de 2026)

Automatizado, en `test/accessibility_test.dart`: etiquetas habladas de los
mensajes («Lucía, 18:40: …» y, en lo enviado, su estado), las pantallas
principales de un móvil con objetivos táctiles de al menos 48 dp y etiqueta en
cada elemento pulsable, la reducción de movimiento del sistema y las
pantallas principales con el texto al 200 % sin desbordes.

Pendiente, manual: recorrer los flujos principales con TalkBack en un
Android físico y con VoiceOver en macOS, y anotar aquí el resultado con el
dispositivo, la versión del sistema y el commit.

## Candidatos del rediseño (25 de septiembre de 2026)

`scripts/package_clients.py` construyó y auditó en local, sin publicarlos,
los candidatos `0.1.0+13` para macOS (arm64, firma ad hoc) y Android (arm64,
clave privada de publicación, SDK mínimo 24) desde el commit limpio `4d5d2c6`
de la rama del rediseño (E3). Ambos pasaron las comprobaciones del script:
arquitectura, firma y ausencia de rutas privadas, marcadores de prueba y
claves dentro del paquete. El informe de diagnóstico de la app lleva la
versión `0.1.0+13` y ese commit.

Actualización: el escenario de perfiles con el CLI compilado desde
`8b4f5ef`, la revisión exacta de los paquetes `0.1.0+10`, frente al código
del rediseño conserva identidad, conversaciones, historial y marcas de
lectura, y rechaza sin tocarlo un perfil de un esquema futuro. Sigue
pendiente repetirlo a nivel de paquete (instalar `0.1.0+10`, llenarlo desde
la app e instalar el candidato) en macOS y en el emulador Android, según
[paquetes del cliente](CLIENT_RELEASES.md).

## Actualización de paquete y revisión con TalkBack (26 de septiembre de 2026)

Candidatos `0.1.0+14` para macOS y Android construidos y auditados en local,
sin publicarlos, desde `main` en `0fa6f6f`, con la pila del rediseño ya
fusionada.

**Actualización desde `0.1.0+10` en Android.** Se usó un AVD nuevo (Android 15,
`google_apis` arm64, emulador) y un relay local desechable. La app `0.1.0+10`
se instaló desde su APK, se dio de alta con una invitación, guardó y verificó
un contacto de prueba (un perfil del CLI), creó la conversación e intercambió
dos mensajes. Después, `adb install -r` instaló `0.1.0+14`, firmada con la
misma clave (versionCode 10 → 14). Resultado:

- El perfil se abre con su identidad, el contacto sigue verificado y la
  conversación conserva el historial.
- Lo recibido antes de actualizar queda leído. Un mensaje que llega después
  aparece como no leído, se marca leído al abrirlo y sigue así tras reiniciar.
- Un mensaje enviado tras la actualización llega al contacto por el mismo
  grupo MLS.
- Lo recibido con `0.1.0+10` no tiene autor, porque esa versión no lo
  guardaba. Se muestra sin nombre y se lee como «Un contacto», como pide el
  diseño.
- En un dispositivo en inglés la app arranca en inglés; `0.1.0+10` solo
  estaba en español.

**Actualización desde `0.1.0+10` en macOS** (macOS 26.6, arm64). Con el perfil
real apartado y el mismo relay, la app `0.1.0+10` creó un perfil nuevo, se dio
de alta, guardó y verificó el contacto de prueba, creó la conversación e
intercambió dos mensajes. Después se cerró y se abrió la app `0.1.0+14`. El
llavero pidió permiso para la nueva firma ad hoc, como en cada build sin
notarizar, y se concedió a mano. Resultado:

- El perfil se abre con su identidad, el contacto verificado y el historial
  completo.
- Lo anterior a la actualización queda leído. Un mensaje que llega después
  aparece como no leído y se marca leído al abrir la conversación.
- Un mensaje enviado desde `0.1.0+14` llega al contacto por el mismo grupo.
- La app sigue el idioma y el tema del sistema: inglés y oscuro en este Mac.

Al terminar, el perfil real volvió a su sitio sin cambios.

**TalkBack.** Se usó TalkBack 15.0 en el mismo emulador, no en un Android
físico. Los gestos se enviaron como toques reales por la consola del
emulador y lo hablado se leyó del registro detallado de TalkBack. Se
recorrieron la bienvenida, la apertura del perfil, la lista de chats, una
conversación (lectura, escritura y envío), los contactos, los ajustes y la
apariencia. El orden es lógico y cada elemento se anuncia con su nombre y
su función. Las burbujas se leen como «Bob, 08:28: …», las pestañas como
«Chats, pestaña 1 de 3», y en apariencia se anuncian los encabezados y la
opción elegida. Hallazgos:

1. Un grupo de ajustes con una sola fila pulsable, como «Conexión», se leía
   como un único encabezado pulsable. Corregido en #100.
2. El control del tamaño del texto decía «100 %, 100 %» sin nombrar qué
   ajusta. Corregido en #100.
3. Tras salir con «atrás» desde la primera pantalla y volver a abrir la app
   en el mismo proceso, el perfil decía estar abierto en otra sesión. Ya
   ocurría con `0.1.0+10`. Corregido en #99, comprobado con un candidato
   local `0.1.0+15`: falló 2 de 2 veces con `0.1.0+14` y ninguna de 3 con el
   arreglo.
4. Los campos con `enableSuggestions: false`, incluido el compositor, hacen
   que Flutter pida en Android una contraseña visible. Gboard muestra
   entonces su teclado de contraseñas, TalkBack lo anuncia y el dictado por
   voz puede desaparecer. Que el teclado no aprenda ya lo garantiza
   `enableIMEPersonalizedLearning: false`. Queda por decidir si el
   compositor recupera las sugerencias.
5. Un mensaje que llega con la conversación abierta no se anuncia. El diseño
   no lo pide; queda anotado.
6. Al abrir una conversación, el foco va al primer elemento de la lista
   («Hoy») y no a la cabecera. Es menor.

Candidatos posteriores: `0.1.0+15` (Android, solo con #99) y `0.1.0+16`
(macOS, desde `main` con #100) se construyeron en local para comprobar los
arreglos. La `0.1.0+16` abrió el perfil actualizado con la conversación aún
leída tras reiniciar.

**VoiceOver: compatibilidad sin probar.** El árbol de accesibilidad y las
etiquetas son los mismos que lee TalkBack, pero en esta sesión no se pudo
recorrer la app con VoiceOver en macOS. La herramienta que manejaba el Mac
no podía leer el panel de subtítulos ni poner el foco en la ventana sin
bloquear la app desde la que se dirigía la prueba. Queda pendiente, junto
con TalkBack en un Android físico.

## Aceptación de las correcciones de lectura (26 de septiembre de 2026)

El código `e8a5c01` de `codex/client-read-state-beta` corrige los mensajes que
se marcaban como leídos detrás de otra pantalla y el resumen desactualizado del
kit tras revocar un dispositivo. Verificación local en macOS 26.6.2, Apple
silicon, Xcode 27.0:

- `flutter analyze`: sin incidencias; pasan 172 pruebas Flutter, incluidos los
  goldens de pantallas. Las regresiones nuevas cubren destinos ocultos, búsqueda,
  otra pantalla superpuesta, historial tardío, aplicación inactiva y vuelta a la
  conversación; el kit se actualiza tras revocar con éxito o fallo de red y
  después de salir de la pantalla de dispositivos.
- Pasa el escenario nativo de conversaciones con dos perfiles cifrados
  temporales, claves del almacén de la plataforma y su propio relay local.
  Prueba la aplicación completa actual, contactos guardados/verificados,
  renombrado, reapertura, el contador real de Rust a uno mientras Ajustes oculta
  una respuesta y a cero al mostrar el historial, texto en ambos sentidos,
  cola sin conexión, paginación y reconexión sin duplicados. El escenario
  anterior aún buscaba controles retirados en el rediseño; esta ejecución usa
  la navegación y el botón de verificación actuales.
- Pasan la documentación bilingüe estricta, las ocho pruebas de los scripts
  de empaquetado/publicación y Gitleaks 8.30.1 sobre el historial de la rama.

El ZIP de macOS y el APK de Android locales `0.1.0+17` se construyeron desde
ese commit exacto y limpio; pasan la auditoría de empaquetado y la comprobación
de sus manifiestos SHA-256. Android conserva el certificado de la compilación
14 (se verificaron las firmas de ambos APK). La aplicación macOS de distribución
arranca y muestra la bienvenida con etiquetas accesibles; en esta comprobación
del paquete no se abrió el perfil de usuario existente. No se publicó ningún
paquete.

| Paquete | SHA-256 |
|---|---|
| `arveil-0.1.0-17-macos-arm64.zip` | `e234f8a9215cbe9f8c3f8401d81fa1596dc200444ccd78a5f08866aa4e678f3c` |
| `arveil-0.1.0-17-android-arm64.apk` | `05f4ce541522345a8e61debda2d782f86e539823a0d11429c7921cfae548f0ab` |

Es aceptación local del código y de integración. No cierra la instalación
desde una descarga limpia, la instalación/actualización y Doze/reconexión en
Android físico, VoiceOver, TalkBack en un dispositivo físico ni las
evaluaciones de tres personas externas exigidas por M3b.5. La actualización
del paquete desde `0.1.0+10` consta en la sección anterior.

## Aceptación del actualizador Android firmado (26 de septiembre de 2026) {#aceptacion-del-actualizador-android-firmado-2026-09-26}

Se ejecutó el punto de entrada privado `update_installer_acceptance.dart` en un
emulador Android 15 / API 35 ARM64 nuevo y desechable. Eran APK de prueba de
depuración, compilaciones 901 y 902, no artefactos de distribución. La primera
creó un perfil SQLCipher real con su clave en Android Keystore. La segunda se
instaló mediante la sesión de `PackageInstaller` de la app y la confirmación
visible **Update** de Android, sin `adb install -r`, sin desinstalar y sin
borrar el almacenamiento de la app. Tras volver a abrirla,
`ARVEIL_TEST_UPDATER_OK:profile:after` confirmó la misma identidad guardada y
que se conservaba la clave de la plataforma.

Antes de aceptar la actualización, la misma instalación también superó estas
pruebas:

- Sin permiso de instalación: se rechazó antes de crear una instalación.
- Cancelación en el diálogo de Android: devolvió `cancelled` y conservó la
  compilación 901 y su perfil.
- Un candidato firmado con otro certificado desechable: devolvió `package`,
  eliminó el candidato y conservó la compilación 901.
- Un candidato con el mismo certificado y un SHA-256 esperado erróneo a
  propósito: se rechazó y se eliminó antes de la instalación.

Las pruebas automatizadas cubren manifiestos firmados, un vector de firma
OpenSSL independiente, caducidad, protección persistente de la secuencia,
comprobación opcional y diaria, integridad de la descarga, redirecciones HTTPS
y validación nativa de la identidad y el certificado del paquete. Consulta
[el protocolo de actualización y el procedimiento de publicación](CLIENT_UPDATES.md).
Este resultado en emulador no acredita el comportamiento en un teléfono físico,
con políticas de dispositivo ni con instalación en segundo plano. No hay
instalación silenciosa ni en segundo plano; la integración con macOS y la
rotación automática de la clave de actualización siguen pendientes.

Código fuente: la ejecución anterior usó el actualizador de `283467b`; después,
`049fd0d` cambió el transporte de las actualizaciones, y a continuación llegaron
las correcciones del mismo pull request. La revisión final aún debe aceptarse
en emuladores con API 24, 28, 29 y 35, y todavía no constan los criterios 3 a 5
del [ADR-010](adr/ADR-010-distribution-and-updates.md) (ningún tráfico con las
comprobaciones desactivadas, ningún identificador en una comprobación, el mismo
comportamiento con el realm caído u hostil), así que el ADR-010 sigue en estado
de propuesta.
