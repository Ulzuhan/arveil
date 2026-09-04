# Modelo de amenazas

**Estado:** propuesta v0.4, sin auditoría ni implementación verificada. [Arquitectura](ARCHITECTURE.md) · [Protocolo](PROTOCOL.md).

*English version: [../THREAT_MODEL.md](../THREAT_MODEL.md)*

## 1. Activos y límites de confianza

Activos de máxima sensibilidad: claves raíz personales, claves privadas de dispositivo, secretos MLS activos, claves de la base local, códigos de recuperación, contenido e historial exportado. También son sensibles el grafo social, las identidades públicas correlacionables, las direcciones IP, las capabilities, los tokens push y el estado de revocación.

El perímetro confiable incluye el core y la UI legítimos, el sistema operativo mientras usa plaintext y el dispositivo que autoriza una identidad. Una pantalla desbloqueada o un proceso comprometido pueden exponer conversaciones. El realm, proxy, red, túnel o CDN intermedio, proveedor push, directorio y almacenamiento remoto se tratan como adversariales para confidencialidad del contenido y autenticidad de personas. Un intermediario que termina TLS, como Cloudflare Tunnel, se trata además como adversario de la API: el canal Noise de [ADR-008](adr/ADR-008-carrier-independent-transport.md) le impide ver o usar credenciales e identificadores.

El propietario del homelab puede ser honesto, curioso o malicioso. E2EE debe proteger frente a este último, pero no obliga al servidor a entregar, conservar o eliminar nada. Una identidad inicialmente no verificada puede ser sustituida por el directorio: la raíz autogenerada no resuelve por sí sola el primer contacto.

## 2. Adversarios y escenarios

| Amenaza | Defensa diseñada | Residuo y condición |
|---|---|---|
| Observador de red o MITM | Canal Noise con clave del realm verificada en bootstrap; E2EE | IP, volumen y timing visibles; un QR sustituido en el bootstrap vincula al cliente a un realm impostor |
| CDN, túnel o proxy que termina TLS (Cloudflare Tunnel, VPS, Funnel) | Canal Noise dentro del carrier; sin secretos ni identificadores fuera del canal | Ve IP de cada cliente, tiempos, tamaños y número de conexiones; puede bloquear o retrasar. No ve frames, credenciales ni tipos de operación; no puede actuar contra el relay |
| Endpoint hostil en la lista o DNS envenenado | `RealmEndpointList` firmado y secuenciado; handshake falla ante clave distinta | El cliente puede quedar sin servicio; no revela nada al endpoint impostor |
| Robo de base y blobs del servidor | MLS, envoltorio por dispositivo, adjuntos cifrados | Expone membresías, rutas, tamaños y tiempos; no es una base «sin datos personales» |
| Operador del realm malicioso | Verificación local de raíces, credenciales, políticas y eventos | Puede bloquear, reordenar, bifurcar vistas y correlacionar tráfico |
| Sustitución de claves en directorio | QR/fingerprint, manifiestos firmados y máximos persistentes | TOFU sin verificación externa es vulnerable en primera conexión; el servidor puede ocultar novedades |
| Replay o entrega duplicada | IDs, epochs, validación MLS y deduplicación durable | El transporte puede repetir indefinidamente; se aplican cuotas y límites |
| Mensajes de un dispositivo retirado | Revocación de credencial, Remove y nuevo epoch | No es instantáneo entre participantes aislados; no borra copias previas |
| Compromiso temporal de un miembro | Actualización MLS con entropía honesta tras limpiar/excluir al atacante | PCS depende de que el atacante pierda acceso y de que los clientes procesen la actualización |
| Robo de dispositivo bloqueado | Cifrado local y secretos protegidos por el SO | Depende del bloqueo, hardware y configuración; no protege memoria ya desbloqueada |
| Malware en dispositivo o cliente adulterado | Reducir privilegios, releases firmadas, revisión y actualizaciones | Fuera de la garantía E2EE: el atacante usa claves y plaintext legítimos |
| Robo de backup personal | Archivo autenticado y cifrado con secreto de alta entropía | Backup y clave juntos exponen contenido; una copia con raíz también permite suplantación |
| Proveedor push curioso | Payload genérico, adaptador opcional | Puede ver token, IP, tiempos y aplicación; el SO no garantiza despertar siempre |
| Miembro malicioso del grupo | Firma/identidad de cada leaf y autorización de cambios | Un destinatario legítimo puede copiar, fotografiar o publicar contenido |
| Agotamiento de disco, CPU o ancho de banda | Cuotas, tamaños, límites de parsing y de epoch futuro | No se promete resistencia a DDoS ni disponibilidad frente al operador |
| Análisis global de tráfico | Menos semántica persistida, padding y envoltorio individual | No resuelto; autenticación de entrega y fan-out permiten correlación |
| Rollback del servidor o de un backup | Máximos locales, deduplicación, claves nuevas al restaurar cliente | Un cliente que perdió todo estado necesita contraste externo; no hay reloj global confiable |
| Fallo de biblioteca o supply chain | Versiones fijadas, inventario, pruebas, revisión independiente | MLS estándar no convierte automáticamente la integración en segura |

## 3. Qué sabe realmente el servidor

| Dato | Visibilidad prevista |
|---|---|
| Miembros, raíces públicas y dispositivos registrados | Visible para administración y directorio |
| Mailbox y dispositivo propietario | Visible por control de acceso/cuotas |
| Emisor de una solicitud autenticada y mailbox destino | Visible durante la entrega; correlacionable por un operador |
| IP, hora, tamaño, frecuencia, tokens push | Visible según el componente; minimizar retención |
| Frames de la API, capabilities, IDs de mailbox y entrega | Visibles solo para el realm dentro del canal Noise; opacos para túneles, CDNs y proxies |
| Lista de endpoints y clave Noise del realm | Pública por diseño; su autenticidad depende de la clave de firma del realm, no del carrier |
| ID del grupo MLS, epochs, roster y títulos | Dentro del envoltorio cifrado; no columnas del servidor |
| Texto, archivos originales, nombres y MIME originales | Cifrados en el cliente |
| Claves privadas y secretos de recuperación personales | Nunca necesarios ni enviados en claro al realm |
| Backups de historial alojados voluntariamente | Ciphertext, tamaño y patrón de acceso; no contenido sin clave |

La ausencia de tablas de conversaciones reduce lo almacenado y expuesto por consultas ordinarias. No impide que un servidor modificado reconstruya relaciones a partir de conexiones y entregas. Los identificadores criptográficos estables pueden correlacionar una persona entre realms si reutiliza la raíz: esta arquitectura no afirma carecer de identificadores globalmente correlacionables.

Un intermediario del carrier ve lo mismo que un observador de red: quién se conecta, cuándo y cuánto envía. Con Cloudflare Tunnel ese observador es un tercero permanente en otra jurisdicción; con Funnel o un VPS con passthrough, ve solo bytes TLS. Es una decisión de despliegue del operador, no un cambio de garantías. Padding por buckets reduce precisión de tamaños, no oculta el volumen total. Una clave exterior HPKE comprometida puede revelar cabeceras MLS de sobres grabados; la confidencialidad del contenido sigue dependiendo de MLS. No se atribuye forward secrecy a una clave de recepción HPKE estática.

## 4. Garantías, con condiciones

**Confidencialidad e integridad de contenido:** objetivo frente a servidor/red adversarial cuando los endpoints y las bibliotecas están íntegros, las identidades se han autenticado y las claves permanecen secretas. No se aceptan mensajes en claro como fallback.

**Forward secrecy:** borrar los secretos de mensajes/epochs según el protocolo limita lo recuperable desde secretos actuales. No protege los mensajes ya descifrados y guardados en el historial local, exportaciones, capturas o copias de seguridad. Retener claves de epochs para aceptar mensajes tardíos amplía la ventana de exposición y debe acotarse.

**Post-compromise security:** requiere que cese el control del adversario y entre material nuevo honesto mediante las operaciones apropiadas de MLS. No hay curación automática por transcurrir tiempo, cambiar el hostname o restaurar la base. Un dispositivo aún autorizado y comprometido sigue siendo destinatario legítimo. Mientras el perfil de coordinador único siga vigente, la PCS de un miembro depende además de que el coordinador esté disponible para confirmar su Update; véase la [revisión v0.3](REVIEW-v0.3.md#31-coordinador-único-de-commits).

**Revocación:** una vez aplicado el Remove correcto y evolucionado el epoch, el dispositivo excluido no debe descifrar mensajes de esos epochs posteriores. Participantes desactualizados pueden seguir enviando en epochs antiguos; el cliente que conoce la revocación deja de enviar hasta completar el cambio. Retención de secretos antiguos y mensajes ya enviados limitan la garantía.

**Recuperación:** preservar identidad exige una raíz recuperable; preservar historial exige copias explícitas. Recuperar la raíz no recrea mágicamente secretos de grupos ni mensajes expirados. Comprometer la raíz permite firmar nuevos dispositivos y es un incidente de identidad completo.

**Disponibilidad y consistencia:** no garantizadas frente a un relay malicioso. Ante commits contradictorios o evidencia de fork, se pausa el grupo y se exige reparación explícita. Comparar checkpoints entre participantes puede detectar contradicciones, pero un servidor que los aísla puede retrasar indefinidamente la detección.

## 5. Invariantes verificables y escenarios de aceptación

| ID | Requisito | Evidencia requerida antes de release |
|---|---|---|
| I-01 | El servidor no recibe secretos personales ni plaintext de mensajes | Trazas de cliente, inventario de campos, inspección de DB/blobs/logs y revisión de flujo de claves |
| I-02 | Un root ajeno no sustituye un contacto verificado | Directorio adversarial que cambia raíz, manifiesto o vínculo de dispositivo; rechazo visible |
| I-03 | Solo dispositivos válidos y cambios autorizados entran en un grupo | Credenciales falsas, caducadas, revocadas y commits MLS válidos pero no autorizados; rechazo |
| I-04 | Un envío no reutiliza estado MLS tras crash | Fallos entre cifrado, commit local y publicación; retransmisión del ciphertext persistido |
| I-05 | ACK implica persistencia local suficiente | Fallos antes/después del commit y ACK; sin pérdida ni duplicados visibles |
| I-06 | Un dispositivo retirado pierde acceso a epochs nuevos | Prueba con varios miembros, partición, Remove y posterior Update/commit; límites de epochs antiguos documentados |
| I-07 | El historial importado no revive secretos MLS antiguos | Restauración de backup desactualizado; nuevo dispositivo, reingreso y archivo separado |
| I-08 | El server restore no hace retroceder versiones conocidas | Snapshot anterior a revocación y entregas; detección y reconciliación |
| I-09 | Push, errores y telemetría no filtran contenido/capabilities | Payloads reales, logs de proxy, crash reports y trazas de bindings revisados |
| I-10 | Entradas malformadas no consumen recursos ilimitados | Fuzzing de framing, CBOR/MLS/HPKE y pruebas de cuotas antes de deserializar |
| I-11 | El backup conserva un conjunto consistente | Restauración aislada con DB, blobs, migraciones y secretos operativos coherentes |
| I-12 | Un intermediario que termina TLS no obtiene credenciales, identificadores ni capacidad de actuar | Captura en el lado del origen de un túnel: solo frames opacos; replay del primer mensaje Noise sin efecto; endpoint con clave distinta rechazado |
| I-13 | El cliente conmuta de carrier sin intervención y sin retroceder la lista de endpoints | Caída secuencial de LAN, tailnet y público; lista con secuencia inferior o firma inválida rechazada |

Estas pruebas pueden detectar incumplimientos. Ninguna prueba de «no encontramos plaintext» demuestra por sí sola que un atacante no pueda descifrar; la revisión criptográfica, las suposiciones y la calidad de bibliotecas siguen siendo esenciales.

La revisión online añade tres casos obligatorios al plan de pruebas: selección durable de commit antes de Welcome; pérdida o revocación del coordinador; y corte de alimentación con las condiciones de [ADR-004](adr/ADR-004-sqlite-single-binary.md#requisitos-verificados-de-durabilidad). Las versiones de bibliotecas, providers y features de debug se auditan conforme a [ADR-002](adr/ADR-002-mls.md); esta revisión documental no acredita una auditoría de esas dependencias.

## 6. Riesgos abiertos que bloquean afirmaciones fuertes

- Revisar la extensión/política que limita commits al coordinador y cómo se valida antes de fusionar estado en la biblioteca elegida.
- Especificar vinculación de dispositivos, transcript, caducidad, QR y resistencia a replay; un QR decorativo no autentica el canal.
- Acotar retención de secretos de epochs y comportamiento al exceder las ventanas de mensajes tardíos.
- Validar suite y formato de archivos/archivos de recuperación sin diseñar construcciones criptográficas ad hoc.
- Comprobar acceso al almacén seguro y cifrado de todos los ficheros locales, WAL, temporales, thumbnails y notificaciones.
- Revisar actualizaciones firmadas desde un canal independiente del realm y comportamiento ante pérdida de la raíz.
- Fijar patrón y suite Noise, tratamiento del primer mensaje `IK` y ventana de rotación de la clave Noise del realm; comprobar que ningún frame se procesa antes de completar el handshake.

El Privacy Inspector del producto debe comunicar estos límites en lenguaje simple y distinguir lo observado de lo inferible. No debe mostrar un check de «anonimato» ni «historial protegido ante cualquier compromiso».

Referencias base y alcance de revisión: [README](README.md#referencias-y-trazabilidad).

## 7. Amenazas adicionales si se adopta HA opcional

Esta extensión es futura y no amplía las garantías actuales. El [ADR-007](adr/ADR-007-optional-realm-redundancy.md) exige estudiar:

- Particiones y doble escritor, promoción de réplicas atrasadas y regreso del antiguo principal.
- Reaparición de capabilities revocadas, sobres borrados o invitaciones consumidas por una réplica obsoleta.
- Pérdida de archivos aunque la base esté replicada, y limpieza incompatible entre nodos.
- Fallos compartidos de alimentación, router, proveedor o domicilio; acceso único que impida llegar a réplicas sanas.
- Ingreso de nodos no autorizados y mayor exposición de metadatos, credenciales operativas y copias de seguridad.

Los nodos no reciben claves E2EE. La continuidad del clúster se evaluará frente a fallos y particiones bajo confianza operativa entre nodos; no se supondrá protección frente a nodos maliciosos por usar consenso. Ante pérdida de autoridad de escritura, el cliente conserva su outbox pendiente y no simula aceptación remota.
