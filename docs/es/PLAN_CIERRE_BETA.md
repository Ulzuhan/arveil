# Plan de implementación y cierre de la beta de Arveil

**Objetivo inmediato.** Conseguir que una persona instale la beta desde el canal publicado, acepte una invitación y converse entre Android y macOS, incluso después de perder la red y volver a abrir la app. El primer hito es la aceptación de la beta limitada M3b.5. La reincorporación a grupos MLS y la revisión independiente tienen entregables propios. [Criterios de fase 3b](PHASE3B.md)

**Base del 27 de noviembre de 2026.** El cliente publicado es la beta 7, build 28. El relay/CLI público v0.2.0 usa el esquema 5. El relay con esquema 7 probado con los avisos de beta 7 está registrado en `d2417aa`. La revisión de `main` fue `dc1fcc7`, con los 15 trabajos de CI correctos. La última sección recoge los resultados obtenidos y las condiciones que siguen abiertas. [Estado de la beta](BETA_READINESS.md) · [CI de referencia](https://github.com/Ulzuhan/arveil/actions/runs/41691553714)

## Orden de trabajo

| Prioridad | Entrega | Puede empezar cuando… | Responsable propuesto |
|---|---|---|---|
| Inmediata | Canal de actualizaciones verificado | Ahora | Mantenedor de la distribución |
| Alta | Relay de esquema 7 instalable desde una release | Ahora | Mantenedor del relay y de releases |
| Alta | Matriz física de instalación, adjuntos y avisos, #134 y #140 | Hay paquetes identificados, un relay compatible, un Android físico y otro Mac con instalación limpia | Ingeniería de cliente y persona que prueba en dispositivos |
| Alta | Prueba externa con tres personas, #135 | Se puede completar el recorrido básico en dispositivos y funcionan las descargas del canal elegido | Coordinador de la beta y participantes A/B/C |
| En paralelo | Diseño de reincorporación MLS, #137 | Ahora. La implementación depende de la revisión del diseño | Ingeniería de protocolo y cliente |
| Antes de producción | Revisión independiente, #136 | El alcance se puede acordar ya. La evaluación final requiere un candidato identificado | Mantenedor y revisor externo |

El PR de Dependabot se integró en `51f6b2d` con sus comprobaciones en verde. El candidato del relay debe identificarse por su propio SHA. [PR #161](https://github.com/Ulzuhan/arveil/pull/161)

## 1. Restablecer y verificar las actualizaciones de la beta

El manifiesto original de la release y la revisión del repositorio web consultada el 27 de noviembre contienen la secuencia 9, caducada el 16 de noviembre. La caducidad afecta a la oferta de actualización dentro de la app. [Actualizaciones firmadas](CLIENT_UPDATES.md)

1. Consultar la URL configurada en la build 28 con las cabeceras del actualizador. Registrar la respuesta HTTP, la firma, el canal, la secuencia y la caducidad. Si ya sirve un anuncio válido y más reciente para los artefactos esperados, conciliar el registro y pasar directamente a la prueba en cliente. Si devuelve un error, HTML o una redirección, reparar la entrega del JSON.
2. Si procede renovar el anuncio, contrastar el registro local de secuencias con lo publicado y verificar tamaños y SHA-256 del APK y ZIP distribuidos. Usar `scripts/client_updates.py sign` con los paquetes originales y la clave de distribución existente. Dejar que el registro asigne la secuencia siguiente. La renovación de la misma build permite conservar los paquetes ya instalados.
3. GitHub marca la beta 7 como inmutable. Archivar la renovación con un nombre por secuencia en el repositorio web y publicar los mismos bytes en la ruta estable. Comprobar el JSON sin compresión con las cabeceras reales de la app y las redirecciones de Android, macOS y notas. Ante una publicación parcial, reintentar con el anuncio ya firmado. [Herramienta de renovación](CLIENT_RELEASES.md)

**Cierre.** Desde Android y macOS, una consulta manual acepta el anuncio vigente. Una build anterior elegible recibe la oferta correcta y la build 28 reconoce que está al día si sigue siendo la última. Registrar secuencia, fecha de expiración, builds y resultado en la preparación de la beta. Dejar asignada la próxima renovación antes de esa fecha. [Procedimiento de firma y publicación](CLIENT_UPDATES.md)

## 2. Distribuir el relay compatible con beta 7

1. Elegir un SHA con CI en verde que contenga el esquema 7 y ADR-014. Ensayar una instalación nueva y una actualización desde v0.2.0 con datos de prueba, mensajes en cola y cursores de entrega. Comprobar que beta 6 sigue sincronizando y que beta 7 recibe avisos a través de la conexión de vigilancia. [ADR-014](adr/ADR-014-relay-activity-notices.md) · [ADR-015](adr/ADR-015-delivery-metadata-and-anonymous-sender.md)
2. Ensayar la vuelta atrás con el binario anterior y su copia consistente previa a la migración. Tras restaurar, comprobar acceso al realm, mensajes previos y secuencia de endpoints. Registrar qué datos posteriores a la copia quedarían fuera de la restauración. [Operación y copias](OPERATIONS.md)
3. Publicar un nuevo tag `v*` usando los workflows existentes `release.yml` y `relay-image.yml` y la aprobación de release configurada. Instalar desde los binarios publicados y desde la imagen por digest. Verificar versión y SHA, sumas, procedencia e imagen para Linux amd64 y arm64. Actualizar la tabla de compatibilidad y las instrucciones de instalación en inglés y español.

**Cierre.** Un operador puede seguir la guía pública en una instalación limpia, arrancar el relay desde la release y recibir en beta 7 un aviso al llegar un mensaje. Guardar tag, SHA, digest de imagen y resultado del ensayo de migración/restauración. La sesión física puede empezar antes con la revisión compatible documentada, dejando constancia de cuál se utilizó. [Instalación](INSTALLATION.md) · [Registro de compatibilidad](BETA_READINESS.md)

## 3. Cerrar la aceptación física de Android y macOS

Ejecutar ambas issues en una sesión coordinada. Usar un Android ARM64 físico y otro Mac Apple silicon que descargue el ZIP público en limpio. La actualización se prueba desde una build anterior del mismo canal, con un perfil desechable que ya tenga identidad, conversación y adjunto. Para cada caso registrar build, canal, SHA-256, versión del relay, modelo y SO, resultado esperado y observado. [#134](https://github.com/Ulzuhan/arveil/issues/134) · [#140](https://github.com/Ulzuhan/arveil/issues/140)

| Evidencia | Casos que ejecutar | Resultado para cerrar |
|---|---|---|
| Instalación y actualización · #134 | Gatekeeper y Llavero en Mac. Certificado y build creciente en Android. Reabrir y actualizar. Probar reinstalación, pérdida de clave y exclusión de copias en perfiles desechables. | El acceso tras actualizar conserva identidad e historial. La pérdida de clave muestra la recuperación disponible. |
| Invitación y conversación · #134 | Volver al enlace original tras instalar. Probar QR con cámara denegada y concedida, vinculación aceptada y rechazada, emisor sin conexión y enlace duplicado. Enviar en ambos sentidos, cerrar y reconectar. | Consentimiento explícito, una conversación, mensajes pendientes entregados una vez. Cruzar los casos A01–A18 con evidencia y explicar los que queden pendientes. |
| Recuperación y accesibilidad · #134 | Exportar/restaurar kit e importar historial cifrado en un perfil de prueba. Recorrer alta, conversación y recuperación con VoiceOver y TalkBack. | La persona puede completar los recorridos y distinguir identidad restaurada, historial legible y estado del grupo. |
| Adjuntos · #134 y #140 | Interrumpir y reanudar transferencia. En Android físico abrir una imagen y un archivo externo, revisar el acceso al temporal y probar permiso denegado. | El destinatario abre el archivo correcto, puede reintentar y el temporal respeta la política de la app. |
| Avisos del relay · #140 | En Android probar Doze, ahorro de batería, Wi‑Fi/datos, muerte de proceso, reinicio, forzar detención y reapertura. En Mac probar permisos, banner, pulsación, ventana oculta, reposo y salida explícita. | Documentar cuándo llega el aviso, si abre el destino esperado y cuándo vuelve a sincronizar. La recepción al reabrir funciona y la documentación describe el comportamiento observado en segundo plano. |

Usar un solo registro de ejecución en la matriz de plataformas y enlazar las filas aplicables desde cada issue. Corregir los bloqueantes con una regresión automatizada cuando sea reproducible. Si cambia el cliente, distribuir una build superior por el canal afectado y repetir los casos sobre el paquete final. [Matriz de plataformas](PLATFORMS.md) · [Casos A01–A18](INVITATION_ONBOARDING_PLAN.md)

## 4. Completar la prueba con tres personas externas

Preparar las instrucciones públicas y un realm de prueba. Cada participante A/B/C instala sin herramientas de desarrollo, entra mediante invitación o vinculación y exporta y restaura un kit con un perfil desechable antes de conservar una identidad. Después verifica un contacto, conversa, intercambia un adjunto, trabaja sin red, reconecta y comprueba actualización y reapertura. Explicar los límites de entrega en segundo plano y de recuperación MLS vigentes en el paquete probado. [#135](https://github.com/Ulzuhan/arveil/issues/135)

**Cierre de M3b.5.** Registrar por persona y recorrido el paquete, la plataforma, el resultado y la ayuda que necesitó. Si hubo un bloqueo, anotar el cambio que lo resolvió y el resultado de repetir ese paso. Cerrar #135 con tres recorridos completos y contrastar #134, #140 y #135 con los criterios de M3b.5. Publicar únicamente evidencia anonimizada. [Criterios del hito](PHASE3B.md) · [Matriz de plataformas](PLATFORMS.md)

## 5. Implementar la reincorporación a conversaciones MLS

Dividir #137 en tres cambios revisables. El diseño puede avanzar durante las pruebas físicas. La beta limitada se puede evaluar con sus límites de recuperación documentados. [#137](https://github.com/Ulzuhan/arveil/issues/137)

| Cambio | Trabajo de implementación | Prueba de salida |
|---|---|---|
| Diseño del protocolo | Especificar pérdida de dispositivo, identidad restaurada y estado de grupo desactualizado. Para cada caso identificar quién puede autorizar la vuelta, cómo demuestra su autoridad, qué estado se retira y qué ocurre si falta un miembro autorizado. Contrastar el diseño con la política MLS existente. | Diseño revisado contra el modelo de amenazas, escenarios admitidos y denegados acordados, y modelo de estado y pruebas definidos antes de implementar. |
| Núcleo y aplicación Rust | Implementar el flujo aprobado en `arveil-core` y `arveil-app`. Persistir el progreso de forma transaccional y hacer que reintento y reapertura converjan. Mantener el historial importado como archivo de lectura. | Con perfiles desechables, probar pérdida, estado obsoleto, revocación, respuesta perdida, cierre intermedio y duplicados. Solo un dispositivo autorizado logra reincorporarse y enviar/recibir mensajes nuevos. |
| Puente y cliente Flutter | Exponer estados y acciones tipadas por el puente. Mostrar el paso que puede dar la persona, la espera de autorización y el resultado. Regenerar los bindings si cambia la API y actualizar la guía de recuperación EN/ES. | Prueba de extremo a extremo entre dos clientes desde restauración hasta conversación activa, y prueba de denegación. Al importar solo historial, el cliente conserva la lectura y exige autorización para reincorporarse. |

**Cierre.** Enlazar desde #137 la revisión del diseño, el SHA de implementación y los resultados positivos y negativos. Identificar la primera build que incorpora el flujo para poder probarla en dispositivos y delimitar la revisión externa. [Protocolo](PROTOCOL.md) · [Modelo de amenazas](THREAT_MODEL.md)

## 6. Preparar la revisión independiente y la salida a producción

Acordar con el revisor el alcance y las condiciones de entrega. Incluir cliente Flutter, puente, núcleo y aplicación Rust, almacenes de claves, integración de protocolo y actualizaciones firmadas. Si el candidato incluye la reincorporación MLS, incorporar su diseño y pruebas al alcance. Registrar SHA y supuestos revisados y usar el canal privado de seguridad para hallazgos sensibles. [#136](https://github.com/Ulzuhan/arveil/issues/136)

**Cierre de #136.** El revisor entrega el informe y verifica las correcciones bloqueantes. El mantenedor registra los riesgos residuales, las diferencias entre el SHA revisado y el candidato final, y la prueba de instalación y actualización firmada en las plataformas anunciadas. Evaluar la salida de fase contra M3b.8. Windows/Linux e iOS conservan sus propios hitos M3b.6 y M3b.7 y sus criterios de distribución. [Plan de fase 3b](PHASE3B.md)

## Evidencia de la ejecución del 27 de noviembre

| Entrega | Resultado reproducido | Pendiente para el cierre |
|---|---|---|
| Distribución | Se contrastaron tamaño y SHA-256 de ambos paquetes de build 28 con GitHub y los metadatos locales. El APK pasó `apksigner verify`; el ZIP extraído pasó `codesign --verify --deep --strict` y contiene la build 28. | Firma y publicación de la renovación. Pruebas desde ambos clientes. |
| Relay | El ensayo con el binario anterior migró la cola de esquema 5 a 7 y recuperó el backup con esquema 5. El ensayo CI usó el relay y la CLI públicos de v0.2.0, comprobó un mensaje pendiente, su cursor, chat en ambos sentidos y un aviso sobre una suscripción de vigilancia. El relay restaurado conservó las claves y arrancó por encima del contador de endpoints conocido. [Ejecución](https://github.com/Ulzuhan/arveil/actions/runs/46059319520/job/140709446438) | Publicar y verificar los artefactos de la nueva versión y repetir el recorrido con el relay instalado. |
| MLS | Una prueba de núcleo verifica Remove + Add, Welcome para el reemplazo y chat nuevo en ambos sentidos. La prueba de archivo comprueba por separado que importar historial conserva la lectura. [Diseño propuesto](adr/ADR-016-reincorporacion-mls.md) | Revisión de la autorización y la persistencia; implementación en la aplicación, puente y UI. |
| Aceptación física, externa y auditoría | Disponibles la hoja de sesión y el alcance propuesto. [Material de ejecución](ACEPTACION_BETA7.md) | Resultados de teléfonos y Macs, recorridos A/B/C e informe independiente. |
