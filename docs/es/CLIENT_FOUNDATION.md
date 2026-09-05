# Base de aplicación: estado implementado

Estado: implementación local revisada durante las iteraciones del 5 de septiembre de 2026. No equivale a una release ni a una auditoría de seguridad. Esta página actualiza las propuestas anteriores para la capa de cliente.

## Arquitectura actual

```text
CLI ────────────────────────────────┐
Flutter → puente Rust (pendientes) ─┴→ arveil-app → arveil-core
                                      │
                                      └→ transporte Noise/WebSocket → relay Go
```

`arveil-app` coordina operaciones y devuelve resultados estructurados. `arveil-core` conserva identidad, MLS, persistencia y primitivas de entrega. El relay sigue siendo un proceso Go independiente; no contiene las claves E2EE de los clientes. Ya existen cliente Flutter y puente: abren, consultan y cierran un perfil. No existe interfaz de mensajería.

## Cambios realizados y evidencia

| Cambio | Implementación y comprobación |
|---|---|
| Extracción del chat de la CLI | [arveil-app](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/src/lib.rs) contiene conversaciones, envío, sincronización, revocaciones y adjuntos. [chat.rs](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-cli/src/chat.rs) adapta argumentos y presenta resultados. |
| Contrato de operaciones | `ClientCommand`, `CommandOutput`, `ApplicationError`, `StateChange` y `MessageReceipt`. Los errores conservan `partial_result()`; la aceptación local se registra después del commit. No se deducen categorías de error del texto. |
| Correlación de entregas | [Delivery::pending](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-core/src/delivery.rs) incluye `event_id`. El cursor avanza con `MAX(actual, nuevo)`. |
| Configuración explícita del perfil | `ProfileConfig` aporta ruta, clave, autoridad de TLS y caducidades; la biblioteca no lee ninguna variable de entorno. La CLI traduce las suyas. `Debug` oculta la clave, y una clave mal formada se rechaza antes de crear nada. |
| Vida de la sesión | Una segunda apertura independiente de la misma ruta canónica devuelve `AlreadyOpen`, sea cual sea la clave que aporte; compartir consiste en clonar el handle. `open` abre la base, así que una clave incorrecta falla ahí y no en el primer comando. `close` deja de admitir trabajo, espera al que corre y une el hilo trabajador, que es quien posee el bloqueo; abandonar el último handle sigue el mismo camino. |
| Ejecutor por perfil | `Application` comparte ejecutor por ruta canónica. Un runtime de una hebra multiplexa futuros durante la red; los tramos síncronos de MLS/SQLite no se intercalan. Los eventos usan contexto por operación. La API pública de llamada sigue siendo bloqueante. |
| Exclusión por operación | Una sola sincronización activa por perfil. `CompleteLink` y `ConfirmPairing` comparten otra exclusión, para evitar finalizadores simultáneos. Las consultas pueden avanzar durante esperas de red. |
| Exclusión transaccional | [SharedConn::unit_of_work](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-core/src/storage.rs) mantiene un mutex reentrante durante toda la transacción; los callbacks de almacenamiento MLS pueden utilizar la misma conexión. `Client.conn` es privado. |
| Transporte con límites de tiempo | [carrier.rs](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/src/carrier.rs) limita conexión, handshake, petición y cierre. Un timeout de petición elimina el socket y el estado Noise. Se exige reconexión. |
| Descargas recuperables | Un error de transporte conserva `file-pending` y el archivo `.part`; una sincronización posterior puede reanudar. No se convierte ese fallo transitorio en indisponibilidad definitiva. |
| Alta y vinculación reutilizables | [onboarding.rs](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/src/onboarding.rs) contiene identidad, inscripción, grants y emparejamiento. [link.rs](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-cli/src/link.rs) es presentación. |
| Emparejamiento explícito | Inicio, espera, aprobación, consulta, confirmación y cancelación identifican la sesión. Se comprueban código y caducidad antes de iniciar la finalización. Cancelar tras el punto de compromiso devuelve `AlreadyCommitted`. |
| Finalización reanudable | Grant directo y confirmación comparten `complete_device_link`. Las fases persistidas avanzan desde `Committing` hasta `Complete`; se valida la identidad del grant de reintento. Las pruebas cubren fallo inicial de red, éxito posterior y confirmaciones concurrentes con un solo buzón/ruta. |
| Exclusión entre procesos | `ProfileGuard` y `Application` adquieren un bloqueo del SO sobre `.arveil-profile.lock`, después de canonicalizar el directorio. La CLI protege también comandos legacy. Otro proceso recibe `ProfileInUse`; el archivo de bloqueo no se elimina para liberar el lock. |

El bloqueo entre procesos permite alternar GUI y CLI sobre el mismo perfil. No permite que ambos procesos lo utilicen simultáneamente. Un acceso simultáneo futuro requeriría un propietario único con IPC, fuera del plan inicial.

Los enlaces a código siguen `main` del repositorio; este registro local debe integrarse en el mismo PR y merge que los cambios de código correspondientes, o después de ellos. No publicar primero un PR solo documental con enlaces a archivos todavía ausentes en `main`: Pages se despliega independientemente y MkDocs estricto no comprueba destinos externos. Antes de publicar, verificar que todas las rutas enlazadas existen en el commit de destino; una referencia SHA/tag solo sirve si ya está publicada y contiene esos archivos.

## Evidencia de revisión

La última ejecución de `cargo test --workspace --locked` terminó con 72 pruebas correctas (incluida una prueba auxiliar de procesos) y una ignorada; demo, interop, q3-capture y las fases 1–4 también se ejecutaron en local. La aceptación de M3b.0 se ejecutó sobre el propio sistema en macOS y en un emulador Android (Android 15, API 35, arm64); todavía sin teléfono físico. La [matriz de plataformas](PLATFORMS.md) recoge el toolchain fijado y los comandos. `git diff --check` pasó. Es un resultado del checkout local en ese momento, no una afirmación sobre todas las plataformas o la CI remota.

Pruebas destacadas:

- `overlapping_pairing_confirmations_share_one_mailbox_and_route` y `direct_grant_completion_resumes_after_network_failure`, en `arveil-app/src/lib.rs`.
- `late_response_cannot_contaminate_a_second_request`, en `arveil-app/src/carrier.rs`.
- [Bloqueo entre procesos](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/tests/profile_lock.rs): cierre normal, terminación abrupta, perfiles distintos y alias simbólicos en Unix.
- [Protección de la CLI legacy](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-cli/tests/profile_lock.rs).

El implementador informó además de Clippy y fases 1–4 correctos durante las iteraciones. La última revisión no volvió a ejecutar esas comprobaciones; antes de publicar debe registrarse una ejecución de aceptación contra un commit concreto.

## Límites que permanecen

- El cliente gráfico abre, consulta y cierra un perfil y nada más: alta, emparejamiento, conversación, adjuntos y gestión de dispositivos no tienen interfaz. No hay instaladores gráficos ni validación en un dispositivo móvil físico.
- Solo la CLI lee ya variables de entorno, y sigue eligiendo perfil sin cifrar cuando no hay clave. La integración con los almacenes de claves del sistema sigue pendiente (M3b.1).
- La API bloqueante necesita un adaptador asíncrono para Dart. Los eventos se devuelven por operación; una suscripción continua y cancelación general todavía requieren contrato.
- Algunos eventos de archivos y membresía necesitan identificadores adicionales para actualizar elementos concretos de la UI. Las consultas de historial necesitan paginación para uso continuado.
- Recuperación de un grupo MLS desincronizado no es sinónimo de `sync`; el método ficticio `recover_conversation` fue retirado. Sigue pendiente un flujo real.
- La sucesión del coordinador depende de revocaciones verificadas; no es una elección automática ante una desconexión.
- El pool SQLite del relay y su configuración por conexión, señalado en la revisión arquitectónica inicial, necesita seguimiento independiente. Las refactorizaciones del cliente no lo resuelven.
- Todavía quedan comandos legacy, incluidos recuperación/archivos y contactos, que habrá que exponer por la capa de aplicación si la GUI los necesita.

Siguiente fase: [plan Flutter](PHASE3B.md). Decisión: [ADR-009](adr/ADR-009-flutter-first.md).
