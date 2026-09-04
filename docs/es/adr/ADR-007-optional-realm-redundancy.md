# ADR-007 — Redundancia opcional del realm después de V1

- **Estado:** propuesto para exploración futura; fuera de V1, sin compromiso de implementación.
- **Fecha:** 2026-09-04.
- **Edición documental:** v0.4.
- **Decisión vigente:** conservar Standalone como perfil predeterminado; estudiar redundancia opcional con **relays independientes** como dirección preferente y clúster con estado compartido como alternativa, sin elegir todavía motor de replicación.

*English version: [../../adr/ADR-007-optional-realm-redundancy.md](../../adr/ADR-007-optional-realm-redundancy.md)*

## Contexto y objetivo

Una familia puede disponer de varias Raspberry Pi o minipcs, en un mismo homelab o en domicilios distintos. Se quiere explorar que otra máquina continúe las entregas cuando falle una máquina, su conexión o una vivienda completa. Esta capacidad encaja con soberanía y continuidad del servicio, siempre que la instalación doméstica de un solo nodo siga siendo completa y sencilla.

Alta disponibilidad y balanceo son objetivos distintos. La prioridad es conservar y entregar mensajes ante fallos; repartir carga se justifica después con mediciones. El clúster replica un mismo realm y no introduce federación entre comunidades.

## Dirección propuesta

| Perfil | Alcance posible | Compromiso |
|---|---|---|
| Standalone | Un proceso servidor, SQLite local y filesystem | Base de V1; sin tolerancia a pérdida del nodo |
| Respaldo | Copia recuperable o réplica con promoción controlada | Menor complejidad; posible pérdida de escrituras aún no replicadas |
| Relays independientes (preferente) | Varios relays autónomos, cada uno con su clave, su SQLite y su lista de endpoints; un `RouteBundle` por relay y entrega a todos los relays del destinatario | Sin líder ni consenso; duplicados resueltos por la deduplicación existente; los adjuntos se suben a cada relay o se referencian con caducidad conocida |
| Clúster con estado compartido (alternativa) | Varios nodos, réplica durable y sustitución automática del principal | Requiere coordinación, operación y pruebas adicionales |

Los relays independientes encajan con el modelo de confianza: la verdad vive en los clientes, las entregas son idempotentes y el canal de [ADR-008](ADR-008-carrier-independent-transport.md) hace que cada relay sea alcanzable por su propia vía. El coste se traslada al cliente, que gestiona varias rutas por contacto y varios cursores, y al fan-out, que se multiplica por el número de relays. La pérdida de un relay no requiere promoción: el otro sigue entregando.

Para el clúster con estado compartido se evaluaría un líder de escritura con réplicas y un mecanismo existente de elección y exclusión del antiguo líder. Varias instancias pueden recibir conexiones y reenviar solicitudes al líder; eso no implica permitir escrituras divergentes. No construir un protocolo de consenso propio ni compartir el archivo SQLite mediante un filesystem de red.

El perfil Standalone conserva el objetivo de un binario. El perfil HA podría necesitar procesos auxiliares; su empaquetado depende de la solución seleccionada. Añadir una configuración opcional no debe convertir sus dependencias en requisitos de V1.

## Qué debe sobrevivir al fallo

La réplica debe cubrir colas, deduplicación, ACK y borrados, consumo de invitaciones y KeyPackages, manifiestos, revocaciones, capabilities, cuotas y referencias a blobs. Los adjuntos cifrados precisan su propia política de réplica; copiar solo la base no conserva los archivos.

El modo HA debe fijar antes de implementarse:

- **RPO:** qué datos confirmados puede perder bajo cada fallo contemplado.
- **RTO:** cuánto tarda en recuperar la entrega, incluyendo reconexión del cliente.
- **Aceptación:** en qué momento un sobre o blob se considera suficientemente replicado.

La aspiración de HA síncrona es no perder envíos confirmados ante un fallo individual cubierto por el diseño; no es una garantía actual. Si se elige réplica asíncrona, se declara la ventana de pérdida. Una cola local o un recibo E2EE no se confunden con confirmación de réplica.

Una transferencia de archivo no puede anunciarse como durable si su descriptor está replicado pero sus bytes solo existen en la máquina que acaba de fallar. La limpieza de blobs y los tombstones de borrado deben coordinarse para no resucitar datos ni borrar archivos aún necesarios. La replicación no sustituye backups históricos independientes.

## Ubicaciones, mayoría y particiones

En un esquema por mayoría, tres nodos con voto permiten continuar con dos disponibles. Distribuir dos en una casa y uno en otra no permite perder indistintamente cualquiera de las casas: perder la primera elimina la mayoría. Para tolerar la pérdida de cualquier vivienda con esa topología se estudiarían tres ubicaciones independientes, una por voto y con datos suficientes para recuperar. El quórum y el conjunto de réplicas que contienen cada blob deben considerarse por separado.

Tres máquinas con el mismo router, alimentación y acceso a Internet protegen frente a algunos fallos de máquina, pero comparten otros fallos. Un testigo de elección tampoco sustituye una copia de datos. Con dos nodos, una promoción manual o un mecanismo de exclusión adicional puede ser viable, pero no se promete sustitución automática segura sin resolver las particiones.

El lado que pierde autoridad de escritura deja pendientes las operaciones; el cliente mantiene su historial y outbox local. No se permite que dos casas aisladas confirmen cambios incompatibles y se fusionen después por fecha. Tras reconectar, el antiguo principal debe reconocer su pérdida de autoridad antes de volver a servir escrituras.

## Acceso de clientes y seguridad

La disponibilidad exige múltiples endpoints autenticados del mismo realm o una entrada de red también redundante. Un único balanceador, túnel o router en la vivienda caída anularía la redundancia de datos. El cliente debe reconectar, reanudar fetch y repetir entregas idempotentes; no se migran conexiones WebSocket vivas entre máquinas.

La asociación entre endpoints y realm la resuelve el `RealmEndpointList` firmado de [ADR-008](ADR-008-carrier-independent-transport.md), ya en V1; con relays independientes cada relay publica la suya. Varias réplicas de un túnel sobre el mismo dominio dan failover de ingreso al clúster con estado compartido sin balanceador propio. Las comunicaciones internas necesitan autenticación mutua y autorización de nodos; pertenecer al realm como usuario no concede acceso al clúster.

E2EE sigue en los clientes. Replicar no introduce miembros MLS ni copia claves raíz personales o secretos de conversación al servidor. Sí amplía la exposición de metadatos y secretos operativos. Los nodos del clúster requieren confianza operativa mutua: no asumimos que la elección por mayoría proteja la disponibilidad o integridad del servicio frente a participantes maliciosos. Si se desean operadores mutuamente desconfiados, habría que estudiar relays independientes como arquitectura separada.

Este modo tampoco recupera un dispositivo cliente perdido ni resuelve la pérdida del coordinador de commits MLS. Son dominios de fallo distintos.

## Opciones a evaluar, sin selección

| Candidato | Evidencia consultada | Implicación para el proyecto |
|---|---|---|
| rqlite | SQLite con Raft; escrituras coordinadas por un líder y acceso por API HTTP; no es reemplazo directo de SQLite | Probar adaptación de operaciones/transacciones y semántica de aceptación, además del coste operativo |
| PostgreSQL con réplicas | Replicación síncrona/asíncrona; detección de fallo y conmutación requieren mecanismos externos | Alternativa de perfil avanzado si su operación resulta asumible |
| LiteFS | Replicación asíncrona; Fly advierte que no ofrece soporte o asistencia para el producto | No priorizarlo como base de una promesa de conservación de envíos confirmados |

Fuentes oficiales consultadas el 2026-09-04: [rqlite FAQ](https://rqlite.io/docs/faq/), [replicación PostgreSQL](https://www.postgresql.org/docs/current/warm-standby.html), [failover PostgreSQL](https://www.postgresql.org/docs/current/warm-standby-failover.html), [LiteFS](https://fly.io/docs/litefs/) y [funcionamiento de LiteFS](https://fly.io/docs/litefs/how-it-works/). Revalidar versiones, mantenimiento, licencias y plataformas cuando se inicie el prototipo. La documentación de un motor no demuestra la durabilidad de nuestra aplicación completa.

## Preparación razonable desde V1

Conservar interfaces de persistencia pequeñas, operaciones de dominio con atomicidad explícita, IDs de entrega idempotentes, reintentos y límites de retención. Separar acceso a blobs de la lógica de colas. No implementar de antemano elección de líder, descubrimiento de clúster, múltiples drivers o configuración ficticia. No se garantiza que cambiar de almacenamiento sea transparente: una API distribuida puede requerir rediseñar transacciones.

## Gates antes de adoptar HA

1. Prototipo de pérdida de nodo durante escritura, ACK, carga de archivo y cambio de líder; verificar contra el historial de operaciones del cliente los datos confirmados que sobreviven.
2. Particiones entre domicilios, pérdida de mayoría y retorno del antiguo principal: sin doble escritor ni retroceso de revocaciones conocidas.
3. Fallo del endpoint de entrada, reconexión y reintentos: sin duplicados visibles ni aceptación fingida.
4. Coherencia de DB y blobs, restauración desde backup y actualización de versiones con réplicas atrasadas.
5. Medición de RPO/RTO, latencia WAN, ancho de banda, consumo y espacio en hardware doméstico representativo; sin cifras de rendimiento asumidas.
6. Experiencia de instalación, entrada/salida de nodos y desactivación de HA. Reducir un clúster a un nodo requiere un procedimiento, no apagar las otras máquinas.

Para relays independientes los gates son distintos: entrega a dos relays con uno caído durante el envío, deduplicación de sobres recibidos por ambos, cursores por relay tras reinstalación y adjuntos con un relay ausente. El resultado del prototipo decidirá si se adopta relays independientes, clúster con estado compartido o solo respaldo. Esa elección actualizará este ADR y los contratos de protocolo y dominio antes de prometer compatibilidad o garantías nuevas.

Relaciones: [arquitectura](../ARCHITECTURE.md#9-evolución-posible-redundancia-opcional-del-realm), [ADR-004](ADR-004-sqlite-single-binary.md), [amenazas](../THREAT_MODEL.md#7-amenazas-adicionales-si-se-adopta-ha-opcional), [protocolo actual](../PROTOCOL.md) y [recuperación](ADR-006-local-first-recovery-first.md).
