# ADR-003 — Servidor no confiable para contenido e identidad personal

- **Estado:** propuesto.
- **Fecha:** 2026-09-04.
- **Edición documental:** v0.2; alcance de comprobación en el [índice](../README.md#referencias-y-trazabilidad).

*English version: [../../adr/ADR-003-zero-trust-server.md](../../adr/ADR-003-zero-trust-server.md)*

## Contexto

Autohospedar permite controlar infraestructura, pero no impide robo del disco, compromiso del proceso, backups expuestos o un administrador curioso. La identidad no puede depender de que el directorio siempre entregue las claves correctas.

## Decisión

El servidor administra admisión, recursos y entrega. No es raíz de identidad, miembro MLS ni custodio de claves personales. Los clientes verifican raíces y credenciales y aplican la política de grupos.

Persistir `mailboxes`, `envelopes`, `blobs`, membresías y material público de dispositivos. No mantener entidades semánticas de conversación, títulos o roster de grupos en el servidor. Encapsular mensajes MLS y controles en sobres HPKE por destinatario; cifrar adjuntos en origen.

La recuperación de identidad se realiza con material del usuario, no con un password reset del administrador. Las aplicaciones E2EE se distribuyen mediante un canal de releases firmado independiente del realm; un cliente web servido dinámicamente por él queda fuera de V1.

## Alternativas

- TLS con mensajes legibles en servidor: no protege frente al operador o al proceso comprometido.
- E2EE con servidor como única autoridad de claves: permite sustitución de identidades si esa autoridad se compromete.
- Red de relays orientada a anonimato y sender no autenticado: reduciría algunos metadatos, pero requiere otra topología y diseño de abuso; se aplaza.

## Consecuencias

El servidor no puede buscar texto de mensajes, generar previews, moderar contenido descifrado o recuperar claves personales. La búsqueda y el historial viven en el cliente. Los avisos push son genéricos y opcionales.

«Zero-trust» se usa aquí con alcance específico, no como sinónimo de cero metadatos. El relay conoce dueño del mailbox, membresías, sesiones y destinos; puede inferir grafo social. Una sesión autenticada por envío facilita cuotas y correlación. No almacenar rooms no impide observar grupos de tráfico.

La disponibilidad, frescura global del directorio y borrado honesto no se garantizan ante un realm malicioso. El primer contacto necesita verificación externa. Un endpoint adulterado o un destinatario legítimo pueden exfiltrar plaintext.

## Criterios de aceptación

Inventario de todos los campos almacenados/transmitidos; pruebas con directorio que sustituye claves; revisión de logs/proxy/push; simulación de relay que reordena, oculta y repite; inspección de backups completos. Verificar que el cliente nunca acepta plaintext ni alta de dispositivos silenciosa como fallback.

Reabrir antes de añadir navegador de chat, bots, bridges, búsqueda remota o recuperación administrada. Cualquiera de esas funciones puede alterar la frontera de claves y necesita una decisión propia.

Referencias: [modelo de amenazas](../THREAT_MODEL.md), [dominio](../DOMAIN_MODEL.md), [fuentes](../README.md#referencias-y-trazabilidad).
