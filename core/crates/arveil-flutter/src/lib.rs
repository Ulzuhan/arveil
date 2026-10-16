//! Flutter adapter over `arveil-app`.
//!
//! This crate translates the application contract into the shapes the
//! generated bindings can carry, and does nothing else: no rule, no state
//! and no storage of its own live here. `arveil-app` and `arveil-core` know
//! nothing about Dart, so a second adapter can sit beside this one
//! (ADR-009).

#![deny(unsafe_code)]

pub mod api;

// JNI entry points for the Android activity service (ADR-014). Exported
// symbols need `#[unsafe(no_mangle)]`, so this module carries the second,
// and last, exception to the rule above; it calls only safe `jni` APIs.
#[cfg(target_os = "android")]
#[allow(unsafe_code)]
mod android;

// The generator writes this module, and it is the only place in the
// workspace where `unsafe` is allowed to appear (M3b.0).
#[allow(unsafe_code)]
#[allow(clippy::all)]
#[rustfmt::skip]
mod frb_generated;
