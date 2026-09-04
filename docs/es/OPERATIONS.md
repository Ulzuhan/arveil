# Poner en marcha un realm

Esta es la página de quien opera: cómo instalar el relay, ponerlo donde tu familia lo alcance, vigilarlo, respaldarlo y recuperarlo. Da por hecho una sola máquina en casa. Varios relays son el [ADR-007](adr/ADR-007-optional-realm-redundancy.md) y quedan fuera de V1.

Lo que el realm guarda y lo que no es la razón de que todo esto sea corto: sin texto plano, sin identificadores de grupo, sin tabla de conversaciones. Aun así, lo que guarda merece protección, porque basta para suplantar al realm: la clave de firma y la clave Noise bajo `server-secrets/`.

## Instalación

**Contenedor.** La imagen lleva el binario y nada más, ni siquiera una shell.

```
docker build -f relay/Dockerfile -t arveil-relay .
docker compose -f relay/compose.yaml up -d
```

**systemd.** Copia [`relay/packaging/arveil-relay.service`](https://github.com/Ulzuhan/arveil/blob/main/relay/packaging/arveil-relay.service), que corre con su propio usuario, con una sección de servicio endurecida y sus datos en `/var/lib/arveil`.

**A mano.** `arveil-relay -data-dir ./data -listen 127.0.0.1:8447`. La primera línea que imprime es la cadena de bootstrap; es lo que un dispositivo necesita para encontrar y autenticar el realm.

En cualquiera de los tres casos, lo primero tras arrancar es una invitación por persona:

```
arveil-relay invite -data-dir /var/lib/arveil
```

## Cómo llega la gente

El canal es independiente del portador ([ADR-008](adr/ADR-008-carrier-independent-transport.md)): el handshake Noise autentica el realm y cifra todo lo que va dentro, así que lo que lo transporte no puede leerlo. Por eso aquí es aceptable un túnel que termina TLS, y en otro sitio no lo sería.

| Camino | Qué ejecutas | Qué cuesta |
|---|---|---|
| LAN | `-listen 0.0.0.0:8447 -advertise lan=ws://<host>:8447/v1/channel` | Nada sale de casa, y nada funciona fuera de casa |
| Tailscale | Lo mismo, atado a la dirección del tailnet y anunciado como `tailnet=` | El coordinador de tu tailnet sabe quién conecta con qué, y cuándo |
| Túnel de Cloudflare | `cloudflared tunnel run` apuntando a `http://127.0.0.1:8447`, anunciado como `public=wss://realm.example.org/v1/channel` | Cloudflare ve metadatos de conexión y termina TLS; ve tramas opacas, nunca contenido |
| TLS en el relay | `-tls-cert cert.pem -tls-key key.pem`, anunciado como `wss://` | La renovación del certificado es tuya, y el puerto queda expuesto directamente |

Anuncia varios y los clientes los prueban en orden, saltándose los que no contestan:

```
arveil-relay -advertise "lan=ws://192.168.1.10:8447/v1/channel,public=wss://realm.example.org/v1/channel"
```

Detrás de un proxy todas las conexiones parecen venir del proxy, así que los límites por dirección dejan de separar a nadie. Activa `-trust-forwarded-for` **solo** si ese proxy es tuyo y sobrescribe `X-Forwarded-For`; si no, un cliente elige su propia dirección poniendo la cabecera él mismo.

## Vigilancia

`-admin-listen 127.0.0.1:9090` sirve `/healthz` y `/metrics`. Mantenlo fuera del túnel: nada de fuera lo necesita, y es el único endpoint que responde sin handshake.

- `/healthz` devuelve 200 cuando la base de datos responde, y 503 si no. `arveil-relay healthcheck` se lo pregunta, y es lo que ejecuta el health check del contenedor.
- `/metrics` es texto de Prometheus: conexiones, tramas, sobres guardados y barridos, blobs barridos, emparejamientos y avisos de notificación. Solo contadores, sin etiquetas, así que raspar ese endpoint no permite reconstruir quién habla con quién.

Los logs son deliberadamente escuetos. Un rechazo dice que saltó un límite, no qué dirección lo provocó, y las altas se registran con identificadores truncados.

## Límites

Las cuotas que importan para el almacenamiento son por mailbox y por identidad, y solo aplican cuando alguien ya es miembro. La cita de emparejamiento es lo único que puede tocar un desconocido, así que tiene sus propios topes:

```
-max-conns 256 -max-conns-per-addr 8 -max-pairings-per-addr 4 -pairing-window 10m
```

Pon `-max-conns-per-addr` por encima del número de dispositivos de una casa, o la gente detrás de la misma dirección se rechazará entre sí.

## Copias de seguridad

La base de datos es la fuente de verdad; los blobs son adjuntos que quizá los clientes ya no tengan. Respalda ambos con el relay en marcha:

```
arveil-relay backup -data-dir /var/lib/arveil -out /backups/arveil-$(date +%F).tar.gz
```

El archivo contiene las claves privadas del realm. Cífralo y guárdalo donde el realm no llegue, para que quien se lleve la máquina no se lleve también las copias.

La restauración va a un directorio nuevo y nunca sobre uno vivo, porque mezclar dos estados haría retroceder revocaciones:

```
arveil-relay restore -in /backups/arveil-2026-09-04.tar.gz -data-dir /var/lib/arveil.new
systemctl stop arveil-relay && mv /var/lib/arveil /var/lib/arveil.old && mv /var/lib/arveil.new /var/lib/arveil && systemctl start arveil-relay
```

Restaurar una copia antigua es visible para los clientes en vez de silencioso: un dispositivo que se recupera con su kit de identidad avisa de que el realm tiene un manifiesto más viejo que el suyo (invariante I-08), y los miembros refrescan manifiestos en cada sincronización. Eso es detección, no prevención.

## Actualizaciones

Parar, sustituir el binario, arrancar. El esquema migra al abrir. Haz una copia antes y conserva el binario anterior hasta que la familia haya usado el nuevo, porque no hay camino de vuelta para la base de datos.
