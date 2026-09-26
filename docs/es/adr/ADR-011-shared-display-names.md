# ADR-011 — Nombres que cada persona elige para sí

- **Estado:** propuesta. Nada de lo que describe está implementado.
- **Fecha:** 2026-09-26.
- **Alcance:** que cada persona elija el nombre con el que la ven los demás, compartido de extremo a extremo con los miembros de sus conversaciones y nunca con el realm. Los nombres locales, los que cada perfil pone a sus contactos, siguen igual.

[English version](../../adr/ADR-011-shared-display-names.md).

## Contexto

Hoy un nombre es local y solo local. Un perfil nombra a sus contactos; el nombre vive en su base de datos cifrada, no viaja y no autentica a nadie ([ADR-005](ADR-005-cryptographic-identity.md): «Los nombres y alias no participan en la autenticación criptográfica»; [fase 4](../../PHASE4.md), M4.8). Nadie puede elegir cómo le ven los demás. Hasta que alguien te pone nombre, eres ocho caracteres hexadecimales de tu identidad.

La primera instalación de la beta hizo visible el coste. Una persona que instalaba la app buscó dónde poner su propio nombre y no lo encontró. La app muestra ahora «Sin nombre · a1b2c3d4» y pide poner nombre a cada contacto ([registro de implementación](../CLIENT_FOUNDATION.md#poner-nombre-a-quien-no-lo-tiene-26-de-septiembre-de-2026)). Eso deja clara la carencia, pero cada persona tiene que seguir nombrando a todas las demás, en cada perfil y en cada dispositivo vinculado, porque los nombres locales no se sincronizan entre dispositivos.

Lo que ofrece hoy el protocolo:

- **Los eventos de aplicación** dentro de MLS son un CBOR `{kind, body}`. Los tipos son `roster`, `manifest`, `text` y `file`.
- **Un cliente descarta los tipos que no conoce.** Confirma el evento, no guarda nada, no cuenta nada como no leído y sigue. Así que un tipo nuevo es aditivo: los clientes instalados lo ignoran.
- **Un tipo existente no se puede ampliar.** Un cuerpo mal formado deshace toda la unidad de entrega y bloquea el buzón hasta que se reintenta. Las líneas del roster, por ejemplo, tienen que ser rutas de exactamente nueve campos, así que añadir un nombre a una ruta atascaría a todos los clientes anteriores.
- **Cada identidad tiene una clave raíz Ed25519.** Firma las credenciales de los dispositivos y un manifiesto de dispositivos con secuencia, y los manifiestos ya viajan como evento de grupo y solo se aceptan con la raíz guardada y una secuencia creciente. La raíz se guarda en el dispositivo de administración, o en uno recuperado, y no se copia a los dispositivos vinculados.
- **MLS autentica el dispositivo que envía** cada evento, y el roster asocia dispositivos con identidades.

## Decisión (propuesta)

**1. Un perfil es una declaración firmada por la raíz de la identidad.** Es un `SignedObject` con el contexto `arveil/profile/v1` y el cuerpo `{sequence, name}`:
- `sequence` crece con cada cambio;
- `name` es un texto, o vacío, que quita el nombre.

Reutiliza el patrón de firma del manifiesto de dispositivos. El nombre pertenece a la identidad y no a un dispositivo, así que todos los dispositivos de esa identidad muestran el mismo nombre.

**2. Viaja como un evento de aplicación MLS nuevo, `profile`, y por ningún otro sitio.** Un dispositivo anuncia el último perfil de su identidad:
- a una conversación, cuando la crea o cuando lo añaden;
- a todas sus conversaciones, cuando cambia el nombre.

El realm solo ve texto cifrado de tamaño corriente. Nunca recibe ni guarda un nombre, y no se añade nada a las rutas, las invitaciones, los KeyPackages ni las tablas del relay.

**3. Quien lo recibe acepta un perfil bajo la raíz que ya conoce de esa identidad**, y solo si su `sequence` es mayor que la del último que aceptó. Lo guarda en una tabla de nombres anunciados, aparte de los nombres locales y del historial: nunca es un mensaje, nunca cuenta como no leído y nunca entra en un archivo.

**4. El nombre local siempre gana.** Un nombre anunciado solo se muestra cuando este perfil no ha puesto nombre a la persona, y se marca como suyo: por ejemplo «~Lucía», con el identificador corto de la persona cuando dos comparten nombre. Una acción lo guarda como nombre local. Ningún tipo de nombre autentica a nadie: el número de seguridad sigue siendo la única comprobación, y un nombre nunca lo cambia.

**5. Solo un dispositivo que tenga la raíz puede cambiar el nombre.** Es decir, el de administración o uno recuperado. Los dispositivos vinculados reenvían el último perfil firmado que recibieron y remiten al de administración para cambiarlo. El coste es que una persona que solo tenga dispositivos vinculados no puede cambiarse el nombre. A cambio, un dispositivo vinculado perdido o robado no puede renombrar la identidad.

**6. El nombre se valida donde se elige y donde se recibe:**
- como mucho 64 puntos de código Unicode, normalizados a NFC;
- sin caracteres de control;
- sin marcas de dirección bidireccional y sin caracteres de anchura cero.

Cualquier otro nombre se rechaza entero.

## Qué sabe cada parte

| Parte | Sabe | No sabe |
|---|---|---|
| El realm | Que tras un cambio de nombre se enviaron eventos de tamaño corriente, como con cualquier mensaje | El nombre, si existe uno, o que un evento es un perfil |
| Los miembros de una conversación | El nombre que eligió la persona, y sus cambios | Los nombres locales que otros le pusieron |
| Quien no comparte ninguna conversación con la persona | Nada | El nombre |

Un nombre llega a todas las personas de todas las conversaciones en las que está quien lo elige, incluidos grupos con gente que no conoce. Esa es la razón de ser de la función y su principal coste de privacidad. La pantalla de ajustes lo dice donde se pone el nombre.

## Alternativas

| Alternativa | Motivo para no adoptarla |
|---|---|
| Solo nombres locales, con los avisos nuevos | Conserva todas las propiedades de hoy, pero cada persona nombra a todas las demás, en cada dispositivo |
| Un nombre dentro de la ruta de contacto | Los clientes anteriores exigen nueve campos y se atascarían; las rutas se pegan en otros canales, por donde el nombre se filtraría; una ruta no cambia cuando cambia el nombre |
| Una extensión del nodo hoja de MLS | La autentica la hoja, pero pertenece a un dispositivo y no a la identidad, y cambiarla exige un commit de actualización que hoy solo puede hacer la hoja activa más baja |
| Un evento `profile` sin la firma de la raíz | Cualquier dispositivo podría poner el nombre; más sencillo, pero los dispositivos podrían discrepar, y un dispositivo vinculado robado podría renombrar la identidad |
| Un perfil guardado por el realm | Da al servidor nombres que nunca debe tener ([ADR-003](ADR-003-zero-trust-server.md), invariante I-01) |

## Consecuencias

- Un tipo de evento nuevo y una tabla de nombres anunciados en el núcleo, además de una declaración firmada con su propia secuencia.
- Los clientes anteriores siguen funcionando y simplemente no muestran nombres elegidos.
- Poner un nombre genera un evento por conversación. Es una ráfaga pequeña y visible de tráfico; su momento le dice al realm que ha pasado algo, pero no qué.
- La fase 3b excluye rediseñar el protocolo ([fase 3b](../PHASE3B.md)). Este es un cambio aditivo, así que puede encajar, pero la decisión se toma aparte de la beta.

## Criterios de aceptación

1. Un cliente anterior que recibe un evento `profile` sigue funcionando, no muestra nada nuevo y no cuenta como no leído ni guarda en su historial nada nuevo.
2. Un perfil firmado por otra raíz, con una secuencia menor o igual o con un nombre fuera de las reglas se rechaza, y el nombre mostrado no cambia.
3. El nombre local siempre tiene prioridad, y un nombre anunciado nunca cambia un número de seguridad ni una verificación.
4. Ningún nombre aparece en la base de datos, los registros ni las métricas del realm, ni en las rutas, las invitaciones o los KeyPackages.
5. Un dispositivo vinculado muestra el nombre puesto en el de administración y no puede cambiarlo.
6. Quitar el nombre lo quita para todos los miembros en cuanto reciben el nuevo perfil.

## Preguntas abiertas

- Si dejar que una persona elija, por conversación o por grupo, no compartir su nombre.
- Si una persona con todos sus dispositivos vinculados debería tener una forma de cambiarse el nombre, y con qué autoridad.
- Si un perfil debería llevar más adelante una foto. Sería una decisión mayor y aparte, con sus propios límites de tamaño y almacenamiento.
