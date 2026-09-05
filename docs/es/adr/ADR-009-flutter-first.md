# ADR-009: Flutter primero, núcleo Rust compartido

Estado: aceptada como dirección de implementación; GUI todavía no implementada.

[English version](../../adr/ADR-009-flutter-first.md).

## Contexto

El objetivo inmediato es disponer de un mensajero utilizable en los sistemas del mantenedor, macOS y Android. Se desea cubrir también iOS, Windows y Linux. El mantenedor conoce Flutter y valora una posible interfaz SwiftUI futura para Apple. Mantener desde el inicio dos interfaces y dos puentes retrasaría la validación del producto.

## Decisión

Construir un cliente Flutter para las cinco plataformas, conectado mediante `flutter_rust_bridge` a un adaptador Rust pequeño sobre `arveil-app`. Priorizar macOS y Android en la primera beta; incorporar después Windows/Linux e iOS con validación específica. Una plataforma no se considera soportada solo porque el framework pueda compilar para ella.

Mantener identidad, MLS, entrega, persistencia y decisiones de dominio en Rust. Flutter contiene navegación, presentación y estado temporal de pantalla. Las integraciones de sistema proporcionan claves, permisos, notificaciones y acceso a archivos mediante contratos explícitos.

El relay conserva su arquitectura y responsabilidad. Se permite en M3b.2 una corrección acotada del contrato de inscripción y su persistencia para que la secuencia de inscripción —canje `InviteRedeem` y creación de buzón— sea reanudable e idempotente ante concurrencia y respuesta perdida, con pruebas de autorización, consumo único y compatibilidad. No implica un rediseño general del protocolo. Rust se integra como biblioteca del cliente; no se añade un servidor HTTP local ni IPC entre procesos en esta fase.

SwiftUI/UniFFI queda como evolución opcional, motivada por necesidades observadas. No se implementa ahora ni se promete reutilizar las pantallas Dart en SwiftUI. El contrato de aplicación debe poder admitir otro adaptador sin incorporar tipos Dart en `arveil-app` o `arveil-core`.

## Consecuencias

- Una base de UI y un puente inicial reducen el trabajo de mantenimiento.
- Se necesitan disposiciones y comportamiento apropiados para móvil y escritorio; no se exige una pantalla idéntica en todos los sistemas.
- Firma, distribución, almacén seguro, segundo plano y push continúan siendo trabajos por plataforma.
- Las versiones de Flutter, del puente y los targets se explorarán durante el spike y quedarán fijados antes de aceptar M3b.0, junto con toolchains nativos y mínimos de SO; esta decisión no presupone compatibilidad probada de SQLCipher en móviles.
- No se seleccionan aún proveedor push ni arquitectura de extensiones iOS. Deben resolverse y probarse antes de anunciar recepción en segundo plano.

## Alternativas consideradas

SwiftUI + Compose + Rust permitiría interfaces específicas con dos familias de UI, pero no aprovecha la experiencia principal del mantenedor. SwiftUI + Flutter + Rust sigue siendo posible después; se pospone el segundo frontend para validar primero un producto funcional.

## Referencias y aceptación

- [Plataformas Flutter](https://docs.flutter.dev/reference/supported-platforms).
- [Flutter Rust Bridge](https://cjycode.com/flutter_rust_bridge/guides/cross-platform/overview).
- [UniFFI](https://mozilla.github.io/uniffi-rs/latest/) como alternativa futura para Apple.
- [Plan de implementación y criterios de salida](../PHASE3B.md).
