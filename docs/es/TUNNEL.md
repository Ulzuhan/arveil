# Un realm privado mediante Cloudflare Tunnel

Esta es una receta de despliegue opcional. Arveil sigue siendo compatible con
LAN, Tailscale y endpoints públicos directos. Los nombres de host de quien
opera, la cuenta, el ID del túnel, el destino SSH, los tokens y el bootstrap
del realm no pertenecen al repositorio público. Guarda esos archivos en
`.local/` o fuera del repositorio, y nunca los pongas en ejemplos, issues, pull
requests, logs ni paquetes del cliente.

Usa nombres de host distintos para la landing del proyecto y para un realm
personal, por ejemplo `project.example.org` y `relay.example.org`. Un subdominio
de un solo nivel entra además en la cobertura comodín ordinaria de Universal
SSL de Cloudflare. Tus amistades usan el endpoint público `wss://` con su
invitación normal de Arveil; no necesitan Tailscale ni una cuenta de
Cloudflare. Mantén el registro solo por invitación.

*English: [A private realm through Cloudflare Tunnel](../TUNNEL.md).*

## Tráfico y límites de confianza

```text
Android ── WSS + Noise ── Cloudflare ── outbound tunnel ── cloudflared
                                                          │ loopback:8448
                                                          ▼
                                                      nginx ── loopback:8449 ── relay
                                                          ▲
Tailscale Serve TCP ──────────────────────────────── loopback:8447
```

Cloudflare termina la conexión TLS exterior y ve la IP, el nombre de host, las
cabeceras HTTP y los patrones de tráfico. La sesión Noise autenticada de Arveil
sigue terminando en el cliente y en el relay; el cifrado de mensajes y adjuntos
se mantiene. Esto no es un transporte anónimo. Consulta la
[explicación del protocolo](../articles/noise-inside-a-cloudflare-tunnel.md).

Solo se reenvía `/v1/channel`. La administración y las métricas del relay
siguen en el puerto loopback 9090 de su contenedor, sin publicar; las métricas
del conector también se enlazan al loopback del host. No hay redirección de
puertos en el router. Los tres puertos de escucha del host se enlazan a
127.0.0.1, y el cortafuegos del host debe seguir denegando las conexiones
entrantes a los puertos de la aplicación. Solo los procesos locales de
confianza pueden acceder al proxy y al backend.

**No actives `-trust-forwarded-for` directamente detrás de cloudflared.** Con
esa opción, el relay lee la última entrada de `X-Forwarded-For`, la que añadió
el proxy de delante, así que todo camino hasta el relay debe pasar por un proxy
que la ponga; la entrada de la tailnet no lo haría y sus clientes podrían
declarar su propia dirección. Esta receta usa el módulo real-IP de nginx en una
escucha dedicada al conector, toma `CF-Connecting-IP` solo ahí y sustituye el
valor completo de `X-Forwarded-For`. Se rechazan las cabeceras de dirección
ausentes, no válidas, encadenadas o repetidas. La escucha separada de Tailscale
descarta las direcciones que declaren las peticiones entrantes y usa la del par
real; los clientes de Serve TCP conservan el límite por dirección compartido
que ya tenían. Para sus límites, el relay agrupa las direcciones IPv6 por /64.

Deja Pseudo IPv4 de Cloudflare en **Off** o **Add Header**, no en **Overwrite
Headers**, y mantén desactivado **Remove visitor IP headers**. No asocies a este
nombre de host Workers que reescriban la dirección del cliente. La cuenta, el
conector y el proxy local son de confianza para atribuir la IP; no obtienen las
claves de la sesión Noise.

## Preparar en privado

Requisitos: el DNS del dominio en Cloudflare, un túnel con nombre **gestionado
localmente**, cloudflared, nginx 1.23 o posterior con `http_realip_module` y el
[despliegue con Podman](../PODMAN.md) sin root que ya tienes. Instala versiones
mantenidas desde sus fuentes oficiales. Restringe la administración de la
cuenta con MFA y conserva Tailscale para SSH.

Las versiones anteriores de nginx solo leen la primera de varias líneas de
cabecera repetidas, así que no pueden rechazar una petición que lleve dos
cabeceras `CF-Connecting-IP`. Debian 12, por ejemplo, incluye nginx 1.22:
instala una versión más reciente, como los paquetes propios de nginx.org, en
lugar de relajar la comprobación. La unidad del proxy generada se niega a
arrancar con un nginx anterior y explica el motivo en su journal; si un nginx
anterior carga la configuración de todos modos, la escucha del conector
rechaza todas las peticiones.

Autentícate y crea el túnel con nombre desde la máquina del mantenedor siguiendo
la [guía de Cloudflare para túneles gestionados localmente](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/).
Pon en el servidor solo el JSON de credenciales de ese túnel, con modo 0600, en
un directorio 0700. No copies al servidor el `cert.pem` de la cuenta, que tiene
un alcance mayor. El generador que se describe abajo no lee ni copia ninguna de
las dos credenciales. Antes de cambiar las escuchas, haz una copia de seguridad
del realm y conserva su volumen con nombre y sus claves.

Crea `.local/tunnel/operator.json` con modo 0600 (todos los valores de abajo son
ejemplos):

```json
{
  "hostname": "relay.example.org",
  "tunnel_id": "00000000-0000-4000-8000-000000000001",
  "credentials_file": "/srv/arveil/private/tunnel.json",
  "revision": "0123456789012345678901234567890123456789",
  "name": "arveil-staging",
  "tailnet_address": "REPLACE_WITH_YOUR_TAILSCALE_IPV4",
  "tailnet_port": 8447,
  "connector_port": 8448,
  "backend_port": 8449,
  "metrics_port": 20241
}
```

Sustituye el marcador de la dirección por tu IPv4 privada de Tailscale. Usa el
nombre de contenedor y de volumen **existente** y la revisión de un commit cuya
imagen ya esté compilada. Omite `tailnet_address` solo en un despliegue nuevo
exclusivamente público. Los puertos deben ser distintos y estar libres, salvo
el puerto de la tailnet que se migra. Genera la configuración:

```sh
python3 scripts/prepare_tunnel.py \
  --config .local/tunnel/operator.json --output .local/tunnel/rendered
```

El generador rechaza ubicaciones dentro de Git que no estén ignoradas y
directorios de salida que ya existan. Crea, con permisos privados,
`cloudflared.yml`, `nginx.conf`, la Quadlet del relay y dos unidades systemd de
usuario. No usa SSH, no cambia el DNS, no arranca nada y no crea credenciales.
Mantén en privado sus archivos, logs e inventarios. Revisa las rutas de los
ejecutables de los servicios (`/usr/sbin/nginx`, que aparece dos veces en la
unidad del proxy, y `/usr/local/bin/cloudflared`) para la distribución de
destino. Las unidades de referencia necesitan un gestor de usuario de systemd
que admita sus directivas de aislamiento; compruébalas en el servidor real
antes del cambio.

## Validar y cambiar

1. Guarda en privado la Quadlet existente y una copia de seguridad del realm.
   Comprueba que existe la imagen fijada del relay y que su `-version` coincide.
   Conserva la imagen y los datos antiguos.
2. Copia las configuraciones a `~/.local/share/arveil/tunnel/` (directorio 0700,
   archivos 0600) y las unidades de servicio a `~/.config/systemd/user/`.
   Comprueba la configuración; `nginx -V` debe indicar la versión 1.23 o
   posterior e incluir `--with-http_realip_module`:

   ```sh
   nginx -V
   nginx -t -e stderr -p "$HOME/.local/share/arveil/tunnel/" -c nginx.conf
   cloudflared --config "$HOME/.local/share/arveil/tunnel/cloudflared.yml" tunnel ingress validate
   systemd-analyze --user verify "$HOME/.config/systemd/user/arveil-proxy.service" \
     "$HOME/.config/systemd/user/arveil-tunnel.service"
   ```

3. Sustituye solo la Quadlet del realm elegido y conserva su volumen de datos
   con nombre. Recarga systemd de usuario y reinicia ese realm; su backend pasa
   al loopback 8449 y libera el antiguo puerto 8447. Arranca el proxy y el
   conector. Cuenta con un breve periodo de reconexión. No restablezcas la
   configuración de Tailscale Serve ni cambies otras rutas.
4. Valida en local antes de crear la ruta DNS pública. Comprueba el comando
   interno de salud del relay y `ss -lnt`: todos los puertos del host anteriores
   deben estar en loopback. Confirma que nginx rechaza `/metrics`, `/healthz` y
   cualquier ruta salvo la del canal; una petición al canal sin upgrade a
   WebSocket, o con la dirección de Cloudflare ausente, no válida o repetida,
   debe fallar.
   Verifica que Tailscale sigue funcionando y que no puede suplantar otra
   dirección con ninguna de las dos cabeceras de reenvío.
5. Crea hacia este túnel con nombre una ruta DNS **solo para el nombre de host
   del relay elegido**. No cambies el nombre de host de la landing. Activa
   WebSockets, desactiva la caché (bypass) en este nombre de host y evita en el
   canal los inicios de sesión de Access pensados solo para navegador, los
   desafíos JavaScript y los CAPTCHA. La autenticación Noise y por invitación
   de Arveil sigue siendo obligatoria. Si Browser Integrity Check bloquea a los
   clientes nativos, aplica la
   [excepción acotada y su procedimiento de vuelta atrás](#browser-integrity-check-excepcion-y-vuelta-atras)
   que se describen abajo. No debilites las protecciones de servicios no
   relacionados.
6. Desde fuera de la tailnet, completa un alta real de Arveil con una invitación
   desechable de un solo uso e intercambia mensajes. Prueba la reconexión tras
   reiniciar el conector, adjuntos dentro de los límites del relay y los límites
   con un `X-Forwarded-For` entrante falsificado a propósito. Comprueba que la
   lista firmada de endpoints y el bootstrap nuevo usan el endpoint WSS público.
   Los miembros existentes deben recibirlo mientras su endpoint anterior siga
   siendo accesible.
7. Habilita el arranque automático solo de las unidades de usuario del proxy y
   del conector, confirma que lingering está activado y comprueba un reinicio
   de la máquina o de los servicios. Limita la retención de los journals, nunca
   actives registros de peticiones que contengan identificadores y no vuelques
   invitaciones en tickets.

No des el despliegue por listo solo porque el túnel aparezca conectado: el
handshake Noise externo, la atribución de direcciones y la actualización del
cliente que conserva el perfil son comprobaciones separadas. Los reinicios de
Cloudflare o del proxy pueden interrumpir los WebSockets; los clientes deben
reconectar. Nunca ejecutes pruebas destructivas de staging sobre un realm que ya
tenga usuarios reales.

Para deshacer el cambio, detén el conector y el proxy nuevos **antes** de
restaurar la Quadlet antigua, para que el puerto 8447 vuelva a quedar libre.
Restaura sus opciones originales y reinicia; deja intacto el mismo volumen si
solo cambió la red. Elimina solo la ruta DNS nueva si ya no la quieres. Si
también cambias el código del relay o el formato de la base de datos, usa el
[procedimiento de copia y vuelta atrás](../PODMAN.md#updates-backups-and-rollback)
en lugar de suponer que un binario anterior puede leer la base de datos actual.

## Actualizar el relay detrás del túnel

Cuando un realm funciona detrás del túnel, `scripts/podman.py deploy` ya no
sustituye su unidad: la unidad estándar publicaría el relay en el puerto que
usa nginx, quitaría `-trust-forwarded-for` y olvidaría el endpoint público, y
la siguiente actualización dejaría el relay caído. Se detiene antes de compilar
nada y lo explica. En su lugar, actualízalo así:

1. Compila y comprueba la imagen nueva sin tocar el servicio en marcha. Si el
   realm está en marcha, también guarda una copia previa a la actualización,
   como hace un despliegue normal:

   ```sh
   python3 scripts/podman.py deploy --host <ssh-alias> \
     --address <tailscale-ipv4> --revision <commit> --image-only
   ```

2. Pon ese commit en `revision` de `.local/tunnel/operator.json` y genera la
   configuración en un directorio nuevo, porque el generador nunca sobrescribe
   uno existente:

   ```sh
   python3 scripts/prepare_tunnel.py \
     --config .local/tunnel/operator.json --output .local/tunnel/rendered-<commit>
   ```

3. Compara la Quadlet nueva del relay con la instalada. Solo deben cambiar las
   líneas de la imagen y la revisión; si cambia algo más, detente y revísalo.
   Conserva la instalada como `.container.previous`, instala la nueva con modo
   0600, ejecuta `systemctl --user daemon-reload` y reinicia solo el servicio
   del realm. El proxy y el conector siguen en marcha.
4. Comprueba el comando interno de salud del relay y que `-version` informe del
   commit nuevo, y después repite las comprobaciones externas del paso 6 de
   [Validar y cambiar](#validar-y-cambiar).

Para volver atrás, restaura `.container.previous` y reinicia el servicio del
realm. Si el relay nuevo migró su base de datos, sigue además el
[procedimiento de copia y vuelta atrás](../PODMAN.md#updates-backups-and-rollback).

## Browser Integrity Check: excepción y vuelta atrás {#browser-integrity-check-excepcion-y-vuelta-atras}

[Browser Integrity Check (BIC)](https://developers.cloudflare.com/waf/tools/browser-integrity-check/)
de Cloudflare usa las cabeceras HTTP, incluido el User-Agent, para rechazar
parte del tráfico automatizado. Los clientes nativos y las peticiones del
actualizador sin User-Agent pueden ser falsos positivos legítimos. Un HTTP 403
con el error 1010 de Cloudflare es una pista para el diagnóstico; no atribuyas
cualquier 403 a BIC ni desactives protecciones no relacionadas para arreglarlo.

**Mantén BIC activado salvo que un cliente real falle por su culpa.** Un script
de diagnóstico no sustituye a los clientes distribuidos: por ejemplo, `urllib`
de Python envía por defecto su propio User-Agent. Que lo rechacen no demuestra
que se vaya a rechazar un cliente sin esa cabecera o con otro valor. Comprueba
el ajuste efectivo de la regla y después prueba la conexión nativa
WebSocket/Noise y el transporte HTTP real del actualizador Android. Un 404 de
un manifiesto inexistente puede demostrar que la petición atravesó el edge de
Cloudflare, pero no valida la publicación del manifiesto, la verificación de la
firma ni la instalación.

Si el fallo depende del User-Agent, compara peticiones idénticas en todo lo
demás usando un identificador de aplicación honesto y compartido. Evita
identificadores del dispositivo, datos del perfil y hacerte pasar por un
navegador. Un User-Agent es un metadato público que se puede falsificar, no una
autenticación, y su mera presencia no garantiza que se acepte la petición. No
cambies clientes que funcionan solo para que pase un script de diagnóstico.

Si después de estas comprobaciones BIC sigue impidiendo que funcionen los
clientes nativos soportados, documenta la evidencia antes de crear una
**Configuration Rule** en la zona elegida, desde **Rules → Overview**, que
establezca solo **Browser Integrity Check = Off**. Haz que coincida exactamente
con el canal del relay y, si se aloja a través de Cloudflare, con el manifiesto
de distribución exacto. Valores solo de ejemplo:

```text
(http.request.method eq "GET" and (
  (http.host eq "relay.example.org" and http.request.uri.path eq "/v1/channel")
  or
  (http.host eq "project.example.org" and http.request.uri.path eq "/updates/clients-beta.json")
))
```

Omite la condición del manifiesto si lo alojas en otro sitio. No uses una
excepción para toda la zona ni para todo el nombre de host. Las demás rutas y
métodos conservan sus ajustes actuales. Revisa el orden de las reglas: cuando
varias Configuration Rules fijan la misma opción, gana la última que coincide.
Esto solo sustituye el ajuste de BIC; no es una omisión general del WAF.

El coste es que algunas peticiones automatizadas que BIC rechazaba antes pueden
llegar a estos endpoints, lo que aumenta la exposición a intentos de conexión y
a la carga. TLS, Noise, la exigencia de invitación, los límites del relay y la
verificación de firmas de las actualizaciones no cambian. Esta regla no
desactiva otras reglas de seguridad de Cloudflare que tengas configuradas ni la
protección DDoS. BIC en sí es una heurística basada en cabeceras, no una
autenticación.

Lleva un **registro privado de cambios**, fuera de Git o en un directorio
ignorado, con la fecha, el motivo, la aprobación de quien opera, la expresión
exacta, el nombre, el ID y el enlace del panel de la regla, el valor de BIC, el
orden de la regla y las observaciones de antes y después. Nunca copies ese
registro ni sus nombres de host reales en esta guía pública ni en un PR.

Después de desplegarla, verifica en Cloudflare la expresión guardada y el
ajuste activo. Prueba una conexión Noise pública real y una comprobación de
actualizaciones sin hacerte pasar por un navegador. El proxy debe seguir
rechazando un GET normal al canal sin upgrade a WebSocket. Un manifiesto
publicado debe devolver exactamente el JSON firmado; un 404 de un manifiesto
que todavía no existe solo verifica que BIC ya no lo bloquea. Comprueba tanto
las rutas excluidas como las peticiones permitidas, y anota los resultados.

### Volver a activar la comprobación

1. Abre la regla con el enlace del panel que anotaste en el registro privado, o
   búscala en **Rules → Overview → Configuration Rules** de la zona correcta.
2. Conserva la misma expresión. Cambia **Browser Integrity Check a On** y
   despliega o guarda el cambio. Deja la regla activa y comprueba que ninguna
   regla posterior que coincida lo sobrescribe; usa el simulador de reglas o
   Trace de Cloudflare cuando haga falta.
3. Prueba la conexión pública de la app y la comprobación de actualizaciones.
   BIC puede volver a devolver 403/1010 a peticiones nativas legítimas. El
   acceso por Tailscale y los perfiles guardados no se ven afectados. Anota la
   hora, el resultado y cualquier ID de petición de Cloudflare en el registro
   privado de cambios.
4. Para recuperar la compatibilidad con los clientes nativos, vuelve a poner
   BIC en **Off** en esa misma regla acotada, despliégala y repite esas
   comprobaciones. Este cambio de ajuste no requiere recompilar el APK, rotar
   claves ni restaurar datos del relay.

Desactivar o borrar la excepción solo restaura los ajustes heredados; **no**
garantiza que BIC quede en On. Revisa el ajuste de la zona y las demás reglas
que coincidan antes de elegir esa alternativa. Volver a activar BIC tampoco es
una forma fiable de retirar el servicio público: para eso, detén el conector
dedicado o elimina su ruta DNS específica siguiendo el plan privado de vuelta
atrás del despliegue.

Referencias: [cabeceras HTTP de Cloudflare](https://developers.cloudflare.com/fundamentals/reference/http-headers/),
[módulo real-IP de nginx](https://nginx.org/en/docs/http/ngx_http_realip_module.html),
[proxy de WebSocket en nginx](https://nginx.org/en/docs/http/websocket.html).
