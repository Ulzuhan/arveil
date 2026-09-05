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
  arveil device pair --data-dir <dir> <bootstrap>
  arveil device pair-approve --data-dir <dir> <bootstrap> <pairing-code>
  arveil device pair-confirm --data-dir <dir> <bootstrap> <verification-code>
  arveil device pair-cancel --data-dir <dir> <session-id>
  arveil kit export --data-dir <dir> <path>
  arveil kit restore --data-dir <dir> <bootstrap> <path> <secret>
  arveil archive export --data-dir <dir> <path>
  arveil archive import --data-dir <dir> <path> <secret>
  arveil notify set --data-dir <dir> <bootstrap> <url>
  arveil notify clear --data-dir <dir> <bootstrap>
  arveil contact list --data-dir <dir>
  arveil contact verify --data-dir <dir> <identity-id> <safety-number>
  arveil contact name --data-dir <dir> <identity-id> <name>
  arveil mailbox create --data-dir <dir> <bootstrap>
  arveil send --data-dir <dir> <bootstrap> <route> <text>
  arveil fetch --data-dir <dir> <bootstrap>
  arveil chat start --data-dir <dir> <bootstrap> <peer-route>...
  arveil chat list --data-dir <dir>
  arveil chat add --data-dir <dir> <bootstrap> <peer-route> [--group <prefix>]
  arveil chat remove --data-dir <dir> <bootstrap> <device-id>
  arveil chat send --data-dir <dir> <bootstrap> <text> [--group <prefix>]
  arveil chat send-file --data-dir <dir> <bootstrap> <path> [--group <prefix>]
  arveil chat sync --data-dir <dir> <bootstrap>
  arveil chat history --data-dir <dir>";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (data_dir, rest) = commands::data_dir_arg(&args);
    let (group, rest) = commands::flag_arg(&rest, "--group");
    let group = group.as_deref();
    let words: Vec<&str> = rest.iter().map(String::as_str).collect();

    // A profile is reserved once, by whoever owns it for this command. An
    // application command opens a session, and that session holds the
    // reservation; only the commands that still reach the client directly
    // take a guard of their own.
    let profile_guard = match (&data_dir, legacy(&words)) {
        (Some(dir), true) => arveil_app::ProfileGuard::acquire(dir).map(Some),
        _ => Ok(None),
    };
    let result = match profile_guard {
        Err(error) => Err(carrier::CliError::FileSystem(error.to_string())),
        Ok(_profile_guard) => match words.as_slice() {
            ["version"] => {
                match arveil_core::revision() {
                    Some(rev) => println!(
                        "arveil {}+{rev} (protocol {})",
                        arveil_core::version(),
                        arveil_core::PROTOCOL_VERSION
                    ),
                    None => println!(
                        "arveil {} (protocol {})",
                        arveil_core::version(),
                        arveil_core::PROTOCOL_VERSION
                    ),
                }
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
            ["device", "pair", bootstrap] => match data_dir {
                Some(d) => link::pair(&d, bootstrap),
                None => usage(),
            },
            ["device", "pair-approve", bootstrap, code] => match data_dir {
                Some(d) => link::pair_approve(&d, bootstrap, code),
                None => usage(),
            },
            ["device", "pair-confirm", bootstrap, sas] => match data_dir {
                Some(d) => link::pair_confirm(&d, bootstrap, sas),
                None => usage(),
            },
            ["device", "pair-cancel", session_id] => match data_dir {
                Some(d) => link::pair_cancel(&d, session_id),
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
            ["notify", "set", bootstrap, url] => match data_dir {
                Some(d) => commands::notify_set(&d, bootstrap, url),
                None => usage(),
            },
            ["notify", "clear", bootstrap] => match data_dir {
                Some(d) => commands::notify_set(&d, bootstrap, ""),
                None => usage(),
            },
            ["contact", "list"] => match data_dir {
                Some(d) => commands::contact_list(&d),
                None => usage(),
            },
            ["contact", "name", identity, name] => match data_dir {
                Some(d) => commands::contact_name(&d, identity, name),
                None => usage(),
            },
            ["contact", "verify", identity, number] => match data_dir {
                Some(d) => commands::contact_verify(&d, identity, number),
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
            ["chat", "list"] => match data_dir {
                Some(d) => chat::list(&d),
                None => usage(),
            },
            ["chat", "add", bootstrap, route] => match data_dir {
                Some(d) => chat::add(&d, bootstrap, route, group),
                None => usage(),
            },
            ["chat", "remove", bootstrap, device] => match data_dir {
                Some(d) => chat::remove(&d, bootstrap, device, group),
                None => usage(),
            },
            ["chat", "send-file", bootstrap, path] => match data_dir {
                Some(d) => chat::send_file(&d, bootstrap, std::path::Path::new(path), group),
                None => usage(),
            },
            ["chat", "send", bootstrap, text] => match data_dir {
                Some(d) => chat::send(&d, bootstrap, text, group),
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
        },
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("arveil: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Commands that open the client themselves instead of entering the
/// application layer. They keep an exclusive guard until they finish.
fn legacy(words: &[&str]) -> bool {
    matches!(
        words.first(),
        Some(
            &"probe"
                | &"status"
                | &"kit"
                | &"archive"
                | &"notify"
                | &"contact"
                | &"mailbox"
                | &"send"
                | &"fetch"
        )
    )
}

fn usage() -> Result<(), carrier::CliError> {
    Err(carrier::CliError(USAGE.into()))
}
