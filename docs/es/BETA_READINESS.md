# Preparación de la beta

[English](../BETA_READINESS.md).

Estado comprobado el 18 de octubre de 2026. Publicación y aceptación son estados separados. El [plan de fase 3b](PHASE3B.md) conserva los criterios normativos de los hitos.

## Beta 7 publicada

La [beta 7 del cliente, 0.1.0+28](https://github.com/Ulzuhan/arveil/releases/tag/clients-v0.1.0-beta.7) usa código limpio `2c43970f40476803201c831c077f65dffd5da1c8`. Los avisos de actividad llegan ahora del propio relay del usuario ([ADR-014](adr/ADR-014-relay-activity-notices.md)): Android mantiene una conexión de solo vigilancia en un servicio en primer plano y macOS espera el aviso del relay en vez de consultar cada diez segundos. Desaparecen el receptor y los ajustes de ntfy; al actualizar desde la beta 5 o 6 se borra el antiguo aviso en el relay y los avisos siguen activos si lo estaban. Tags y artefactos conservan su contenido inmutable al integrar las PR por squash.

| Canal | Estado verificado |
|---|---|
| GitHub | Prerelease pública: ZIP macOS ARM64 y APK Android ARM64; sumas subidas, metadatos y tamaños y sumas del anuncio firmado comprobados |
| Google Play | Build 28 en pruebas internas, disponible el 18 de octubre; sin revisar, no distribución de producción |
| Homebrew | Cask `0.1.0-beta.7,28` |
| Anuncio firmado | Canal beta, secuencia 9, caduca el 16 de noviembre de 2026; feed público y redirecciones `/download/android` y `/download/macos` comprobados |
| Relay compatible | `d2417aaf5243042f32e14005332cc13f80701ef2` (esquema 7 del relay) desplegado en el entorno de prueba desde el 16-10-2026; prueba Noise pública correcta. La beta 7 necesita el esquema 7; los clientes de la beta 6 también funcionan con él |
| Web complementaria | Guías y descargas firmadas en `fad9770`; Lighthouse correcto en las páginas de Arveil |
| ntfy | El servidor ntfy autoalojado, su proxy, la ruta del túnel y el nombre DNS se retiraron del entorno de prueba el 18 de octubre |

El APK directo conserva su certificado. El AAB usa la clave de subida establecida; Google Play firma la distribución con su propio certificado de app. macOS conserva firma ad hoc, sin notarización de Apple. Actualiza por el mismo canal sin desinstalar ni borrar datos del perfil.

| Artefacto | SHA-256 |
|---|---|
| macOS ZIP | `247be753a545a8818633a1f23630f45afb31227db9149ea0ad93c51264b89c1d` |
| Android APK | `98317760d3d8f67f7c1c88d3107599bc36515e85c361bf00ba7c0f3e757c48c8` |
| Play AAB | `a9b90e2631ea8e63ad5c6be51ec15151f93335a18792c081d91abf33b5047b0e` |

El servicio de avisos de Android pasó la aceptación relay-emulador en Android 15/API 35 arm64 contra un relay desechable (`scripts/test_android_watch.py`): suscripción, notificación persistente, aviso genérico al llegar correo y parada al rechazarse la clave. Los avisos de Android siguen siendo experimentales hasta que un teléfono físico pase Doze, ahorro de batería, cambios de red, reinicio y forzar detención. Los avisos, toques y suspensión del Mac empaquetado aún no están verificados.

La beta 6 (0.1.0+27, código `e4011f3`, secuencia 8) sigue disponible como prerelease inmutable.

## Compatibilidad e integración

Cuando se publicó beta 6, la release pública de relay/CLI era [v0.1.0](https://github.com/Ulzuhan/arveil/releases/tag/v0.1.0). Esos binarios son anteriores a la consulta de credenciales e invitaciones personales; no deben usarse con beta 6. Usa la revisión compatible registrada u otra release posterior probada cuyas notas declaren compatibilidad. [#133](https://github.com/Ulzuhan/arveil/issues/133) registra la distribución pública posterior del relay/CLI y sus pruebas de compatibilidad; actualizar solo el despliegue privado no demuestra esos criterios.

Relay 4→5 y perfil 7→8 requieren copias consistentes y un despliegue compatible. Se ensayó restaurar el relay anterior con su backup compatible y contador de endpoints conservado. No es un downgrade in situ de esquema ni reversión del perfil del cliente. Prefiere una build correctiva superior a reemplazar una release inmutable.

Las PR #139 (QR), #141 (archivos/notificaciones) y #142 (invitaciones) contienen los cambios de la beta. #138 concilia su registro de publicación. Se promovió explícitamente la identidad existente del administrador mediante la CLI del host; no se publican identificadores ni secretos del despliegue. La administración completa desde la app (ADR-013) y los nombres compartidos (ADR-011) siguen siendo propuestas más amplias.

## Aceptación pendiente

| Issue | Evidencia restante para cerrarla |
|---|---|
| [#133](https://github.com/Ulzuhan/arveil/issues/133) | Distribución pública versionada de relay/CLI y matriz completa de compatibilidad y actualización entre paquetes antiguos/nuevos |
| [#134](https://github.com/Ulzuhan/arveil/issues/134) | Android físico y Mac descargado en limpio: instalación/actualización, QR, enlaces, contactos, adjuntos, recuperación y accesibilidad |
| [#135](https://github.com/Ulzuhan/arveil/issues/135) | Tres personas externas completan el recorrido principal, con resultados anónimos A/B/C |
| [#136](https://github.com/Ulzuhan/arveil/issues/136) | Auditoría independiente y corrección verificada de bloqueantes antes de producción |
| [#137](https://github.com/Ulzuhan/arveil/issues/137) | Diseño revisado e implementación de recuperación/reincorporación MLS activa; restaurar identidad/historial no restaura sesiones activas |
| [#140](https://github.com/Ulzuhan/arveil/issues/140) | Avisos/pulsación/suspensión de Mac empaquetado; abrir archivos en Android físico y recorrido relay→móvil, Doze, muerte de proceso, red y batería |

Todos los checks requeridos pasaron en el código publicado ([ejecución](https://github.com/Ulzuhan/arveil/actions/runs/36853095121)). Nueve escenarios Go↔Rust cubren 22 fronteras de fallo de persistencia, backup/restauración compatible y emisor vinculado. Mac nativo y Android emulado cubren creación, consentimiento, cierre/reapertura/reanudación sin red y chat en ambos sentidos. No cierran A01–A18 físicos del [plan de invitaciones](INVITATION_ONBOARDING_PLAN.md).

El tester confirmó vinculación con Android físico tras build 24; siguen sin registrarse hardware/SO exactos y la matriz completa. El antiguo borrador GitHub beta 4 (build 23, secuencia 6) nunca se publicó y está superado por beta 5/6; no debe publicarse después con descargas antiguas. Windows/Linux e iOS siguen en M3b.6/M3b.7.

Las notificaciones son experimentales y sin garantía de entrega; sincronizar en primer plano/al reabrir es la base. Registra cada resultado con suma del paquete, dispositivo/SO y revisión en la [matriz de plataformas](PLATFORMS.md). No ha habido auditoría independiente ni prueba externa completa.
