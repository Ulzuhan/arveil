# ADR-006 — Local-first y recuperación como funciones fundamentales

- **Estado:** propuesto.
- **Fecha:** 2026-09-04.
- **Edición documental:** v0.2; alcance de comprobación en el [índice](../README.md#referencias-y-trazabilidad).

*English version: [../../adr/ADR-006-local-first-recovery-first.md](../../adr/ADR-006-local-first-recovery-first.md)*

## Contexto

Un homelab puede estar apagado y un teléfono puede perderse. E2EE sin historial local, estados honestos y una ruta de recuperación resulta poco útil para familiares. A la vez, restaurar snapshots criptográficos antiguos o entregar todas las claves a cada dispositivo destruye propiedades importantes.

## Decisión

La base cifrada del cliente es la fuente de su historial; la cola local permite redactar y preparar envíos sin red. El relay conserva sobres hasta ACK/TTL y no es el archivo histórico obligatorio.

Separar tres capacidades:

1. **Kit de identidad:** raíz privada cifrada y metadatos de recuperación; permite autorizar dispositivos nuevos. Su secreto de alta entropía se custodia fuera del único endpoint.
2. **Incorporación de dispositivo:** claves y leaf nuevas; autorización de raíz y Add por grupo. No clonar claves privadas de dispositivos ni estados MLS activos.
3. **Archivo/transferencia de historial:** mensajes exportados y adjuntos seleccionados, cifrados y autenticados con claves separadas. No incluye secretos de epochs activos.

El cifrado saliente y la evolución MLS se confirman junto con outbox en una transacción. La recepción y deduplicación se confirman antes de ACK. Restaurar una base anterior no permite reanudar envío desde ese estado: se trata como recuperación y reingreso.

## Matriz de recuperación

| Incidente | Qué permite recuperar | Qué requiere |
|---|---|---|
| Servidor perdido; clientes intactos | Identidad e historial local; servicio desde backup o nuevo realm | Reconfigurar rutas, confiar en nuevo endpoint y reconciliar pendientes |
| Teléfono perdido; otro dispositivo y raíz accesibles | Identidad, nueva incorporación e historial seleccionado | Revocar teléfono, Remove/Commit y transferencia autenticada |
| Todos los dispositivos perdidos; kit y archivo disponibles | Identidad e historial exportado | Claves nuevas, contraste de manifiestos, reingreso y posible grupo nuevo |
| Solo kit de identidad | Autoridad de la identidad | Reingreso; el pasado depende de otros clientes o archivos |
| Solo archivo de historial y su clave | Los registros archivados | Nueva identidad; el archivo no autoriza a firmar como la anterior |
| Sin dispositivos, kit ni archivo | Nada de identidad/historial anteriores | Empezar con identidad nueva y reverificar contactos |
| Backup del relay sin material personal | Servicio, metadatos y sobres aún útiles para clientes que tengan claves | No recupera por sí solo identidad ni historial descifrable |
| Raíz comprometida | Continuar con identidad nueva | Revocaciones posibles, contacto externo y reverificación; no confiar en continuidad automática |

## Alternativas

- Historial permanente descifrable en servidor: rompe la frontera E2EE.
- Historial remoto cifrado como única copia: mantiene confidencialidad potencial, pero depende de disponibilidad y clave; no satisface local-first.
- Restaurar base completa con estado de envío MLS: puede retroceder generaciones y revocaciones; rechazado como recuperación automática.
- No ofrecer recuperación por preservar FS: evita copias, pero no satisface el producto. Se ofrece archivo explícito con límites claros.

## Consecuencias

Copiar historia aumenta los lugares donde el pasado puede quedar expuesto. La forward secrecy del transporte no cifra retroactivamente los mensajes locales ni protege un archivo cuando se roba su clave. La UI permite elegir periodo y adjuntos y explica esta consecuencia antes de transferir.

La aplicación distingue pendientes locales, aceptación del relay, recepción por dispositivo y lectura optativa. Un grupo puede tener entrega parcial. Expiración o pérdida del servidor deja mensajes inciertos; no se rellenan con estados de éxito inventados.

La recuperación se valida desde la primera versión utilizable: exportar un archivo no basta sin restaurarlo. El usuario puede verificar el kit mediante una prueba controlada que no envía su secreto al servidor. El diseño exacto del archivo y del canal de vinculación sigue pendiente de revisión.

## Criterios de aceptación

Abrir historial y redactar sin red; reiniciar durante envío/recepción sin perder ni duplicar eventos visibles; restaurar un servidor; recuperar con kit antiguo; recuperar solo historial; pérdida total; dispositivo retirado intentando volver; fallo de contraseña/secreto de archivo; adjunto ausente o corrupto.

Reabrir si se añade sincronización cloud permanente, recuperación administrada o delegación social. Ninguna comodidad nueva puede restaurar secretamente un estado MLS antiguo o entregar la raíz al operador.

Referencias: [arquitectura](../ARCHITECTURE.md), [protocolo](../PROTOCOL.md), [amenazas](../THREAT_MODEL.md).
