# Base de aplicación: estado implementado

Estado: registro actualizado el 23 de septiembre de 2026; los resultados de aceptación anteriores conservan su alcance original. No equivale a una release ni a una auditoría de seguridad. Esta página actualiza las propuestas anteriores para la capa de cliente.

## Arquitectura actual

```text
CLI ────────────────────────────────┐
Flutter → puente Rust ─┴→ arveil-app → arveil-core
                                      │
                                      └→ transporte Noise/WebSocket → relay Go
```

`arveil-app` coordina operaciones y devuelve resultados estructurados. `arveil-core` conserva identidad, MLS, persistencia y primitivas de entrega. El relay sigue siendo un proceso Go independiente; no contiene las claves E2EE de los clientes. El cliente Flutter abre perfiles cifrados, da de alta por invitación, vincula dispositivos y exporta/restaura kits cifrados de identidad mediante el puente. La interfaz permite crear conversaciones tras comparar rutas, leer historial paginado, enviar texto sin conexión y sincronizar.

## Cambios realizados y evidencia

| Cambio | Implementación y comprobación |
|---|---|
| Extracción del chat de la CLI | [arveil-app](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/src/lib.rs) contiene conversaciones, envío, sincronización, revocaciones y adjuntos. [chat.rs](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-cli/src/chat.rs) adapta argumentos y presenta resultados. |
| Contrato de operaciones | `ClientCommand`, `CommandOutput`, `ApplicationError`, `StateChange` y `MessageReceipt`. Los errores conservan `partial_result()`; la aceptación local se registra después del commit. No se deducen categorías de error del texto. |
| Correlación de entregas | [Delivery::pending](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-core/src/delivery.rs) incluye `event_id`. El cursor avanza con `MAX(actual, nuevo)`. |
| Configuración explícita del perfil | `ProfileConfig` aporta ruta, clave, autoridad de TLS y caducidades; la biblioteca no lee ninguna variable de entorno. La CLI traduce las suyas. `Debug` oculta la clave, y una clave mal formada se rechaza antes de crear nada. |
| Vida de la sesión | Una segunda apertura independiente de la misma ruta canónica devuelve `AlreadyOpen`, sea cual sea la clave que aporte; compartir consiste en clonar el handle. `open` abre la base, así que una clave incorrecta falla ahí y no en el primer comando. `close` deja de admitir trabajo, espera al que corre y une el hilo trabajador, que es quien posee el bloqueo; abandonar el último handle sigue el mismo camino. |
| El alta se reanuda | Una inscripción por perfil, con su fase escrita según cada paso se vuelve durable y la invitación guardada como hash y no como token. Repetir la misma inscripción continúa donde se quedó y conserva una identidad, un buzón y una ruta; otro realm u otra invitación se rechazan y dejan intacta la inscripción registrada. |
| Canjear una invitación dos veces | El relay registra lo que produjo un canje —token, identidad y credencial— dentro de la misma transacción que consume el uso, y responde a la repetición de esa terna exacta con el resultado que registró, no con un conflicto. Otra credencial para la misma identidad sigue siendo conflicto: la igualdad de un hash no es autorización. Una repetición no consume otro uso, y una base escrita por un relay más nuevo se rechaza antes de modificar nada. La creación del buzón ya reutiliza la petición y las capabilities persistidas. El lote inicial de KeyPackages y su estado privado MLS se confirman juntos antes de publicarlos; una respuesta perdida reenvía los mismos bytes, y completar el alta impide generar otro lote. El relay aplica el cupo después de deduplicar y nunca reactiva paquetes consumidos. |
| La clave del perfil pertenece a la plataforma | 32 bytes aleatorios del sistema, generados en Rust y guardados por Keychain o Keystore, sin sincronizar. iOS/Android usan protección ligada al dispositivo; macOS utiliza el llavero clásico y su control de acceso por app. Nunca derivados de una frase. Un perfil cuya clave desapareció se informa, nunca se le da una nueva: eso respondería «aquí no hay nada» a quien tiene su historial en disco. Android rechaza copia en nube y transferencia entre dispositivos; Apple marca el directorio del perfil como excluido en cada arranque. Un acceso denegado al almacén se informa sin recurrir a claves en texto plano. |
| Un pánico termina su sesión | Un comando que entra en pánico se contiene en el límite: quien llamó recibe un fallo tipado con el nombre de la operación, lo que estuviera encolado detrás se responde en lugar de quedarse esperando, y nada más se ejecuta en esa sesión. Una transacción interrumpida por el desenrollado revierte, porque `unit_of_work` ahora la cierra desde `Drop`. El perfil queda intacto en disco y vuelve a abrirse tras cerrar la sesión. Esto vale donde la compilación desenrolla; una que aborte en pánico termina el proceso y ningún contrato sobrevive a eso. |
| Progreso durante el trabajo | Una proyección acotada llega a quien observa según se registra cada cambio, no al responder la operación: mensaje encolado y recibido, publicación, estado de entrega, transferencias, sincronización, emparejamiento y pasos del alta. Quien se queda atrás pierde eventos y se le dice cuántos, para que relea en vez de fiarse de una vista parcial; el resultado durable sigue llevándolo todo. |
| Historial paginado | `QueryHistoryPage` recibe conversación, cursor y límite acotado; los identificadores solo crecen, así que una página no se desplaza cuando llegan eventos mientras alguien lee hacia atrás. Los resúmenes leen un recuento y la fila más reciente en lugar de todos los cuerpos. Las lecturas locales ya no exigen un realm inscrito. |
| Admisión acotada | El trabajo se cuenta por tipo: dos sincronizaciones, treinta y dos mutaciones y ciento veintiocho consultas. Más allá, el comando se rechaza con un `Busy` tipado que no empezó nada; los huecos se liberan cuando el trabajo termina, no cuando quien llamó se marcha. Las consultas tienen sitio propio y responden mientras las sincronizaciones están saturadas. |
| Ejecutor por perfil | `Application` comparte ejecutor por ruta canónica. Un runtime de una hebra multiplexa futuros durante la red; los tramos síncronos de MLS/SQLite no se intercalan. Los eventos usan contexto por operación. La API pública de llamada sigue siendo bloqueante. |
| Exclusión por operación | Sincronización, consulta de KeyPackages por red y reposición comparten una exclusión por perfil. `CompleteLink` y `ConfirmPairing` comparten otra exclusión, para evitar finalizadores simultáneos. Las consultas pueden avanzar durante esperas de red. |
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

La ejecución original de la base con `cargo test --workspace --locked` terminó con 72 pruebas correctas (incluida una prueba auxiliar de procesos) y una ignorada; demo, interop, q3-capture y las fases 1–4 también se ejecutaron en local. La aceptación de M3b.0 se ejecutó sobre el propio sistema en macOS y en un emulador Android (Android 15, API 35, arm64); todavía sin teléfono físico. La [matriz de plataformas](PLATFORMS.md) recoge el toolchain fijado y los comandos. `git diff --check` pasó. Es un resultado del checkout local en ese momento, no una afirmación sobre todas las plataformas o la CI remota.

Pruebas destacadas:

- `overlapping_pairing_confirmations_share_one_mailbox_and_route` y `direct_grant_completion_resumes_after_network_failure`, en `arveil-app/src/lib.rs`.
- `late_response_cannot_contaminate_a_second_request`, en `arveil-app/src/carrier.rs`.
- [Bloqueo entre procesos](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/tests/profile_lock.rs): cierre normal, terminación abrupta, perfiles distintos y alias simbólicos en Unix.
- [Protección de la CLI legacy](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-cli/tests/profile_lock.rs).

El implementador informó además de Clippy y fases 1–4 correctos durante las iteraciones. La última revisión no volvió a ejecutar esas comprobaciones; antes de publicar debe registrarse una ejecución de aceptación contra un commit concreto.

## Límites que permanecen

- El cliente gráfico abre perfiles cifrados y permite el alta por invitación, su reintento y la consulta del avance al reabrir. Emparejamiento y kit de identidad ya tienen interfaz. La conversación de texto está implementada; siguen pendientes adjuntos y gestión de dispositivos. Existe empaquetado experimental ZIP/APK; falta aceptación en un móvil físico.
- Solo la CLI lee ya variables de entorno, y sigue eligiendo perfil sin cifrar cuando no hay clave. El almacén seguro se ha probado en emulador Android y en macOS con firma ad hoc y llavero clásico. Quedan pendientes teléfono físico y una instalación nueva descargada.
- El puente Rust ejecuta las llamadas bloqueantes fuera del hilo de interfaz y expone un flujo incremental de eventos. Siguen pendientes la cancelación general de operaciones y la aceptación completa del ciclo de vida de cada plataforma.
- Algunos eventos de archivos y membresía necesitan identificadores adicionales para actualizar elementos concretos de la UI. El progreso es una proyección: los cambios que no modela solo llegan en el resultado durable.
- Recuperación de un grupo MLS desincronizado no es sinónimo de `sync`; el método ficticio `recover_conversation` fue retirado. Sigue pendiente un flujo real.
- La sucesión del coordinador depende de revocaciones verificadas; no es una elección automática ante una desconexión.
- El relay aplicaba sus pragmas una vez, así que solo la conexión que los ejecutó tenía tiempo de espera o exigía claves foráneas; ahora van en la cadena de conexión, y una prueba sostiene varias conexiones y comprueba cada una. Las transacciones de escritura también reservan el turno antes de leer (`BEGIN IMMEDIATE`), evitando el fallo al pasar de lectura a escritura durante la limpieza u otras peticiones; las lecturas WAL siguen siendo concurrentes. Véase la [regresión de concurrencia](../PHASE1.md#storage-contention-regression). El tamaño del pool sigue sin acotar y queda pendiente.
- La CLI del kit de identidad ya usa el servicio de aplicación. Archivos y contactos conservan comandos legacy que habrá que exponer por esa capa si la GUI los necesita.

Siguiente fase: [plan Flutter](PHASE3B.md). Decisión: [ADR-009](adr/ADR-009-flutter-first.md).

## Alta por invitación

El formulario mantiene la invitación solo en memoria y la borra al completar el alta o cerrar el perfil. El ejecutor responde con una consulta tipada del estado al abrir y tras los intentos de alta. Los datos de relay/invitación mal formados se rechazan antes de crear la identidad. La interfaz muestra categorías de error sin interpolar rutas ni diagnósticos remotos. Las pruebas cubren reintentos, envíos duplicados, cierre de aperturas tardías y mensajes sin detalles privados. Es la parte de alta por invitación de M3b.2. Los cambios de emparejamiento y kit descritos abajo no cierran el hito: faltan aceptación en dispositivos físicos y comprobaciones de los diálogos nativos. La implementación de KeyPackages se registra más abajo.

## Emparejamiento y kit de identidad (23 de septiembre de 2026)

El alta ofrece invitación, vinculación y restauración. El dispositivo nuevo
compara manualmente el código corto antes de aplicar su autorización; un código
incorrecto impide finalizar. Si la espera se interrumpe **antes de recibir la
comparación**, hay que cancelar y generar otro código. La comparación recibida
sobrevive a la reapertura; tras confirmar, la finalización retoma el mismo
dispositivo y buzón. Cancelar solo detiene el alta local: no revoca una
autorización ya emitida por el administrador. Su pantalla lo explica antes
de autorizar y muestra después la comparación. La espera del administrador
está acotada a 90 segundos; todavía no dispone de cancelación.

La exportación guarda solo el archivo cifrado mediante el diálogo del sistema.
Su clave separada aparece únicamente tras guardar, desaparece al salir o pasar
a segundo plano y Arveil no la conserva. Posponer el kit muestra el riesgo de
pérdida de identidad. Restaurar exige perfil vacío, kit, clave y bootstrap del
relay original, con confirmación de revocación y ausencia del historial anterior.
Usa el kit más reciente y expórtalo de nuevo tras cambiar dispositivos. Un kit
antiguo puede rechazarse si el relay conoce un manifiesto posterior. Recuperar
identidad no restaura historial ni estado de grupos MLS.

CLI y GUI comparten preparación local atómica y un registro durable. Un error
de transporte conserva la misma credencial y permite reanudar sin volver a
importar el archivo. El relay guarda la petición firmada exacta y la secuencia
previa en una sola transacción: acepta su repetición autenticada y rechaza
credenciales cambiadas, caducadas o revocadas. Requiere el relay actualizado
(esquema 4); los anteriores no garantizan el reintento tras perder la respuesta
de recuperación. Haz una copia antes de actualizar: una versión anterior
rechaza el esquema nuevo. Las advertencias de retroceso persisten al reabrir.

Las pruebas cubren consentimiento, comparación incorrecta/caducada, cancelación
durante la espera, exportación cancelada, eliminación de la clave al pasar a
segundo plano, rollback de la preparación y reintentos tras reiniciar cliente
y relay. La reproducción nativa está en el
[README de Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md).
Estos cambios no publican ni reemplazan el candidato alfa existente.

Comprobaciones de este cambio: 87 tests Rust pasan (uno ignorado), Go con
detector de carreras, análisis Flutter y 16 pruebas de widgets/unidad,
aceptación nativa macOS y emulador Android, fases 2, 3 y 3b y documentación bilingüe en modo estricto.
Son resultados locales; la matriz de plataformas delimita su alcance.

## Disponibilidad y reposición de KeyPackages (23 de septiembre de 2026)

El perfil muestra una consulta fechada de las claves de un solo uso disponibles
en el relay. Abrir el perfil lee el estado local sin consultar la red; un dato
desconocido se distingue de cero. Si falla la actualización, se conserva el
último dato con una advertencia visible. El agotamiento impide que otros
dispositivos inicien conversaciones nuevas con este dispositivo; las
conversaciones existentes conservan sus propias claves.

Cuando quedan tres paquetes o menos, la reposición prepara los necesarios
para llegar a diez. Los bytes públicos del lote y su estado privado MLS se
confirman juntos antes de publicar. La sincronización CLI y la GUI comparten
ese registro y serializan las operaciones de red. Tras perder una respuesta,
reabrir y reintentar envía el mismo lote; el relay no reactiva claves consumidas.
Si todo el lote se consumió antes del reintento, la confirmación elimina el
registro pendiente y otra reposición explícita puede generar claves nuevas.
La interfaz consulta de nuevo tras publicar para mostrar el recuento del relay,
teniendo en cuenta que otra persona puede consumir claves mientras tanto.

Comprobaciones actuales: 89 pruebas Rust pasan (una ignorada), Clippy, 20 pruebas
Flutter de widgets/unidad y aceptación nativa macOS y emulador Android. La fase 4 local pasó,
incluyendo consumo real por grupos MLS y reposición CLI; omitió la compilación
Docker al no estar disponible. La [matriz de plataformas](PLATFORMS.md)
delimita la prueba GUI con consumo simulado y la evidencia por plataforma.
Siguen pendientes teléfono físico y diálogos nativos. La versión fuente es
`0.1.0+4`; el candidato alfa existente no cambia.

## Interfaz de conversaciones (M3b.3)

El cliente fuente `0.1.0+5` incorpora lista/detalle adaptable, compartir la ruta de
este dispositivo explícitamente, comparación del número de seguridad de cada
contacto, creación verificada de grupos, historial paginado y composición de texto.
Editar las rutas invalida la comparación. Rust valida tamaños, dispositivos
repetidos y los números exactos antes de verificar los contactos. Se utiliza el
protocolo de identidad/MLS existente; no equivale a una auditoría independiente.

`QueueMessage` confirma estado MLS, evento y outbox cifrado antes de devolver el
recibo, sin acceder a la red. Flutter borra solo el borrador aceptado y sincroniza
los sobres guardados. Si la creación falla después del commit, el bridge devuelve
el grupo guardado con un aviso para no crearlo otra vez. La CLI comparte la misma
transacción local de envío. El texto admite hasta 32 KiB de UTF-8.

El historial responde durante una sincronización. La pantalla relee las
proyecciones con el progreso y al completar operaciones; en primer plano sincroniza
cada diez segundos y al reanudarse, además del reintento manual. No hay push ni
entrega en segundo plano. La actualización reconcilia el historial mostrado en páginas de 50, conserva
las páginas anteriores que abrió el usuario y se detiene si cambia de pantalla
o selección. Se distingue
almacenamiento local, aceptación del relay, entrega no disponible y recepción en
este dispositivo. No se afirma lectura humana, autor autenticado ni hora del
mensaje. Los nombres de contactos se implementan en M3b.4 más abajo; acciones de adjuntos
y gestión de miembros quedan para entregas posteriores.

Las regresiones cubren comparación simétrica y confirmación atómica de contactos,
encolado/reapertura sin relay, resultados del bridge tras commit, historial durante
red bloqueada, esperas compartidas de sincronización, cancelación del observador antes de su arranque, selecciones tardías, paginación con nuevos mensajes, invalidación de
rutas editadas, texto recibido, conservación de borradores y doble envío.
Las pruebas de ciclo de vida cubren el paso a segundo plano durante el arranque y
la conservación del controlador y borrador cuando Flutter reconstruye la ruta.
La [matriz de plataformas](PLATFORMS.md) detalla el alcance nativo y el
[README Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md)
aporta el comando reproducible con un relay aislado.

## Contactos locales y selección de destinatarios (primera entrega de M3b.4)

El cliente fuente `0.1.0+6` incorpora agenda, alias locales, verificación explícita
del número de seguridad y creación desde contactos guardados. Las conversaciones
muestran nombres y una lista de participantes con identidad, dispositivo y estado
de verificación/revocación. Estos nombres no autentican al autor de cada mensaje
ni se sincronizan con otros perfiles.

Las rutas, incluidas sus capabilities de buzón, se guardan en la tabla nueva
`contact_routes` dentro del perfil cifrado de la GUI. Las listas solo exponen
identificadores y revocación, sin capabilities. Guardar, renombrar y verificar
pasan por el ejecutor del perfil; contacto, alias, ruta y verificación opcional
se confirman juntos. Editar una ruta invalida la comparación de la UI. Importar
el mismo dispositivo actualiza su ruta sin duplicarlo; un nombre vacío al
importar conserva el alias existente, mientras que renombrar permite borrarlo.

La creación recibe identificadores guardados de identidad/dispositivo. Rust
relee sus rutas y exige contactos verificados, correspondencia de identidad,
raíz y dispositivo, dispositivos distintos y ninguna revocación local conocida
antes de crear por red. Se mantiene el recibo con aviso tras commit para evitar
que un fallo de publicación invite a crear de nuevo el grupo guardado. Admite
hasta 16 dispositivos; revocaciones aún desconocidas y rutas caducadas siguen
dependiendo de la sincronización y validación del relay.

Los contactos aprendidos en conversaciones se pueden nombrar y verificar; si
no tienen una ruta guardada hay que importar una antes de seleccionarlos. Alias
y verificación sobreviven a la reapertura. El asistente de aceptación de
conversaciones recorre ahora este flujo antes de texto bidireccional, modo sin
red, reconexión y paginación. Quedan pendientes de M3b.4 adjuntos, gestión de
dispositivos e interfaz de archivos de historial.
