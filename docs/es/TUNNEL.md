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
con esa opción el relay lee la última entrada de `X-Forwarded-For`, la que añadió
el proxy de delante, así que todo camino hasta el relay debe pasar por un proxy
que la ponga; la entrada de la tailnet no lo haría y sus clientes podrían
declarar su propia dirección. Para sus límites, el relay agrupa las direcciones
IPv6 por /64.

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

## Actualizar el relay detrás del túnel

Cuando un realm funciona detrás del túnel, `scripts/podman.py deploy` ya no
sustituye su unidad: la unidad estándar publicaría el relay en el puerto que
usa nginx, quitaría `-trust-forwarded-for` y olvidaría el endpoint público, y
la siguiente actualización dejaría el relay caído. Se detiene antes de
compilar nada y lo explica. Actualízalo así:

1. Compila y comprueba la imagen nueva sin tocar el servicio en marcha. Si el
   realm está en marcha, también guarda una copia previa, como un despliegue
   normal:

   ```sh
   python3 scripts/podman.py deploy --host <alias-ssh> \
     --address <ipv4-de-tailscale> --revision <commit> --image-only
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
4. Comprueba el healthcheck interno del relay y que `-version` informe del
   commit nuevo, y repite las comprobaciones externas de la sección anterior.

Para volver atrás, restaura `.container.previous` y reinicia el servicio del
realm. Si el relay nuevo migró su base de datos, sigue además el
[procedimiento de copia y vuelta atrás](../PODMAN.md#updates-backups-and-rollback).

## Browser Integrity Check: excepción y vuelta atrás {#browser-integrity-check-excepcion-y-vuelta-atras}

[Browser Integrity Check (BIC)](https://developers.cloudflare.com/waf/tools/browser-integrity-check/)
filtra peticiones por sus cabeceras HTTP, incluido el User-Agent. Puede bloquear
clientes nativos legítimos y la consulta de actualizaciones, que no envía ese
identificador. Un HTTP 403 con error Cloudflare 1010 es una pista concreta;
no atribuyas cualquier 403 a BIC ni desactives otras protecciones por probar.

**Mantén BIC activado salvo que bloquee a un cliente real.** Un script de
diagnóstico no sustituye a los clientes distribuidos: por ejemplo, `urllib`
de Python ya envía su propio User-Agent. Su rechazo no demuestra que falle un
cliente sin esa cabecera o con otro valor. Comprueba el ajuste efectivo y prueba
la conexión nativa WebSocket/Noise y el transporte HTTP real del actualizador
Android. Un 404 de un feed inexistente puede confirmar que la petición supera
el filtro, pero no valida la publicación del manifiesto, su firma ni la instalación.

Si el fallo depende del User-Agent, compara peticiones idénticas cambiando solo
esa cabecera por un identificador propio y común de la aplicación. Evita datos
del dispositivo o del perfil y hacer pasar el cliente por un navegador. El
User-Agent es metadato público que cualquiera puede copiar, no autenticación;
añadirlo no garantiza superar BIC. No cambies clientes que ya funcionan solo
para que pase un script de diagnóstico.

Si BIC sigue impidiendo el uso de los clientes soportados después de estas
comprobaciones, documenta la evidencia antes de crear una **Configuration Rule** en la zona correspondiente,
desde **Rules → Overview**, con **Browser Integrity Check = Off**. El filtro debe
limitarse al método GET y a las rutas exactas del canal y del feed, si este último
también pasa por Cloudflare. Ejemplo genérico:

```text
(http.request.method eq "GET" and (
  (http.host eq "relay.example.org" and http.request.uri.path eq "/v1/channel")
  or
  (http.host eq "project.example.org" and http.request.uri.path eq "/updates/clients-beta.json")
))
```

Omite la segunda condición si alojas el feed en otro sitio. Evita excepciones
para toda la zona o todo el subdominio. Revisa el orden: si varias reglas cambian
la misma opción, prevalece la última que coincida. Esta regla solo ajusta BIC;
no omite todo el WAF.

Se pierde ese filtro para las peticiones seleccionadas: algunos bots podrán
llegar al servicio y aumentar los intentos de conexión o la carga. Se mantienen
TLS, Noise, invitaciones, límites del relay, verificación de las actualizaciones
y las demás protecciones de Cloudflare configuradas. BIC no autentica usuarios.

Guarda **en un registro privado**, fuera de Git o en un directorio ignorado:
fecha, motivo, autorización, filtro exacto, nombre/ID/enlace de la regla, valor
de BIC, posición y resultados antes/después. Los dominios y datos reales de ese
registro no pertenecen a esta guía ni a un PR público.

Después de aplicarla, comprueba el filtro guardado y la regla activa. Verifica
una conexión Noise pública y la consulta de actualizaciones con los clientes
reales, sin fingir ser un navegador. Un GET al canal sin negociación WebSocket
debe seguir siendo rechazado por el proxy. El feed publicado debe devolver el
JSON firmado exacto; un 404 de un feed todavía inexistente solo confirma que BIC
ya no lo bloquea. Comprueba también peticiones excluidas por el filtro.

### Cómo volver a activarlo

1. Abre el enlace de la regla guardado en el registro privado, o localízala en
   **Rules → Overview → Configuration Rules** de la zona correcta.
2. Conserva el filtro y cambia **Browser Integrity Check a On**. Guarda/despliega
   y deja la regla activa. Comprueba que ninguna regla posterior lo sobrescriba;
   utiliza el simulador/Trace de Cloudflare si hace falta.
3. Prueba la conexión pública y las actualizaciones: podrían reaparecer errores
   403/1010 en peticiones legítimas. Tailscale y los perfiles guardados no cambian.
   Anota fecha, resultado y, si hay error, el identificador de petición Cloudflare
   en el registro privado.
4. Para recuperar la compatibilidad, vuelve a **Off** en esa misma regla, guarda
   y repite las comprobaciones. No requiere recompilar el APK, cambiar claves ni
   restaurar datos del relay.

Desactivar o borrar la regla solo recupera la configuración heredada: **no
garantiza que BIC quede activado**. Antes de hacerlo, revisa el ajuste de la zona
y otras reglas que coincidan. Activar BIC tampoco garantiza cerrar el acceso
público; para retirarlo, sigue el plan privado para detener el conector dedicado
o eliminar únicamente su registro DNS.
