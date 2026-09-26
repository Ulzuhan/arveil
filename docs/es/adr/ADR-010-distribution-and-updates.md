# ADR-010 — Distribución y actualizaciones fuera de las tiendas

- **Estado:** propuesta. La implementación de Android está en revisión: los criterios de aceptación 3 a 5 aún necesitan evidencia registrada antes de aceptar esta decisión para Android.
- **Implementación:** búsqueda, descarga, `PackageInstaller` y firma local de manifiestos para Android; véase [Actualizaciones firmadas](../CLIENT_UPDATES.md). macOS/Sparkle y la rotación automática de claves quedan pendientes. Este código no configura un feed público ni un relay personal.
- **Fecha:** 2026-09-26.
- **Alcance:** cómo consiguen las apps de Android y macOS, y sus actualizaciones, personas que no son desarrolladoras mientras Arveil no esté en Google Play ni en la App Store; cómo sabe la app que hay una versión nueva; qué revela esa comprobación. Forma parte de M3b.8 del [plan Flutter](../PHASE3B.md) («actualizaciones firmadas»).

[English version](../../adr/ADR-010-distribution-and-updates.md).

## Contexto

Los primeros paquetes son un APK de Android y un ZIP de macOS, publicados como releases `clients-v*` en GitHub con `SHA256SUMS-clients.txt` ([paquetes del cliente](../CLIENT_RELEASES.md)). Ninguno pasa por una tienda, al menos al principio. Para quien desarrolla, basta. Para las personas a las que va dirigido Arveil, no: el padre o la madre de alguien no va a recorrer las releases de GitHub, comparar sumas ni acordarse de mirar si hay versión nueva, y una app que nunca se actualiza conserva sus fallos y sus vulnerabilidades.

El proyecto tiene una web pública con una guía de instalación y, cuando haya versión pública, enlaces directos de descarga. Eso resuelve la primera instalación. No resuelve la segunda.

Tres condiciones acotan cualquier respuesta:

- **Las actualizaciones son la vía de ataque más atractiva contra un mensajero cifrado.** Quien consigue que un dispositivo instale un cliente modificado lee todo lo que ese dispositivo lee. El [modelo de amenazas](../THREAT_MODEL.md#6-riesgos-abiertos-que-bloquean-afirmaciones-fuertes) ya recoge como riesgo abierto las «actualizaciones firmadas desde un canal independiente del realm».
- **El cliente no llama a casa.** Principio 6 del [diseño del cliente](../CLIENT_DESIGN.md): nada se descarga en ejecución y no hay analítica. Preguntar a un servidor «¿hay versión nueva?» revela la IP del dispositivo, la hora y, si no se diseña para evitarlo, la versión instalada.
- **Una actualización nunca puede costar el perfil.** Desinstalar o borrar los datos elimina la identidad local; desde `0.1.0+11` la app se niega a abrir un perfil de una versión más nueva. Android sólo acepta una actualización firmada con la misma clave y con número de build mayor.

## Decisión

**1. Los binarios se quedan en GitHub Releases.** Cada paquete publicado vive en su release `clients-v*`, inmutable una vez publicada (sin `--clobber`, como ya exige la guía de releases). La web enlaza; no aloja copias. Una sola fuente, las sumas de la propia release, y ni ancho de banda ni disco en el servidor de la web.

**2. La versión vigente la anuncia un manifiesto firmado, no «latest».** `releases/latest` de GitHub ignora las prereleases y no distingue `v*` (relay y CLI) de `clients-v*`. Un JSON pequeño por canal, `clients-<canal>.json` (`clients-beta.json` para quien prueba con el mantenedor, `clients-stable.json` para el resto), recoge por plataforma la versión, el número de build, el sistema mínimo, la URL de descarga, el tamaño y el SHA-256, además de la URL de las notas, un `sequence` que sólo crece y una fecha `expires`. Se publica en la web del proyecto y se adjunta a la release. El canal va compilado en la app y firmado dentro del manifiesto, así que cada build sólo acepta el de su canal.

**3. El manifiesto se firma con una clave de actualizaciones dedicada.** Una clave Ed25519 que no sirve para nada más: ni es la clave de firma de Android ni la de ningún realm. Vive fuera del servidor de la web y fuera de la CI, tiene copia como la de Android, y la firma se hace en la máquina del mantenedor en el mismo momento en que una release pasa de borrador a publicada. La clave pública va compilada en la app. Una clave futura puede anunciarse dentro de un manifiesto firmado por la actual.

**4. El canal de actualizaciones es independiente del realm.** La app nunca pregunta al relay por actualizaciones y el relay nunca distribuye binarios. Un realm hostil o comprometido no puede ni colar un cliente ni retenerlo; una web comprometida puede retener actualizaciones (ver `expires`), pero no conseguir que la app acepte un binario.

**5. Comprobar es opcional y no dice nada del dispositivo.** Desactivado por defecto, con un **Buscar actualizaciones** manual en Ajustes y la opción de comprobar como mucho una vez al día. La petición es un `GET` del manifiesto entero, sin versión, identificador ni cookie; la comparación se hace en el dispositivo. El modelo de amenazas declara el residuo: quien opera la web y su CDN ven una IP y una hora.

**6. Nada se instala en silencio.** La app verifica la firma del manifiesto, rechaza un `sequence` menor o un manifiesto caducado, descarga el paquete, comprueba tamaño y SHA-256 y sólo entonces lo ofrece, con las notas de la versión. La persona confirma y es el sistema operativo quien instala. Un paquete que falle cualquier comprobación se borra y nunca se ofrece. Nunca se ofrece un número de build menor que el instalado.

**7. Por fases y por plataforma.**

| Plataforma | Fase | Mecanismo |
|---|---|---|
| Android | Clientes anteriores | Descarga desde la web y la guía de instalación, por encima de la app existente una vez para incorporar el actualizador. Opcionalmente, [Obtainium](https://github.com/ImranR98/Obtainium) con las prereleases activadas y un filtro para el APK; el sistema sigue exigiendo el mismo certificado |
| Android | Implementado, en aceptación | Comprobación en la app (decisiones 5 y 6); el APK verificado se entrega al instalador del sistema con una sesión de `PackageInstaller`, que exige el permiso `REQUEST_INSTALL_PACKAGES` y la confirmación de la persona |
| macOS | M3b.8 | [Sparkle](https://sparkle-project.org/) con un appcast generado desde el mismo manifiesto y firmado con la misma clave de actualizaciones (el EdDSA de Sparkle es Ed25519). Hasta entonces: descargar y sustituir la app, como dice la guía |
| Windows, Linux | M3b.6 | Se decide con esas compilaciones; el formato del manifiesto ya tiene sitio para ellas |
| iOS | M3b.7 | No hay distribución práctica fuera de la de Apple (App Store o TestFlight); queda fuera de esta decisión |

## Amenazas y qué puede hacer cada parte

| Parte | Puede | No puede |
|---|---|---|
| Quien opera el realm | Nada relacionado con las actualizaciones | Colar, bloquear u observar comprobaciones |
| Quien opera la web, o su CDN | Ver IP y hora de las comprobaciones activadas; retener el manifiesto (se detecta al caducar); servir uno viejo (lo rechaza `sequence`) | Conseguir que la app acepte un paquete: firma y sumas se comprueban en el dispositivo |
| GitHub | Retener o sustituir un fichero | Sustituirlo sin que se note: tamaño y SHA-256 vienen del manifiesto firmado |
| Quien robe la clave de actualizaciones | Anunciar el paquete que quiera. En macOS basta: con firma ad hoc y sin Developer ID no hay segunda barrera | Que Android lo instale como actualización sin tener también la clave de firma de Android; por eso las dos claves van separadas |
| Quien robe la clave de firma de Android | Compilar un APK que Android aceptaría como actualización | Que la app lo ofrezca sin la clave de actualizaciones |

## Alternativas

| Alternativa | Por qué no ahora |
|---|---|
| Google Play y la App Store | Cuentas de desarrollador, ciclos de revisión y una tienda en medio de cada versión. No se descarta más adelante; iOS probablemente la necesitará |
| El repositorio principal de F-Droid | Exige compilaciones que F-Droid pueda reproducir desde el código; con Rust + Flutter + SQLCipher eso es un proyecto en sí. Vale la pena revisarlo |
| Un repositorio propio de F-Droid | Estático, con índice firmado y clientes existentes; razonable para quien ya usa F-Droid, y compatible con esta decisión. No es la vía por defecto: casi nadie tiene F-Droid |
| Sólo Obtainium | Sin código y funciona hoy, pero se fía de lo que sirva GitHub más allá del certificado del APK, y es otra app que instalar. Queda como opción |
| Actualizaciones a través del realm | El realm no es de confianza por diseño ([ADR-003](ADR-003-zero-trust-server.md)); no debe poder cambiar el cliente |
| Servir los binarios desde la web | Duplica las releases inmutables de GitHub y lleva ancho de banda y disponibilidad al servidor de la web |
| Actualizaciones automáticas y silenciosas | Contradicen el consentimiento y el principio de no llamar a casa, y esconden justo el cambio que alguien puede querer aplazar |

## Consecuencias

Aparece un segundo secreto de larga vida: la clave de actualizaciones, con su copia y su rotación. Perderla obliga a publicar una versión con una clave pública nueva que la gente instala a mano, una vez.

Publicar una versión gana un paso: generar el `clients-<canal>.json` del canal, firmarlo, publicarlo en la web y adjuntarlo a la release. La sección de descargas de la web se genera desde el mismo manifiesto, así que la página y la app no pueden discrepar sobre cuál es la versión vigente.

El actualizador Android usa `REQUEST_INSTALL_PACKAGES`, un permiso que algunas tiendas y políticas de dispositivo restringen; sólo lo declaran los builds con canal de actualizaciones. La prueba del instalador está en el [registro de plataformas](../PLATFORMS.md#aceptacion-del-actualizador-android-firmado-2026-09-26). Esto no completa los demás requisitos de M3b.8.

Que sea opcional significa que la mayoría de las instalaciones no buscará actualizaciones por su cuenta. La guía de instalación y las notas de cada versión siguen siendo el canal principal hasta que la comprobación demuestre su valor.

## Criterios de aceptación

1. Un manifiesto con firma no válida, con un `sequence` menor que el último visto o pasado su `expires` se rechaza y no se ofrece nada.
2. Un paquete cuyo tamaño o SHA-256 no coincide con el manifiesto se borra y no se ofrece.
3. Con la comprobación desactivada, una captura no muestra ninguna petición de la app a la web ni a GitHub, ni al arrancar ni nunca.
4. Una comprobación activada no envía versión, identificador ni cookie.
5. Con el realm caído u hostil, la comprobación se comporta igual.
6. En Android, una actualización sobre una instalación existente conserva el perfil; un APK firmado con otra clave lo rechaza el sistema y la app lo explica sin proponer desinstalar.
7. Nunca se ofrece un build menor que el instalado.

## Preguntas abiertas

- Si la firma puede pasar a la CI sin dejar la clave al alcance de sus logs y de acciones de terceros.
- Cuánto dura un manifiesto (`expires`): lo bastante para no romper móviles que pasan semanas sin conexión, y lo bastante poco para notar una actualización retenida.
