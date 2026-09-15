# Instalar y probar Arveil

[English](../INSTALLATION.md).

**Disponibilidad actual (15 de septiembre de 2026):** todavía no hay releases
publicadas en GitHub. El flujo de releases prepara binarios del relay y de la
CLI; no empaqueta la app Flutter. La interfaz permite el alta por invitación,
pero faltan emparejamiento, kit de recuperación y mensajería. Estas
instrucciones describen las rutas de desarrollo disponibles.

## Elige por dónde empezar

| Quiero… | Ruta disponible | Qué falta para una versión descargable |
|---|---|---|
| Desplegar un relay | Compilar con Docker Compose o usar el asistente de staging con Podman sin root | Imágenes versionadas para Linux x86-64/ARM64 y guía de instalación/actualización probada |
| Probar la app en macOS | Compilar desde el código; la app arranca, pero abrir el perfil requiere un almacén de claves funcional | App empaquetada, claves verificadas sin cuenta Apple de pago e instrucciones de primera apertura y actualización |
| Probar la app en Android | Compilar y ejecutar en emulador o teléfono conectado | APK descargable con clave de firma de release persistente; aceptación de instalación y actualización en teléfono físico |
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

## Apps: por ahora, compilaciones de desarrollo

El [README de Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md)
y la [matriz de plataformas](PLATFORMS.md) describen la compilación nativa y su
alcance probado. Actualmente requiere Flutter, Rust y los SDK de cada
plataforma; los paquetes descargables deben evitar esa instalación al usuario
final.

- **macOS:** desde `clients/flutter`, ejecuta `flutter pub get` y
  `flutter run -d macos`. Arrancar una compilación local no requiere una cuenta
  Apple de pago. La configuración actual del almacén seguro puede impedir
  abrir el perfil sin la firma correspondiente. Queda pendiente adaptar y
  verificar esa ruta para desarrollo local; que la app arranque no basta como
  aceptación.
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
