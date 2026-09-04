# ADR-004 — SQLite y filesystem en un único binario servidor

- **Estado:** propuesto.
- **Fecha:** 2026-09-04.
- **Edición documental:** v0.3; alcance de comprobación en el [índice](../README.md#referencias-y-trazabilidad).

*English version: [../../adr/ADR-004-sqlite-single-binary.md](../../adr/ADR-004-sqlite-single-binary.md)*

## Contexto

El usuario objetivo aloja un círculo pequeño en un homelab. La simplicidad de instalar, copiar, actualizar y reparar importa tanto como el rendimiento. Un broker, base externa y object storage obligatorios aumentan puntos de fallo antes de demostrar que son necesarios.

## Decisión

Usar un proceso Go con SQLite en WAL para membresías, material público, control de acceso y colas. Guardar blobs cifrados inmutables en filesystem local. Empaquetar un binario servidor por plataforma y una imagen opcional con un directorio persistente.

Un realm por instancia, un escritor lógico, transacciones breves y backpressure. La base usa disco local compatible; no NFS/SMB para WAL ni escritura compartida de varias instancias. El proxy TLS y las herramientas de observabilidad son opcionales, no dependencias de datos obligatorias.

La compatibilidad del driver SQLite con build estático, licencias, mantenimiento, parámetros de durabilidad y plataformas debe validarse antes de elegirlo. Un binario distribuible no exige que todo el ecosistema use un solo lenguaje o proceso.

## Requisitos verificados de durabilidad

**Motor:** exigir SQLite 3.51.3 o posterior, o un backport documentado del arreglo WAL-reset, como 3.44.6 o 3.50.7. El fallo afecta a determinadas carreras entre escritura y checkpoint. Verificar la versión realmente embebida por el driver y por SQLCipher, no solo el paquete envoltorio. [Fuente: SQLite, WAL-reset](https://sqlite.org/wal.html).

**Confirmación:** usar `journal_mode=WAL` y `synchronous=FULL` en las conexiones que hacen escrituras durables. Con `NORMAL`, un corte de alimentación puede perder una transacción ya confirmada. Revisar también las opciones de sincronización específicas del sistema operativo; la garantía depende de que almacenamiento y VFS cumplan su contrato. [Fuente: SQLite, synchronous](https://sqlite.org/pragma.html#pragma_synchronous).

Estas condiciones son requisitos del diseño para servidor y estado criptográfico local. Un benchmark no puede relajarlas sin cambiar explícitamente la semántica ofrecida al usuario. Las pruebas deben distinguir matar el proceso de perder la alimentación del host.

## Alternativas

| Alternativa | Ventaja | Motivo para aplazar |
|---|---|---|
| PostgreSQL | Concurrencia de escritura y operación multiinstancia | Añade servicio y backup independiente sin necesidad demostrada |
| Redis/RabbitMQ | Funciones avanzadas de cola | SQLite ofrece durabilidad suficiente como hipótesis inicial |
| S3/MinIO obligatorio | Escala/gestión de objetos | Aumenta dependencias para archivos de un grupo doméstico |
| Base solo en memoria | Simplicidad superficial | Perdería entregas pendientes al reiniciar |

## Consecuencias operativas

El rendimiento de escritura y disco marca el límite; WAL no ofrece escritores concurrentes ilimitados. El perfil Standalone no promete alta disponibilidad. Se miden latencia de persistencia, locks, fan-out, tamaño de WAL y GC antes de ampliar alcance.

V1 ofrece backup offline del directorio completo tras detener limpiamente. La futura copia online debe coordinar snapshot SQLite, blobs y limpieza. Los blobs se cargan en staging y se confirman con orden de persistencia documentado; un reconciliador elimina huérfanos después de una ventana segura.

El backup del servidor contiene metadatos y secretos operativos y necesita cifrado externo y control de acceso. No sustituye al kit personal ni al archivo de historial. Restaurar no autoriza retroceder el estado criptográfico de los clientes.

Migración con backup y acceso exclusivo; rollback mediante snapshot compatible. La retención, las cuotas y la caducidad se muestran al operador y al cliente. El espacio agotado produce error, nunca una aceptación de entrega no durable.

## Criterios de aceptación

Instalar y arrancar sin DB externa; probar corte de proceso, disco lleno, WAL grande, expiración y backup/restore aislado. Medir carga representativa sobre hardware doméstico, sin afirmar rendimiento de Raspberry Pi antes de medirlo. Validar permisos del directorio y actualización entre dos versiones de esquema.

Reabrir cuando métricas demuestren saturación sostenida o se decida estudiar HA. [ADR-007](ADR-007-optional-realm-redundancy.md) registra esa posibilidad después de V1, sin sustituir esta decisión para Standalone. Elegir PostgreSQL o rqlite requeriría revisar adaptadores, operaciones atómicas y operación; no se garantiza una migración transparente ni se añade un perfil distribuido preventivamente.

Referencias: [arquitectura](../ARCHITECTURE.md), [SQLite WAL](https://sqlite.org/wal.html), [backup](https://sqlite.org/backup.html). Alcance de revisión: [índice](../README.md#referencias-y-trazabilidad).
