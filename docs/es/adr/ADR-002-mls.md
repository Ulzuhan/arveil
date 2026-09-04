# ADR-002 — MLS para mensajería E2EE y grupos multidispositivo

- **Estado:** propuesto; adopción de biblioteca pendiente de spike.
- **Fecha:** 2026-09-04.
- **Edición documental:** v0.2; alcance de comprobación en el [índice](../README.md#referencias-y-trazabilidad).

*English version: [../../adr/ADR-002-mls.md](../../adr/ADR-002-mls.md)*

## Contexto

Se necesitan grupos, dispositivos independientes, incorporación, retirada y evolución de claves. Crear un protocolo criptográfico propio excede el alcance y el nivel de evidencia disponible. Cifrar siempre con una clave estática de conversación facilita el prototipo pero empeora el tratamiento del compromiso.

## Decisión

Usar MLS conforme a RFC 9420, mediante biblioteca existente. Modelar cada conversación como un grupo y cada dispositivo como una leaf. Evaluar OpenMLS primero y mls-rs como alternativa; registrar versión, provider, plataformas, estado de mantenimiento y revisión de seguridad antes de seleccionar.

MLS aporta mecanismos de claves de grupo, no toda la aplicación. Nosotros debemos definir identidad, autorización, entrega, orden de commits, persistencia, replay de aplicación, archivo y recuperación. No presentar la adopción de MLS como evidencia de seguridad auditada del producto.

El perfil de prototipo propone un coordinador de commits por grupo y una política autenticada que los clientes aplican antes de aceptar estado. Sin coordinador, cambios de miembros esperan; recuperar de su pérdida crea un grupo nuevo verificado. Se prioriza una semántica conservadora sobre introducir consenso distribuido o room state en el servidor.

## Alternativas

| Alternativa | Evaluación |
|---|---|
| Integrar un protocolo tipo Signal | Opción válida, pero exige resolver por separado la arquitectura de grupos y multidispositivo de este producto |
| Adoptar Matrix/OMEMO como plataforma completa | Reduce trabajo propio y aporta interoperabilidad, pero cambia el producto y las restricciones de operación/metadata |
| Clave simétrica estática por grupo | Implementación aparente simple; no satisface evolución de claves y exposición histórica deseadas |
| Diseñar primitivas/ratchet propios | Rechazado: carga de seguridad y revisión injustificable |

## Consecuencias y límites

MLS exige persistir estado correcto y manejar epochs, KeyPackages, Welcome y miembros ausentes. La librería debe permitir validación de credenciales y política, inspección de commits antes de fusionar y transacciones de almacenamiento coherentes.

Forward secrecy depende de eliminación de secretos y no protege plaintext archivado. PCS requiere una actualización honesta después de que termine el compromiso. El nuevo dispositivo no recibe historia automáticamente; la transferencia explícita es una función independiente. La retirada no tiene efecto retroactivo y no es instantánea para clientes aislados.

El coordinador simplifica carreras, pero introduce una dependencia de disponibilidad para cambios de estado. No se oculta al usuario ni se confunde con una garantía del estándar. Un coordinador malicioso tampoco debe poder sustituir identidades ajenas sin credenciales válidas; las altas permitidas por política siempre son visibles.

## Condiciones de dependencias verificadas

OpenMLS declara la suite candidata del proyecto y ofrece providers de almacenamiento, pero eso no demuestra una transacción conjunta con nuestra outbox. En builds distribuidos se prohíben las features `content-debug` y `crypto-debug`, que permiten imprimir contenido o claves. La comprobación debe incluir features transitivas. [Fuente: OpenMLS](https://github.com/openmls/openmls#features).

El README de mls-rs declara que aún no ha recibido una auditoría completa de seguridad de terceros; además, marca aspectos de Rust Crypto y Web Crypto como experimentales. Su conformidad con RFC 9420 no sustituye esa revisión. Se comparan versión y provider concretos, no solo el nombre de la biblioteca. [Fuente: mls-rs](https://github.com/awslabs/mls-rs#security-notice).

El coordinador único permanece como hipótesis de prototipo. Su retirada o revocación no se resuelve mediante un commit que lo elimine a sí mismo: el comportamiento conservador detallado en [PROTOCOL](../PROTOCOL.md#cambios-orden-y-particiones) es cerrar el grupo afectado y crear uno nuevo verificado. Antes de distribuir V1 hay que probar ese flujo y decidir si su coste de uso exige un mecanismo de sucesión con un ADR propio.

## Criterios de aceptación

Vectores oficiales y pruebas de biblioteca; grupos con varios dispositivos; Add/Remove/Update; paquetes repetidos; commits concurrentes o no autorizados; mensajes desordenados; crash entre cifrado y commit local; reingreso tras perder epochs. Fijar límites de secretos antiguos retenidos.

Reabrir si no se puede imponer la política o garantizar atomicidad con la biblioteca, o si la experiencia del coordinador hace inviable el uso diario. No parchear esos problemas restaurando epochs antiguos.

Referencias: [protocolo](../PROTOCOL.md), [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420), [RFC 9750](https://www.rfc-editor.org/rfc/rfc9750). Alcance de revisión: [índice](../README.md#referencias-y-trazabilidad).
