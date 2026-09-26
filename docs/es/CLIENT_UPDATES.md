# Actualizaciones Android firmadas

Arveil permite buscar una actualización, descargar el APK verificado y pedir
a Android que lo instale **encima de la app existente**, conservando el perfil
y las conversaciones. No desinstales ni borres datos para actualizar. Una
versión anterior sin actualizador necesita una última instalación manual por
encima para incorporar esta función.

La pantalla está en **Ajustes → Actualizaciones** y en el icono de actualización
con el perfil cerrado. La búsqueda es manual por defecto. Puedes activar una
comprobación al abrir o volver a la app, como máximo una vez al día, también
cuando la consulta anterior falló. El aviso aparece dentro de la app; no hay
push, comprobaciones en segundo plano ni avisos con la app cerrada.

La consulta es independiente del realm y no necesita abrir el perfil. No envía
identidad, versión instalada ni cookies. El alojamiento del manifiesto sigue
viendo IP y hora; descargar el APK contacta además con su alojamiento. Una
compilación sin canal configurado no consulta un servicio central por defecto.

Primero se verifica la firma Ed25519 del anuncio, su caducidad y que no sea
anterior al último aceptado. La descarga debe coincidir en tamaño y SHA-256;
un archivo incorrecto o incompleto se elimina. **Instalar actualización** puede
pedir primero el permiso de Android para instalar paquetes desde Arveil.
Después, vuelve a la app y pulsa Instalar. Android muestra la confirmación.
La app verifica de nuevo los bytes al copiarlos a `PackageInstaller`, exige
el mismo identificador y certificado y un número de compilación superior.
Nunca propone desinstalar como solución a un error.

## Para quien distribuye la app

La [guía técnica de actualizaciones](../CLIENT_UPDATES.md) especifica el formato,
los comandos y la publicación. La configuración tiene exactamente tres campos
públicos: URL HTTPS del manifiesto, clave pública Ed25519 y canal `beta` o
`stable`. Se introduce mediante `--update-config` al crear el APK y se incluye
en `BUILD.json`. El archivo de entrada puede vivir en `.local/`, ignorado por Git.
No contiene datos de ningún relay personal.

1. Conserva la clave de firma Android existente y aumenta el número de
   compilación en cada versión distribuida.
2. Crea una clave Ed25519 **diferente**, con
   `scripts/client_updates.py init-key`. Guarda una copia cifrada fuera del
   checkout, separada de la clave Android. No la entregues al relay, web o CI.
3. Compila desde un commit limpio con `scripts/package_clients.py`, indicando
   `--signing-config`, `--update-config` y `--build-number`.
4. Prepara el release inmutable `clients-v*` y firma su anuncio con
   `scripts/client_updates.py sign`. El comando comprueba los hashes del
   paquete, la distribución y la clave; solo genera archivos locales.
5. Publica primero el APK. Adjunta el anuncio firmado con un nombre único por
   secuencia y sirve sus mismos bytes en la URL fija del manifiesto, sin
   redirecciones, compresión ni desafíos de navegador. No uses `releases/latest`.

Cada cambio del anuncio exige una secuencia superior, incluso renovar su
caducidad sin cambiar el APK. La validez por defecto es de 30 días, hasta 90.
Lleva un registro privado de secuencias y renueva el anuncio a tiempo. Un
anuncio caducado bloquea la oferta de esa actualización, no la mensajería.
Un servidor todavía puede ocultar una versión nueva mientras el anuncio
anterior siga siendo válido.

El estado de seguridad del actualizador se guarda fuera del perfil y se
reemplaza de forma atómica antes de ofrecer una versión. Un fallo de lectura o
escritura detiene las actualizaciones en lugar de borrar la protección contra
retrocesos. No borres los datos de la app para recuperarlo.

macOS continúa con sustitución manual de la app. Sparkle, rotación automática
de la clave de actualizaciones, cambio de canal de una instalación existente
y migración del certificado Android quedan pendientes. Cambiar simplemente
la clave compilada no constituye una migración segura.

Las pruebas cubren firma inválida, un vector OpenSSL independiente, caducidad,
retrocesos, consultas desactivadas, frecuencia diaria, descargas manipuladas,
redirecciones y validación nativa del paquete. El ensayo del instalador real
usa un emulador desechable y verifica la misma identidad SQLCipher/Keystore
después de aceptar la actualización. No distribuyas los APK de ese ensayo.
