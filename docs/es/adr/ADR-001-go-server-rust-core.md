# ADR-001 — Servidor Go y core seguro Rust

- **Estado:** propuesto.
- **Fecha:** 2026-09-04.
- **Edición documental:** v0.2; alcance de comprobación en el [índice](../README.md#referencias-y-trazabilidad).
- **Ámbito:** distribución de responsabilidades y dependencias.

*English version: [../../adr/ADR-001-go-server-rust-core.md](../../adr/ADR-001-go-server-rust-core.md)*

## Contexto

El servidor debe ser fácil de operar en un homelab, con conexiones persistentes, colas y almacenamiento local. Los clientes necesitan la misma implementación de identidad, MLS, persistencia y recuperación en varias plataformas. El diseño anterior contempló backend Rust; la apuesta actual separa estas dos necesidades.

## Decisión

Construir el realm como monolito modular en Go. Construir un core Rust embebido en cada cliente. El servidor no ejecuta ni enlaza ese core, no es miembro MLS y no recibe secretos E2EE. El límite entre ambos es el protocolo de red versionado.

El core posee las máquinas de estado y valida seguridad antes de devolver eventos a la UI. Flutter con bindings Rust es candidato para presentación, sujeto a probar móviles y escritorio; no se fijan todavía ABI, generador de bindings o framework como requisito irreversible.

Fijar toolchains y dependencias al crear el repositorio, con lockfiles, inventario y actualizaciones revisadas. No adoptar «la última versión» sin probar providers y plataformas. La consulta del 2026-09-04 confirma Go 1.27.1, publicado el 1 de septiembre, y Rust 1.98.1, publicado el 3 de septiembre. Son candidatos iniciales sujetos al build y pruebas del proyecto. Rust 1.98.1 corrige un fallo de generación de vtables de 1.98.0; no se seleccionará 1.98.0 para el prototipo. Fuentes: [Go](https://go.dev/doc/devel/release) y [Rust](https://blog.rust-lang.org/2026/09/03/Rust-1.98.1/).

## Alternativas

| Alternativa | Ventaja | Motivo para no adoptarla ahora |
|---|---|---|
| Todo Rust | Un lenguaje y tipos compartidos | No es necesario compartir el estado criptográfico con el relay; Go es una elección operativa razonable |
| Todo Go | Toolchain única para servidor/core | Se prefiere evaluar las bibliotecas MLS Rust y su integración cliente |
| Criptografía en Dart/Swift/Kotlin por separado | Menos FFI por plataforma | Duplica lógica crítica y aumenta riesgo de divergencia |
| Go con Rust por FFI en servidor | Reutilización de código | Añade complejidad donde el servidor solo necesita transporte y validación pública |

## Consecuencias

Dos toolchains, builds móviles y frontera FFI requieren mantenimiento real. Rust no elimina errores lógicos ni inseguridad en bindings. Go no garantiza un servidor pequeño o rápido por sí solo; esas propiedades se miden.

Los bindings no exponen claves privadas, capturan errores sin volcar secretos y definen cancelación, propiedad de memoria y lifecycle. Se separan parsers públicos compartidos por especificación de cualquier almacenamiento criptográfico privado. No se trasladan decisiones de autorización a la UI por comodidad.

## Alcance de plataformas comprobado

El README de OpenMLS distingue targets construidos y probados de otros solo compilados en CI. Android, iOS y WASM figuran en este segundo grupo, marcado como no soportado. Que compilen no demuestra funcionamiento móvil, persistencia segura ni calidad de los bindings. La selección exige ejecutar pruebas propias en dispositivos reales. [Fuente: OpenMLS](https://github.com/openmls/openmls#supported-platforms).

## Validación y revisión

Prototipo con dos clientes que usan el mismo core; pruebas de reinicio y atomicidad MLS; build en una plataforma móvil y una de escritorio; medición del servidor con conexiones concurrentes y límites de memoria. Aceptar solo si el empaquetado de SQLite y providers es reproducible.

Reabrir si el coste de FFI/plataformas impide distribuir clientes o si un servidor Rust simplifica sustancialmente el mantenimiento demostrado. No reabrir solo por benchmarks sintéticos de lenguaje.

Referencias: [arquitectura](../ARCHITECTURE.md), [versiones y fuentes](../README.md#referencias-y-trazabilidad).
