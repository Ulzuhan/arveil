//! `arveil` command-line client.
//!
//! Phase 0 uses this binary to drive clients against a local relay and to
//! record the demo. It is not the end-user interface.
//!
//! `arveil probe <bootstrap>` opens the Noise channel over WebSocket,
//! fetches and verifies the signed endpoint list and exchanges a ping. It is
//! the cross-language check of milestone M0.2.

use std::process::ExitCode;

mod probe;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("version") => {
            println!(
                "arveil {} (protocol {})",
                arveil_core::version(),
                arveil_core::PROTOCOL_VERSION
            );
            ExitCode::SUCCESS
        }
        Some("probe") => match args.get(1) {
            Some(bootstrap) => match probe::run(bootstrap) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("probe failed: {e}");
                    ExitCode::FAILURE
                }
            },
            None => {
                eprintln!("usage: arveil probe <arveil-bootstrap:v0:...>");
                ExitCode::from(2)
            }
        },
        _ => {
            eprintln!("usage: arveil version | arveil probe <bootstrap>");
            eprintln!(
                "Phase 0 commands (identity, realm, chat) land milestone by milestone; see docs/PHASE0.md."
            );
            ExitCode::from(2)
        }
    }
}
