# ADR-016 · Reincorporación de un dispositivo a una conversación MLS

**Propuesta para revisión · 27 de noviembre de 2026.** Un miembro que conserva el estado actual del grupo puede autorizar que la misma identidad vuelva desde un dispositivo nuevo. El historial importado permanece de lectura. La beta 7 distribuye la restauración de identidad y la importación de historial. Esta propuesta describe el cambio posterior. [Issue #137](https://github.com/Ulzuhan/arveil/issues/137) · [Modelo de amenazas](../THREAT_MODEL.md)

## Casos admitidos

| Situación | Resultado propuesto |
|---|---|
| Dispositivo perdido, raíz recuperada y grupo activo | Registrar la credencial nueva, revocar la perdida, verificar el contacto y solicitar una invitación nueva al grupo. |
| Faltan commits pero pueden recuperarse | Aplicar primero los commits autenticados que faltan. Si es imposible completar la cadena, detener el envío desde ese estado y ofrecer la recuperación con un dispositivo nuevo. |
| Dispositivo expulsado o identidad que abandonó el grupo | Requiere una decisión de admisión nueva del grupo. El derecho histórico de lectura o la posesión del kit son insuficientes. |
| Coordinador ausente | Esperar al coordinador autorizado. La sucesión existente exige que los manifiestos firmados acrediten las revocaciones pertinentes. La desconexión por sí sola no autoriza la sucesión. |
| Ningún miembro conserva un estado activo fiable o se sospecha una bifurcación | Pausar el grupo afectado. Ofrecer crear otro grupo después de volver a verificar a los participantes. Mantener distinguibles las dos conversaciones. |
| Compromiso de la raíz | Tratarlo como incidente de identidad. Una reincorporación bajo esa misma raíz no restablece la confianza. |

## Flujo propuesto

1. El titular recupera la raíz según el flujo existente, registra un dispositivo nuevo y publica sus credenciales, ruta y KeyPackages. El kit y el archivo de historial se procesan localmente. Un contacto con una sesión de grupo activa recibe la solicitud por un canal autenticado. El diseño inicial permite coordinar el contacto fuera de banda y elegir la conversación en la interfaz del miembro activo. Así se evita un directorio de grupos en el relay.
2. El miembro confirma en pantalla el grupo y la identidad del solicitante. El dispositivo autorizado para hacer commits vuelve a verificar el manifiesto bajo la raíz conocida, la credencial activa, su vínculo con la ruta y el KeyPackage, y el estado de revocación. Una identidad nueva con el mismo nombre requiere admisión explícita. La regla de commit vigente elige la hoja activa de menor índice y exige retirar las hojas inferiores revocadas cuando procede. [Protocolo del grupo](../PROTOCOL.md)
3. El coordinador registra una intención duradera asociada al grupo, al epoch padre, a la credencial de reemplazo y al intento. Para un reemplazo retira la hoja obsoleta e incorpora el KeyPackage nuevo mediante MLS. Antes de entregar el Welcome persiste el commit elegido, el nuevo estado y los envíos pendientes. Un reinicio o ACK perdido reutiliza los mismos bytes y la misma decisión. Un cambio de epoch exige reconciliar la intención original antes de considerar otro commit.
4. El dispositivo nuevo verifica el Welcome con el material privado del KeyPackage, la identidad del grupo y la vinculación al intento aprobado. La transición a «Conversación activa» exige persistir el nuevo estado, registrar el intento consumido y poder reabrir el perfil. El archivo de historial conserva su procedencia. La creación de otros grupos y los reenvíos de mensajes pendientes del antiguo perfil requieren una decisión explícita.
5. La interfaz distingue «Historial disponible», «Esperando autorización», «Reincorporación en curso», «Conversación activa» y «Requiere nueva verificación». Solo ofrece enviar en el grupo con el estado activo. Un rechazo permite explicar qué persona puede autorizar una nueva solicitud.

La prueba de núcleo de esta propuesta ejercita un commit con Remove y Add, un Welcome para claves nuevas y mensajes en ambos sentidos. Comprueba que el dispositivo anterior carece de acceso al epoch nuevo y que el reemplazo carece de acceso al mensaje del epoch anterior. La autenticación del solicitante, las transacciones y la interacción pertenecen a las capas de aplicación. [RFC 9420, operaciones del grupo](https://www.rfc-editor.org/rfc/rfc9420.html#section-12)

## Decisiones que debe resolver la revisión

- Fijar la representación autenticada que vincula solicitud, aceptación, credencial, KeyPackage, grupo, intento y caducidad. Determinar qué puede validar el recién llegado antes de aceptar el Welcome y qué requiere comparación con el contacto.
- Precisar si el primer incremento acepta únicamente el reemplazo de una hoja ya revocada. Definir el orden de sincronización de manifiestos y las reglas para expulsión, retirada voluntaria y credenciales que cambiaron desde la solicitud.
- Acordar la transacción y la deduplicación ante reinicio después de elegir commit, después de transmitir Welcome y antes de confirmar la recepción. Fijar límites, caducidad y limpieza de solicitudes. Resolver dos solicitudes simultáneas sin elegir dos commits para el mismo padre.
- Revisar qué datos quedan en los dispositivos y qué metadatos de entrega ve el relay. Registrar la decisión en #137 antes de ampliar el protocolo distribuido.

**Aceptación para implementar.** El revisor de protocolo acuerda las decisiones anteriores y los casos de denegación. **Aceptación para distribuir.** Dos clientes reales completan la recuperación y se intercambian mensajes nuevos. La suite cubre dispositivo perdido y revocado, expulsión, credencial incorrecta, historial importado, falta de coordinador, Welcome duplicado, entrega tardía y reinicio en cada frontera de persistencia. Registrar SHA, versión y límites en la matriz.
