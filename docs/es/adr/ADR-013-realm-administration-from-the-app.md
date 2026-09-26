# ADR-013 — Administrar el realm desde la app

- **Estado:** propuesta. Nada de lo que describe está implementado.
- **Fecha:** 2026-09-27.
- **Alcance:** quién administra un realm, cómo invita y retira a personas desde la app y cómo se recupera la administración si se pierden dispositivos. Los enlaces y códigos QR de invitación son la [ADR-012](ADR-012-qr-codes-and-links.md).

[English version](../../adr/ADR-013-realm-administration-from-the-app.md).

## Contexto

Hoy un realm solo se administra desde su servidor.
- **Invitaciones.** `arveil-relay invite` abre directamente la base de datos del relay, así que crear una exige una shell en el servidor: SSH, `podman exec` o `docker compose exec`.
- **No hay nada más.** No existe ninguna orden para listar o revocar invitaciones, listar miembros ni retirar a nadie.
- **Los roles se guardan, pero no se usan.** El `-role` de la invitación se copia en `realm_memberships.role`, y nada lo lee.
- **No hay tramas de administración.** El relay no tiene ninguna. Su listener de administración solo sirve `/healthz` y `/metrics`.
- **Una credencial diseñada que nunca se construyó.** El diseño preveía una «credencial administrativa independiente» ([Protocolo §3](../PROTOCOL.md#3-bootstrap-del-realm-e-identidad), [arquitectura](../ARCHITECTURE.md)), y que las tramas de administración solo se aceptarían en endpoints de tipo `admin`. No existe ninguna de las dos cosas.
- **Un choque de nombres.** La app llama «dispositivo de administración» al que guarda la raíz personal, que no tiene nada que ver con administrar el realm.

En un realm familiar esto significa que una persona con una terminal da de alta a todas las demás, con una sesión SSH por invitación.

Qué hacen los servicios autoalojados: el propietario se establece una vez al instalar y administra desde la app. El servidor conserva una orden para emergencias. Ejemplos son Matrix/Synapse (API de administración más `register_new_matrix_user`), Home Assistant, Jellyfin y Gitea (`gitea admin`).

## Decisión (propuesta)

### 1. Los roles pertenecen a las identidades

`realm_memberships.role` pasa a ser `owner`, `admin` o `member`.
- **La autoridad pertenece a la identidad, no a un dispositivo.** Cualquier credencial de dispositivo activa de esa identidad se autentica mediante su sesión Noise. Revocar un dispositivo acaba con el poder de ese dispositivo, y perder un dispositivo no se lleva el rol.
- **Qué puede hacer cada rol:**
  - `owner` lo hace todo y es el único rol que cambia roles;
  - `admin` invita y retira miembros;
  - `member` no hace ninguna de las dos cosas, salvo que el realm permita invitar a los miembros (véanse las preguntas abiertas).

### 2. El primer propietario se reclama con una invitación, no conectándose primero

«Quien conecte primero es el propietario» es una carrera siempre que el relay sea accesible antes de que su operador se una. En su lugar:
- `arveil-relay invite -role owner` crea la invitación de propietario en el servidor e imprime el enlace `join` y el QR de la [ADR-012](ADR-012-qr-codes-and-links.md).
- Al arrancar, un relay sin propietario escribe en el log una indicación para ejecutar esa orden. No escribe el secreto.
- Canjear la invitación convierte a esa identidad en la propietaria.

Es el único paso que necesita el servidor, como hoy lo necesita la primera invitación.

### 3. Tramas de administración

Estas tramas solo se aceptan en sesiones de miembro cuya identidad tiene el rol necesario:

| Trama | Rol | Efecto |
|---|---|---|
| `invite_create {role, ttl, uses}` | admin, owner | Devuelve un token. El cliente construye el enlace `join` a partir del realm que ya conoce. Límites: `ttl` ≤ 7 días, `uses` ≤ 10, `role` ≤ el de quien la pide |
| `invite_list` | admin, owner | Devuelve, para cada invitación: un prefijo corto de su hash, rol, caducidad, usos restantes y las identidades que la canjearon |
| `invite_revoke {prefix}` | admin, owner | Borra una invitación sin canjear |
| `member_list` | admin, owner | Devuelve identificadores de identidad, roles, estado y fecha de alta. El relay ya tiene todos estos datos |
| `member_remove {identity}` | admin (solo miembros), owner | Marca la pertenencia como retirada, cierra sus sesiones y rechaza sus dispositivos |
| `role_set {identity, role}` | owner | Cambia un rol; el último propietario no se puede degradar |

**Acciones que necesitan la raíz.** `member_remove` y `role_set` deben llevar además una declaración firmada por la raíz de quien las pide: un `SignedObject` con el contexto `arveil/realm-admin/v1` y el cuerpo `{realm_id, action, target, expires, nonce}`.
- El relay la comprueba contra la raíz guardada para esa pertenencia.
- Así, un dispositivo vinculado robado puede invitar, que es algo acotado y revocable, pero no retirar a nadie ni conceder roles.
- El cliente construye la declaración él mismo, con su propio contexto. No es una firma sobre bytes elegidos por el servidor, cosa que el [Protocolo §3](../PROTOCOL.md#3-bootstrap-del-realm-e-identidad) prohíbe.

**Limitar los endpoints.** Una opción `-admin-frames any|admin-endpoints` limita estas tramas a los endpoints de tipo `admin`, por ejemplo una tailnet. Por defecto es `any`, para que quien administra un realm familiar pueda invitar desde cualquier sitio. Sustituye la regla incondicional del [Protocolo §3](../PROTOCOL.md#3-bootstrap-del-realm-e-identidad).

**Límites y registro.**
- Quien administra puede crear como mucho 20 invitaciones al día. Puede haber como mucho 50 invitaciones abiertas a la vez.
- El relay registra cada acción de administración con el identificador truncado de quien la hizo, la acción y la hora. Nunca registra nombres. `admin_log` devuelve el registro, y la app lo muestra.

### 4. Lo que la administración no puede hacer

Esta decisión cambia quién decide la admisión, no lo que significa ([ADR-003](ADR-003-zero-trust-server.md), [ADR-005](ADR-005-cryptographic-identity.md)). Un propietario o un administrador no puede:
- leer mensajes;
- firmar dispositivos de otras identidades;
- fabricar ni sustituir claves;
- ver nombres ni contactos.

Retirar a un miembro hace que este relay deje de darle servicio. No lo saca de los grupos MLS: eso lo hacen los demás miembros de cada grupo.

### 5. Recuperación, por orden

1. **Otro dispositivo de la misma identidad** conserva el rol.
2. **El kit de identidad** restaura la identidad, y con ella el rol.
3. **Un segundo propietario.** La app sugiere a quien es propietario que nombre a otro, por ejemplo alguien de la familia, para que el realm nunca dependa de una sola persona.
4. **El servidor, por SSH**, para emergencias:
   - `arveil-relay invite -role owner` crea una invitación de propietario nueva;
   - `arveil-relay member list`, `member role` y `member remove` actúan directamente sobre la base de datos, por ejemplo para degradar a una identidad cuyos dispositivos fueron robados.

### 6. Nombres en la app

El dispositivo que guarda la raíz personal pasa a llamarse **dispositivo principal** en la interfaz. «Administrador» y «administración» quedan para el realm.

## Qué aprende cada parte

| Parte | Aprende | No aprende |
|---|---|---|
| El realm | Los roles, las acciones de administración y quién las hizo. Ya conocía cada pertenencia | Nombres, contactos ni contenidos de mensajes |
| Propietarios y administradores | La lista de miembros: identificadores, roles y fechas, que el relay ya tiene | Nombres, salvo que esos miembros sean también sus contactos; mensajes |
| Miembros | Nada nuevo | Quién administra, salvo que se lo digan |

## Alternativas

| Alternativa | Motivo para no adoptarla |
|---|---|
| Solo SSH, como hoy | Funciona, pero una persona con una terminal da de alta a todas |
| La primera identidad que conecta es la propietaria | Una carrera siempre que el relay sea accesible antes de que su operador se una |
| Una contraseña o credencial administrativa aparte | Otro secreto que perder y proteger; una contraseña robada actúa sin ningún dispositivo |
| Un panel web de administración en el relay | Una superficie de ataque nueva en el componente que debe guardar menos |
| Firmar con la raíz todas las acciones de administración | Las invitaciones, la acción habitual, necesitarían el dispositivo principal cada vez |

## Consecuencias

- **Relay:** tramas nuevas, una comprobación de rol, una tabla de registro y las subórdenes `member`. Las invitaciones pasan a tener creador.
- **Cliente:** una sección de Administración, visible solo para propietarios y administradores, con invitaciones, miembros y el registro; declaraciones firmadas por la raíz; el cambio de nombre del dispositivo principal.
- **Texto del protocolo:** el [Protocolo §3](../PROTOCOL.md#3-bootstrap-del-realm-e-identidad) y la [arquitectura](../ARCHITECTURE.md) se actualizan para describir roles sobre identidades en lugar de una credencial administrativa aparte.
- **Redundancia del realm:** una réplica debe replicar los roles y el registro, igual que ya debe replicar el consumo de invitaciones ([ADR-007](ADR-007-optional-realm-redundancy.md)).

## Criterios de aceptación

1. **Invitaciones.** Un propietario crea una invitación en la app y una persona nueva se une con su enlace. A un miembro sin el rol se le rechaza `invite_create`.
2. **Revocación.** Una invitación revocada no se puede canjear, y la lista muestra el estado de cada invitación.
3. **Acciones que necesitan la raíz.** `member_remove` y `role_set` sin una declaración de raíz válida se rechazan, también cuando llegan de un dispositivo vinculado de un propietario.
4. **Recuperación.** Perdidos todos los dispositivos y el kit, una invitación de propietario nueva creada en el servidor funciona, y el propietario anterior se puede degradar desde el servidor.
5. **Privacidad.** Ningún nombre aparece en la base de datos, los logs ni el registro del relay; los identificadores van truncados.
6. **Endpoints limitados.** Con `-admin-frames admin-endpoints`, las tramas de administración se rechazan en los demás endpoints.

## Preguntas abiertas

- Si los miembros pueden invitar, y si sus invitaciones necesitan la aprobación de un administrador.
- Si retirar a alguien debería pedir también a sus grupos que lo saquen, o dejarlo en manos de sus miembros.
- Cuánto tiempo se conserva el registro.
