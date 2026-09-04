# ADR-005 — Identidad independiente del realm y claves por dispositivo

- **Estado:** propuesto.
- **Fecha:** 2026-09-04.
- **Edición documental:** v0.2; alcance de comprobación en el [índice](../README.md#referencias-y-trazabilidad).

*English version: [../../adr/ADR-005-cryptographic-identity.md](../../adr/ADR-005-cryptographic-identity.md)*

## Contexto

Perder un servidor o cambiar de dominio no debe cambiar quién es una persona. El administrador puede decidir quién usa la infraestructura, pero no debe poder fabricar una nueva clave y hacerla pasar por un contacto ya verificado. Multidispositivo requiere retirar un teléfono sin invalidar todos los demás.

## Decisión

Generar una raíz Ed25519 local y usar el hash de su representación pública versionada como identidad. Separar `Identity`, `Device` y `RealmMembership`. Nombres y alias no participan en autenticación criptográfica.

Cada dispositivo recibe claves independientes para MLS, autenticación de transporte y recepción exterior. La raíz firma una credencial que las vincula a dispositivo, identidad, usos y validez. Un manifiesto firmado, secuenciado y encadenado enumera credenciales activas y revocadas.

V1 exige acceso explícito a la raíz para emitir credenciales y manifiestos. Puede estar cifrada en un dispositivo de administración o recuperarse mediante kit. No se copia a cada dispositivo ni se concede a cualquier miembro la facultad implícita de firmar nuevos devices. Delegaciones y recuperación social quedan fuera hasta tener un diseño revisado.

Los contactos se verifican mediante QR/fingerprint y guardan la raíz y máximo de manifiesto conocido. El realm publica, pero el cliente autentica. El acceso a cada grupo es otra autorización y requiere incorporación MLS explícita.

## Alternativas

- Usuario/contraseña como raíz: simplifica reset, pero devuelve al servidor el poder de sustituir identidad.
- Una clave privada compartida entre todos los dispositivos: dificulta revocación individual y permite clonar estados.
- Certificados personales emitidos exclusivamente por el realm: el servidor se convierte en autoridad de suplantación.
- Delegación ilimitada entre dispositivos: alta cómoda, pero un teléfono comprometido puede persistir autorizando otros.
- Identidades por relación exclusivamente: reduce correlación, pero complica recuperación y UX; puede estudiarse después.

## Consecuencias y límites

Se obtiene continuidad entre servidores, a costa de responsabilidad sobre la raíz y correlación si se reutiliza en varios realms. Perder la raíz y todos sus backups impide emitir nuevas credenciales con esa identidad. Un dispositivo existente puede seguir operando mientras sus grupos/credenciales lo permitan, pero no reconstruir la raíz.

Comprometer la raíz compromete la autoridad de identidad: no basta con revocar un teléfono. V1 exige nueva raíz, contacto externo y reverificación; una firma de la raíz comprometida no demuestra que la nueva pertenezca al usuario legítimo.

Un manifiesto firmado demuestra origen, no frescura absoluta. Se rechazan retrocesos conocidos y conflictos; participantes aislados pueden no ver una revocación reciente. Restaurar desde un kit viejo exige contrastar versiones con fuentes supervivientes o reverificar.

La revocación exige manifiesto nuevo, invalidación operativa y Remove/Commit en cada grupo. La UI presenta estos pasos y estados parciales; no afirma una retirada instantánea global.

## Criterios de aceptación

Alta legítima, dispositivo falso, credencial con clave sustituida, raíz cambiada con mismo username, manifiesto antiguo o bifurcado, pérdida de administrador, recuperación con kit y retiro de un dispositivo offline. Cada caso debe producir resultados visibles y no sustituir confianza silenciosamente.

Reabrir para delegación, rotación de raíz con continuidad, transparencia de claves o identidades por contacto. Cada extensión debe declarar qué autoridad nueva introduce.

Referencias: [dominio](../DOMAIN_MODEL.md), [flujos de identidad](../PROTOCOL.md), [fuentes](../README.md#referencias-y-trazabilidad).
