# ADR-001 — Go server and secure Rust core

- **Status:** proposed.
- **Date:** 2026-09-04.
- **Documentation edition:** v0.2; verification scope in the [index](../README.md#references-and-traceability).
- **Scope:** distribution of responsibilities and dependencies.

*Versión en español: [../es/adr/ADR-001-go-server-rust-core.md](../es/adr/ADR-001-go-server-rust-core.md)*

## Context

The server must be easy to operate in a homelab, with persistent connections, queues and local storage. Clients need the same implementation of identity, MLS, persistence and recovery across several platforms. The previous design considered a Rust backend; the current bet separates these two needs.

## Decision

Build the realm as a modular monolith in Go. Build a Rust core embedded in each client. The server does not run or link that core, is not an MLS member and receives no E2EE secrets. The boundary between the two is the versioned network protocol.

The core owns the state machines and validates security before returning events to the UI. Flutter with Rust bindings is a candidate for presentation, subject to testing on mobile and desktop; ABI, bindings generator and framework are not yet fixed as an irreversible requirement.

Pin toolchains and dependencies when creating the repository, with lockfiles, an inventory and reviewed updates. Do not adopt "the latest version" without testing providers and platforms. The check on 2026-09-04 confirms Go 1.27.1, released on September 1, and Rust 1.98.1, released on September 3. They are initial candidates subject to the project's build and tests. Rust 1.98.1 fixes a vtable generation bug in 1.98.0; 1.98.0 will not be selected for the prototype. Sources: [Go](https://go.dev/doc/devel/release) and [Rust](https://blog.rust-lang.org/2026/09/03/Rust-1.98.1/).

## Alternatives

| Alternative | Advantage | Reason not to adopt it now |
|---|---|---|
| All Rust | One language and shared types | Sharing cryptographic state with the relay is not necessary; Go is a reasonable operational choice |
| All Go | Single toolchain for server/core | Evaluating the Rust MLS libraries and their client integration is preferred |
| Separate cryptography in Dart/Swift/Kotlin | Less FFI per platform | Duplicates critical logic and increases the risk of divergence |
| Go with Rust via FFI on the server | Code reuse | Adds complexity where the server only needs transport and public validation |

## Consequences

Two toolchains, mobile builds and the FFI boundary require real maintenance. Rust does not eliminate logic errors or unsafety in bindings. Go does not by itself guarantee a small or fast server; those properties are measured.

The bindings do not expose private keys, capture errors without dumping secrets, and define cancellation, memory ownership and lifecycle. Public parsers shared by specification are separated from any private cryptographic storage. Authorization decisions are not moved to the UI for convenience.

## Verified platform scope

The OpenMLS README distinguishes targets that are built and tested from others that are only compiled in CI. Android, iOS and WASM are in this second group, marked as unsupported. That they compile does not demonstrate mobile operation, secure persistence or the quality of the bindings. Selection requires running our own tests on real devices. [Source: OpenMLS](https://github.com/openmls/openmls#supported-platforms).

## Validation and review

Prototype with two clients using the same core; MLS restart and atomicity tests; build on one mobile platform and one desktop platform; measurement of the server with concurrent connections and memory limits. Accept only if the packaging of SQLite and providers is reproducible.

Reopen if the cost of FFI/platforms prevents distributing clients or if a Rust server demonstrably simplifies maintenance substantially. Do not reopen solely because of synthetic language benchmarks.

References: [architecture](../ARCHITECTURE.md), [versions and sources](../README.md#references-and-traceability).
