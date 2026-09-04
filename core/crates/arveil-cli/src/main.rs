//! `arveil` command-line client.
//!
//! Phase 0 uses this binary to drive two clients against a local relay and to
//! record the demo. It is not the end-user interface.

use std::process::ExitCode;

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
        _ => {
            eprintln!("usage: arveil version");
            eprintln!(
                "Phase 0 commands (identity, realm, chat) land milestone by milestone; see docs/PHASE0.md."
            );
            ExitCode::from(2)
        }
    }
}
