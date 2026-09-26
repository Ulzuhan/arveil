# Un realm privado mediante Cloudflare Tunnel

El túnel es una opción de despliegue; Arveil también funciona por LAN,
Tailscale o una dirección pública directa. Utiliza un nombre distinto para
la landing del proyecto y para tu realm, por ejemplo `project.example.org` y
`relay.example.org`. Los invitados usan la dirección pública WSS y una
invitación de Arveil, sin instalar Tailscale ni tener cuenta de Cloudflare.

**Los nombres reales, cuenta, identificador del túnel, destino SSH, credenciales,
bootstrap e invitaciones son datos privados de operación.** Guarda los archivos
en `.local/` o fuera del repositorio. Nunca los publiques en ejemplos, issues,
PR, logs o paquetes del cliente.

La [receta técnica](../TUNNEL.md) incluye preparación, comprobaciones, cambio
de servicio y vuelta atrás. `scripts/prepare_tunnel.py` recibe un JSON privado
y genera configuraciones para cloudflared, nginx y el relay en Podman. Exige
salidas fuera de Git o ignoradas, con permisos privados. No despliega, crea DNS
ni lee credenciales. Revisa las rutas de ejecutables y valida todo en el host.

El recorrido público es Cloudflare → túnel saliente → cloudflared → nginx
local → relay. Solo se publica `/v1/channel`; administración y métricas quedan
fuera. Todos los puertos del host se enlazan a loopback. No se abre ningún
puerto entrante del router y se mantiene Tailscale para administrar el host.
Cloudflare termina TLS y conoce IP, cabeceras y patrones de tráfico; Noise
sigue terminando en cliente y relay. Esto no es transporte anónimo.

El proxy tiene dos entradas separadas. La del conector toma la IP de
`CF-Connecting-IP` y **sustituye** `X-Forwarded-For`, en vez de añadir una IP a
una cadena potencialmente falsa. La de Tailscale no confía en ninguna de esas
cabeceras. No actives `-trust-forwarded-for` directamente detrás de cloudflared:
Cloudflare puede conservar una primera IP aportada por el cliente y el relay
usa justamente esa primera entrada para sus límites.

Conserva el volumen y las claves del realm existente, haz una copia antes del
cambio y prepara la vuelta atrás. La receta mueve el backend a otro puerto
loopback y deja el puerto anterior al proxy para mantener Tailscale Serve.
No reinicies toda la configuración de Serve ni alteres otros servicios.
Las conexiones existentes pueden necesitar reconectar durante el cambio.

Antes de invitar a gente, verifica desde fuera de la tailnet: alta con
invitación desechable, intercambio de mensajes, adjuntos, reconexión, límites
por IP y rechazo de cabeceras falsificadas. Comprueba que administración y
métricas no sean accesibles y que el bootstrap y la lista firmada anuncien el
endpoint WSS correcto. Que Cloudflare muestre «conectado» no sustituye estas
comprobaciones. Las pruebas destructivas de staging no deben ejecutarse sobre
un realm que ya tenga usuarios reales.
