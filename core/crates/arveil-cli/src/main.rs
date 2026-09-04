//! `arveil` command-line client.
//!
//! Phase 0 uses this binary to drive clients against a local relay and to
//! record the demo. It is not the end-user interface.

use std::process::ExitCode;

mod carrier;
mod chat;
mod commands;
mod kit;
mod link;

const USAGE: &str = "usage:
  arveil version
  arveil identity new --data-dir <dir>
  arveil enroll --data-dir <dir> <bootstrap> <invite-token-hex>
  arveil probe [--data-dir <dir>] <bootstrap>
  arveil status --data-dir <dir>
  arveil device request --data-dir <dir>
  arveil device authorize --data-dir <dir> <bootstrap> <link-request>
  arveil device link --data-dir <dir> <bootstrap> <link-grant>
  arveil device revoke --data-dir <dir> <bootstrap> <device-id>
  arveil kit export --data-dir <dir> <path>
  arveil kit restore --data-dir <dir> <bootstrap> <path> <secret>
  arveil archive export --data-dir <dir> <path>
  arveil archive import --data-dir <dir> <path> <secret>
  arveil mailbox create --data-dir <dir> <bootstrap>
  arveil send --data-dir <dir> <bootstrap> <route> <text>
  arveil fetch --data-dir <dir> <bootstrap>
  arveil chat start --data-dir <dir> <bootstrap> <peer-route>...
  arveil chat add --data-dir <dir> <bootstrap> <peer-route>
  arveil chat remove --data-dir <dir> <bootstrap> <device-id>
  arveil chat send --data-dir <dir> <bootstrap> <text>
  arveil chat send-file --data-dir <dir> <bootstrap> <path>
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
        ["device", "request"] => match data_dir {
            Some(d) => link::request(&d),
            None => usage(),
        },
        ["device", "authorize", bootstrap, request] => match data_dir {
            Some(d) => link::authorize(&d, bootstrap, request),
            None => usage(),
        },
        ["device", "link", bootstrap, grant] => match data_dir {
            Some(d) => link::link(&d, bootstrap, grant),
            None => usage(),
        },
        ["device", "revoke", bootstrap, device] => match data_dir {
            Some(d) => chat::revoke(&d, bootstrap, device),
            None => usage(),
        },
        ["kit", "export", path] => match data_dir {
            Some(d) => kit::kit_export(&d, std::path::Path::new(path)),
            None => usage(),
        },
        ["kit", "restore", bootstrap, path, secret] => match data_dir {
            Some(d) => kit::kit_restore(&d, bootstrap, std::path::Path::new(path), secret),
            None => usage(),
        },
        ["archive", "export", path] => match data_dir {
            Some(d) => kit::archive_export(&d, std::path::Path::new(path)),
            None => usage(),
        },
        ["archive", "import", path, secret] => match data_dir {
            Some(d) => kit::archive_import(&d, std::path::Path::new(path), secret),
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
        ["chat", "remove", bootstrap, device] => match data_dir {
            Some(d) => chat::remove(&d, bootstrap, device),
            None => usage(),
        },
        ["chat", "send-file", bootstrap, path] => match data_dir {
            Some(d) => chat::send_file(&d, bootstrap, std::path::Path::new(path)),
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
