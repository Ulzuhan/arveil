//! `arveil` command-line client.
//!
//! Phase 0 uses this binary to drive clients against a local relay and to
//! record the demo. It is not the end-user interface.

use std::process::ExitCode;

mod carrier;
mod chat;
mod commands;

const USAGE: &str = "usage:
  arveil version
  arveil identity new --data-dir <dir>
  arveil enroll --data-dir <dir> <bootstrap> <invite-token-hex>
  arveil probe [--data-dir <dir>] <bootstrap>
  arveil status --data-dir <dir>
  arveil mailbox create --data-dir <dir> <bootstrap>
  arveil send --data-dir <dir> <bootstrap> <route> <text>
  arveil fetch --data-dir <dir> <bootstrap>
  arveil chat start --data-dir <dir> <bootstrap> <peer-route>...
  arveil chat add --data-dir <dir> <bootstrap> <peer-route>
  arveil chat send --data-dir <dir> <bootstrap> <text>
  arveil chat sync --data-dir <dir> <bootstrap>
  arveil chat history --data-dir <dir>";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (data_dir, rest) = commands::data_dir_arg(&args);
    let words: Vec<&str> = rest.iter().map(String::as_str).collect();

    let result = match words.as_slice() {
        ["version"] => {
            println!(
                "arveil {} (protocol {})",
                arveil_core::version(),
                arveil_core::PROTOCOL_VERSION
            );
            Ok(())
        }
        ["identity", "new"] => match data_dir {
            Some(d) => commands::identity_new(&d),
            None => usage(),
        },
        ["enroll", bootstrap, invite] => match data_dir {
            Some(d) => commands::enroll(&d, bootstrap, invite),
            None => usage(),
        },
        ["probe", bootstrap] => commands::probe(data_dir.as_deref(), bootstrap),
        ["status"] => match data_dir {
            Some(d) => commands::status(&d),
            None => usage(),
        },
        ["mailbox", "create", bootstrap] => match data_dir {
            Some(d) => commands::mailbox_create(&d, bootstrap),
            None => usage(),
        },
        ["send", bootstrap, route, text] => match data_dir {
            Some(d) => commands::send(&d, bootstrap, route, text),
            None => usage(),
        },
        ["fetch", bootstrap] => match data_dir {
            Some(d) => commands::fetch(&d, bootstrap),
            None => usage(),
        },
        ["chat", "start", bootstrap, routes @ ..] if !routes.is_empty() => match data_dir {
            Some(d) => chat::start(&d, bootstrap, routes),
            None => usage(),
        },
        ["chat", "add", bootstrap, route] => match data_dir {
            Some(d) => chat::add(&d, bootstrap, route),
            None => usage(),
        },
        ["chat", "send", bootstrap, text] => match data_dir {
            Some(d) => chat::send(&d, bootstrap, text),
            None => usage(),
        },
        ["chat", "sync", bootstrap] => match data_dir {
            Some(d) => chat::sync(&d, bootstrap),
            None => usage(),
        },
        ["chat", "history"] => match data_dir {
            Some(d) => chat::history(&d),
            None => usage(),
        },
        _ => usage(),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("arveil: {e}");
            ExitCode::FAILURE
        }
    }
}

fn usage() -> Result<(), carrier::CliError> {
    Err(carrier::CliError(USAGE.into()))
}
