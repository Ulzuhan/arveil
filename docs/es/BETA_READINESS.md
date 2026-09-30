# Preparación de la beta

[English](../BETA_READINESS.md).

Estado comprobado el 30 de septiembre de 2026. Este es el registro actual de
publicación y aceptación; el [plan de fase 3b](PHASE3B.md) conserva los criterios
de los hitos. Publicar un paquete experimental no cierra un hito ni acredita
preparación para producción.

## Disponible y preparado

| Entrega | Código | Estado |
|---|---|---|
| [Relay/CLI v0.1.0](https://github.com/Ulzuhan/arveil/releases/tag/v0.1.0) | `dc03eef` | Binarios y sumas públicos |
| [Cliente beta 3, 0.1.0+21](https://github.com/Ulzuhan/arveil/releases/tag/clients-v0.1.0-beta.3) | `9489ce6` | ZIP macOS ARM64, APK Android ARM64 y anuncio de actualización firmado públicos |
| Candidato beta 4, 0.1.0+23 | `cf7073823c4695c6246684061fedf47773107613` | Borrador de GitHub con ZIP, APK y anuncio firmado (secuencia 6); sumas de archivos subidos verificadas; sin publicación pública |
| Google Play beta 4, versionCode 24 | `eae5ff7d655ed6cd2cff94ee58e1f8e6104c02a4` | Sustituye al código 23 en pruebas internas desde el 30 de septiembre; Play Console confirma disponibilidad para testers internos, con estado Sin revisar |
| macOS beta 4 local, 0.1.0+24 | `eae5ff7d655ed6cd2cff94ee58e1f8e6104c02a4` | Instalada sobre la build 23; perfil cifrado conservado y abierto; comprobado que el QR generado usa la ruta pública anunciada actualmente |
| Relay para acompañar la beta | `cf7073823c4695c6246684061fedf47773107613` | Código candidato; faltan compilación/publicación de release y aceptación del despliegue |

El candidato añade QR, enlaces, tarjetas de contacto y solicitudes
([ADR-012](adr/ADR-012-qr-codes-and-links.md)), la pantalla Acerca de y empaquetado
AAB. El AAB es un artefacto separado para la tienda, con certificado de subida
y sin actualizador propio. Compilarlo no acredita aprobación, acceso de testers
ni disponibilidad en Google Play.

## Compatibilidad y orden de despliegue

Beta 3 funciona con relay v0.1.0. El cliente nuevo usa `CredentialGet`, introducido
en `d26b5c5`, para comprobar la ruta de un contacto contra la credencial de
dispositivo firmada por su raíz. Relay v0.1.0 no tiene esa trama. El cliente
rechaza el servidor no compatible en vez de saltarse la verificación. Prueba
la pareja completa de versiones en el commit elegido, no solo el mínimo que
introdujo esa trama.

1. Compilar relay/CLI e imágenes desde el commit elegido y probado; registrar
   versión, commit, sumas y procedencia de compilación.
2. Hacer copia del realm, actualizar su relay y verificar salud, alta, mensajes
   y reconexión con un cliente anterior. Registrar copia y procedimiento de vuelta.
3. Verificar el cliente candidato contra ese relay: alta, vinculación/rechazo,
   solicitudes, mensajes, adjuntos, desconexión/reconexión y conservación del perfil
   al actualizar desde beta 3. Confirmar el rechazo claro del relay antiguo.
4. Revisar el anuncio firmado y las notas; verificar que beta 3 ve la
   actualización. Publicar el relay compatible antes de anunciar el cliente que
   depende de él; después verificar descargas, feed y vías de actualización.
5. Registrar Google Play aparte: canal, versionCode, estado de revisión y acceso
   de testers. No asumir que las builds instaladas por APK y Play se reemplazan
   entre sí: comparar primero sus certificados de firma de la app.

El candidato existente se preparó con el asistente:

```sh
python3 scripts/release_clients.py prepare \
  --tag clients-v0.1.0-beta.4 --build 23 \
  --revision cf7073823c4695c6246684061fedf47773107613
```

`prepare` no publica. El anuncio se firmó y verificó el 30 de septiembre
(secuencia 6). Los seis archivos del borrador coinciden con las sumas SHA-256
locales. Las notas indican la dependencia del relay y la aceptación pendiente. Los workflows
del relay requieren aprobación del entorno `release` del repositorio; un
borrador o paquete local no demuestra que se hayan ejecutado esas compilaciones.

## Trabajo registrado

| Trabajo | Evidencia para cerrarlo |
|---|---|
| [Publicación coordinada beta/relay #133](https://github.com/Ulzuhan/arveil/issues/133) | Pareja compatible, actualización probada, anuncio firmado y distribución verificada |
| [Android físico y macOS limpio #134](https://github.com/Ulzuhan/arveil/issues/134) | Dispositivo/SO y sumas de paquetes; cámara, enlaces, ciclo de vida, claves y accesibilidad |
| [Prueba externa con tres personas #135](https://github.com/Ulzuhan/arveil/issues/135) | Resultados anónimos A/B/C, restauración del kit antes de conservar identidad y bloqueantes corregidos y verificados |
| [Revisión externa de seguridad #136](https://github.com/Ulzuhan/arveil/issues/136) | Alcance y commit inmutable, hallazgos bloqueantes corregidos/verificados y riesgos residuales antes de producción |
| [Recuperación MLS activa #137](https://github.com/Ulzuhan/arveil/issues/137) | Diseño revisado de recuperación/reincorporación y comportamiento verificado sin restaurar estado antiguo de envío |

Los [nombres elegidos compartidos (ADR-011)](adr/ADR-011-shared-display-names.md)
y la [administración desde la app (ADR-013)](adr/ADR-013-realm-administration-from-the-app.md)
siguen como propuestas. Windows/Linux e iOS siguen en M3b.6/M3b.7.

## Evidencia y límites

El 30 de septiembre, el tester confirmó que el escaneo y la vinculación de la
identidad del Mac con un Android físico funcionaron tras actualizar a la build 24.
Es un resultado comunicado por el usuario; faltan el modelo/SO exactos del móvil
y la aceptación completa en hardware. Los 16 trabajos de CI de `eae5ff7` pasaron.

La revisión posterior encontró que los QR/enlaces de contacto y los datos del
servidor al reabrir aún copiaban la dirección original de alta. La corrección y
sus pruebas se siguen en [PR #139](https://github.com/Ulzuhan/arveil/pull/139);
no están en la build 24 instalada/publicada. La siguiente aceptación debe cubrir
contactos, mensajes, adjuntos y uso sin conexión/al reabrir en el móvil físico;
después, restauración del kit en un perfil aislado y prueba con tres personas.

En `cf70738`, [CI](https://github.com/Ulzuhan/arveil/actions/runs/36316913022)
completó sus 15 trabajos, incluidos los puentes nativos y aceptación de fases.
La revisión local del 29 de septiembre pasó las pruebas Go, 169 pruebas Rust
(una utilidad de vectores ignorada), 280 pruebas Flutter y el análisis Flutter.
La comprobación de paquetes del 30 de septiembre revisó los archivos candidatos
sin recompilarlos ni modificarlos.

Esto no acredita la aceptación completa en Android físico, macOS descargado en limpio, VoiceOver,
TalkBack en hardware, Doze ni la prueba externa de tres personas. Registra cada
resultado con suma del paquete, SO/dispositivo y commit en la
[matriz de plataformas](PLATFORMS.md). No publiques endpoints reales,
invitaciones, material de recuperación ni datos de participantes.

La beta garantiza sincronización en primer plano/al reabrir. El kit recupera
identidad; el archivo de historial recupera mensajes de solo lectura. Ninguno
restaura sesiones MLS activas. No ha habido revisión independiente de seguridad.
