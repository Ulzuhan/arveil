# Hoja de aceptación de la beta 7 y encargo de revisión

## Sesión con Android físico y otro Mac

Usar el APK de GitHub o un canal de Play en el que participe la cuenta. Para probar una actualización, instalar la build anterior por el mismo canal, crear una identidad desechable y enviar un mensaje antes de actualizar. En Mac descargar el ZIP desde un navegador en una instalación limpia. Usar un relay con esquema 7 e identificar su revisión. El APK y el ZIP públicos tienen sus hashes en el registro de la beta. [Paquetes y canales](BETA_READINESS.md) · [Instalación](INSTALLATION.md)

Copiar la tabla en la matriz de plataformas al ejecutar. En su cabecera anotar fecha, modelo/SO, canal, build antes y después, SHA-256 del paquete, SHA del relay y persona que observó el resultado bajo un identificador anónimo. En cada fila anotar **pasó**, **falló** o **pendiente**, junto al resultado observado y a la incidencia/reprueba cuando proceda.

| Caso | Acción en los paquetes distribuidos | Observación que registrar |
|---|---|---|
| Instalación y acceso | Abrir ZIP descargado, atravesar el flujo normal de Gatekeeper y Llavero. En Android verificar instalación y certificado del canal. Cerrar y reabrir. | Avisos exactos e identidad accesible tras reabrir. |
| Actualización | Actualizar desde la build anterior del mismo canal. Consultar después el canal de actualizaciones aplicable. | Build/certificado, identidad, historial y oferta observada. En Play la actualización se hace desde Play. |
| Alta | Enviar invitación, instalar, volver al enlace, probar QR y cámara denegada y concedida. Reabrir el mismo enlace. Probar aprobación y rechazo al vincular. | Identidad/conversación creadas una vez y resultado de cada consentimiento. |
| Mensajes y adjuntos | Dejar al emisor sin red, enviar en ambos sentidos y reconectar. Interrumpir una transferencia, reanudar, previsualizar una imagen y abrir un archivo externamente. | Mensajes duplicados o ausentes; archivo abierto, permisos y destino temporal. |
| Android en reposo | Habilitar avisos. Enviar con el teléfono bloqueado, en Doze y con ahorro de batería. Cambiar Wi-Fi/datos, reiniciar y probar forzar detención/reabrir. Repetir con permiso denegado. | Por condición, registrar si se recibe aviso, demora observada, destino al tocar y si aparece el mensaje al reabrir. |
| Mac en reposo | Conceder/denegar permiso, ocultar la ventana, recibir un mensaje, pulsar el banner, suspender/reactivar y salir explícitamente. | Banner, apertura de conversación, contenido visible con perfil bloqueado y sincronización tras reabrir. |
| Recuperación | Con identidades desechables, restaurar kit e importar historial. Ensayar reinstalación, pérdida de clave y exclusión de copia del perfil en Android. | Identidad restaurada, historial legible, límites de sesión MLS y comportamiento ante clave ausente. |
| Accesibilidad | Repetir alta y primer chat con TalkBack y VoiceOver, texto grande y navegación por teclado en Mac. | Acción completada, foco, control sin etiqueta o anuncio necesario. |

Asignar cada resultado a #134 o #140 y a los casos A01–A18 correspondientes. Guardar los fallos de cada plataforma aunque la otra haya pasado. Las pruebas con teléfonos y perfiles desechables conservan fuera de la evidencia pública los enlaces de invitación, los datos de participantes, las claves y las rutas privadas. [Matriz](PLATFORMS.md) · [Casos de invitación](INVITATION_ONBOARDING_PLAN.md)

## Instrucciones para cada participante externo

Desde otro dispositivo, abre la invitación, sigue la guía publicada para instalar Arveil y vuelve al enlace. Si necesitas ayuda, anota el paso y el texto que te confundió. Con un perfil de prueba, exporta el kit y prueba a restaurarlo antes de decidir si conservarás la identidad. Verifica un contacto, intercambia un mensaje y un archivo, envía otro en modo avión y reconecta. Comprueba cómo se actualiza tu canal y vuelve a abrir la app. Anota qué recibiste al reabrir y qué ocurrió mientras estaba cerrada. Un kit conserva la identidad y un archivo conserva historial legible. Si pierdes el estado activo del grupo, puedes iniciar una conversación nueva con tus contactos verificados. La reincorporación al grupo original sigue pendiente. [Guía de instalación](INSTALLATION.md)

| Participante | Canal, plataforma y build | Alta y kit | Verificación y chat | Adjunto y reconexión | Actualización y reapertura | Ayuda, incidencia y reprueba |
|---|---|---|---|---|---|---|
| A | Pendiente | | | | | |
| B | Pendiente | | | | | |
| C | Pendiente | | | | | |

## Alcance preparado para el revisor independiente

**Referencia inicial.** Cliente distribuido en `2c43970`, build 28. Antes de empezar, fijar SHA del candidato completo, versiones de los artefactos y del relay, hashes y diferencias respecto a la beta. Si la entrega incluye reincorporación MLS, incorporar el diseño aprobado, la implementación y sus pruebas al encargo. [#136](https://github.com/Ulzuhan/arveil/issues/136) · [Modelo de amenazas](THREAT_MODEL.md)

| Superficie | Pregunta de revisión | Evidencia que se entrega |
|---|---|---|
| Identidad, MLS y persistencia | ¿Qué autoriza un nuevo dispositivo, una revocación, un commit y un Welcome? ¿Qué estado queda tras una interrupción? | Política de grupo, transacciones Rust, pruebas de sucesión, archivo y reincorporación si corresponde. |
| Flutter, puente y almacenamiento | ¿Cómo se propagan errores y cancelaciones? ¿Quién puede abrir el perfil, sus claves y archivos temporales tras bloquear o cerrar? | Contrato del puente, integración de Llavero/Keystore, resultados de permisos y adjuntos con paquetes reales. |
| Canal del relay y avisos | ¿Qué identidad y capacidades exige cada sesión y qué metadatos aprende el operador? | Protocolo, implementaciones Go/Rust, evidencia de interoperabilidad y límites de la clave de vigilancia. |
| Cadena de distribución | ¿Cómo comprueba cada canal la identidad del publicador, build, firma, caducidad y retroceso? | Artefactos y sumas públicos, procedencia del relay, recibos firmados y configuración pública del actualizador. |

**Entregables del encargo.** Alcance acordado y revisiones inmutables; informe privado con severidad y componente; registro de correcciones vinculado a commits; verificación independiente de bloqueantes; resumen publicable de cobertura y riesgos residuales. La decisión de producción requiere además las pruebas de plataformas y distribución sobre el candidato final. [Criterios de producción](PHASE3B.md)
