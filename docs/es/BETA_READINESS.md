# Preparación de la beta

[English](../BETA_READINESS.md).

Estado comprobado el 1 de octubre de 2026. Publicación y aceptación son estados separados. El [plan de fase 3b](PHASE3B.md) conserva los criterios normativos de los hitos.

## Beta 6 publicada

La [beta 6 del cliente, 0.1.0+27](https://github.com/Ulzuhan/arveil/releases/tag/clients-v0.1.0-beta.6) usa código limpio `e4011f3f2781aa48888d7da35114aa475d6ff71e`. Tags y artefactos conservan su contenido inmutable al integrar las PR por squash.

| Canal | Estado verificado |
|---|---|
| GitHub | Prerelease pública: ZIP macOS ARM64 y APK Android ARM64; sumas subidas y metadatos comprobados |
| Google Play | Build 27 en pruebas internas, disponible el 1 de octubre; Sin revisar, no distribución de producción |
| Homebrew | Cask `0.1.0-beta.6,27`; estilo y descarga/suma reales correctos |
| Anuncio firmado | Canal beta, secuencia 8; firma, feed público y redirecciones de descarga verificados |
| Relay compatible | `e4011f3f2781aa48888d7da35114aa475d6ff71e` desplegado en el entorno de prueba; copia consistente, identidad conservada, servicios activos y prueba Noise pública correctos |
| Web complementaria | PR [#3](https://github.com/Ulzuhan/kaicorplabs-web/pull/3) integrada y desplegada; guías y descargas firmadas en `8cc3d8b`; Lighthouse correcto en ambos idiomas |

El APK directo conserva su certificado. El AAB usa la clave de subida establecida; Google Play firma la distribución con su propio certificado de app. macOS conserva firma ad hoc, sin notarización de Apple. Actualiza por el mismo canal sin desinstalar ni borrar datos del perfil.

| Artefacto | SHA-256 |
|---|---|
| macOS ZIP | `b4eaa65d56e3d149d5a8dcec85ac5695cfa1670e4ceffd3d5966bf2b065b4fe4` |
| Android APK | `effaa5a496fd817b4338a24b627e184f4375b80c75a988c070378332a2e0864f` |
| Play AAB | `d0d90c2d5250e867db41952d385a1f96c529bdf724340d357369b7ff1e6d3ac3` |

El APK se instaló correctamente en el emulador desechable Android 15/API 35 arm64. El paquete Mac extraído abrió y mostró build 27. Estas comprobaciones no sustituyen una instalación limpia en un teléfono físico u otro Mac.

## Compatibilidad e integración

Los binarios públicos de relay/CLI siguen en [v0.1.0](https://github.com/Ulzuhan/arveil/releases/tag/v0.1.0). Son anteriores a la consulta de credenciales de contactos y a las invitaciones personales; no deben usarse con beta 6. Usa la revisión compatible registrada u otra posterior probada. Actualizar el despliegue privado no publica una nueva release del relay/CLI; #133 conserva ese trabajo.

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
