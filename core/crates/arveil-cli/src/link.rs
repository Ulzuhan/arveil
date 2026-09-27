//! Thin CLI presentation for reusable enrollment and pairing services.

use std::io::Write;
use std::path::Path;

use arveil_app::Application;

use crate::carrier::CliError;
use crate::chat::{cli_error, render};

fn application(data_dir: &Path) -> Result<Application, CliError> {
    crate::commands::open_session(data_dir)
}

pub fn request(data_dir: &Path) -> Result<(), CliError> {
    let result = application(data_dir)?
        .create_link_request()
        .map_err(cli_error)?;
    render(result.operation);
    Ok(())
}

pub fn authorize(data_dir: &Path, bootstrap: &str, request: &str) -> Result<(), CliError> {
    let result = application(data_dir)?
        .authorize_link(bootstrap, request)
        .map_err(cli_error)?;
    render(result.operation);
    Ok(())
}

pub fn link(data_dir: &Path, bootstrap: &str, grant: &str) -> Result<(), CliError> {
    let result = application(data_dir)?
        .complete_link(bootstrap, grant)
        .map_err(cli_error)?;
    render(result.operation);
    Ok(())
}

pub fn pair(data_dir: &Path, bootstrap: &str) -> Result<(), CliError> {
    let app = application(data_dir)?;
    let started = app.begin_pairing(bootstrap).map_err(cli_error)?;
    let session = started.value;
    render(started.operation);
    // A redirected CLI is commonly watched by another process while this
    // command waits for the administration device.
    std::io::stdout()
        .flush()
        .map_err(|error| CliError::FileSystem(format!("stdout: {error}")))?;
    let ready = app.await_pairing(bootstrap, session).map_err(cli_error)?;
    render(ready.operation);
    Ok(())
}

/// Answer a code an older device shows. Nothing is signed until the number
/// the new device shows is typed back here (ADR-012 §3).
pub fn pair_approve(data_dir: &Path, bootstrap: &str, code: &str) -> Result<(), CliError> {
    let app = application(data_dir)?;
    let result = app.approve_pairing(bootstrap, code).map_err(cli_error)?;
    render(result.operation);
    confirm(
        &app,
        &result.value.session_id,
        &result.value.verification_code,
    )
}

/// `arveil device link-offer --data-dir D`: show a link for a new device
/// (ADR-012 §3), wait for it to answer, and sign only after the person types
/// back the number both screens show.
pub fn link_offer(data_dir: &Path) -> Result<(), CliError> {
    let app = application(data_dir)?;
    let offer = app.offer_link().map_err(cli_error)?;
    render(offer.operation);
    let offer = offer.value;
    println!("link: {}", offer.link);
    if std::io::IsTerminal::is_terminal(&std::io::stdout())
        && let Some(qr) = arveil_app::qr::encode(&offer.link)
    {
        print!("{}", terminal_qr(&qr));
    }
    println!(
        "waiting: open or scan that link on the new device (it expires at {})",
        offer.expires_at
    );
    flush()?;
    let request = app.await_link_request(&offer.pair_id).map_err(cli_error)?;
    render(request.operation);
    confirm(&app, &offer.pair_id, &request.value.verification_code)
}

/// Read one line: the number typed back links the device, anything else
/// declines it.
fn confirm(app: &Application, pair_id: &[u8], expected: &str) -> Result<(), CliError> {
    println!("confirm: type the number the new device shows to link it, anything else declines");
    flush()?;
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|error| CliError::FileSystem(format!("stdin: {error}")))?;
    let digits = |s: &str| s.chars().filter(char::is_ascii_digit).collect::<String>();
    let approve = !digits(expected).is_empty() && digits(&line) == digits(expected);
    let result = app.answer_link(pair_id, approve).map_err(cli_error)?;
    render(result.operation);
    Ok(())
}

/// `arveil device link-join --data-dir D <link> [--scanned]`: answer a link
/// on a new device. `--scanned` says the link was read from the other
/// screen, which authenticates it; otherwise the number is confirmed with
/// `device pair-confirm` before the grant is applied.
pub fn link_join(data_dir: &Path, text: &str, scanned: bool) -> Result<(), CliError> {
    let app = application(data_dir)?;
    // The number arrives while the new device still waits for the other
    // one, which is when the person has to read it.
    let progress = app.watch();
    std::thread::spawn(move || {
        while let Some(event) = progress.recv() {
            if let arveil_app::ProgressKind::PairingVerification {
                verification_code,
                confirmation_required,
                ..
            } = event.kind
            {
                println!("verification code: {verification_code}");
                if confirmation_required {
                    println!(
                        "confirm with `arveil device pair-confirm --data-dir <dir> <bootstrap> {verification_code}` once the other device linked, only if it showed the same number"
                    );
                } else {
                    println!("waiting: confirm on the other device if it shows the same number");
                }
                let _ = std::io::stdout().flush();
            }
        }
    });
    let mut result = app
        .join_link(text, Some("CLI"), scanned)
        .map_err(cli_error)?;
    result
        .operation
        .changes
        .retain(|c| !matches!(c, arveil_app::StateChange::PairingVerificationReady { .. }));
    render(result.operation);
    Ok(())
}

fn flush() -> Result<(), CliError> {
    std::io::stdout()
        .flush()
        .map_err(|error| CliError::FileSystem(format!("stdout: {error}")))
}

/// Half blocks, black on white whatever the terminal's colours, with a
/// quiet zone of two modules.
fn terminal_qr(m: &arveil_app::qr::QrMatrix) -> String {
    let width = m.width as i64;
    let dark = |x: i64, y: i64| {
        (0..width).contains(&x) && (0..width).contains(&y) && m.dark[(y * width + x) as usize]
    };
    let mut out = String::new();
    for y in (-2..width + 2).step_by(2) {
        out.push_str("\x1b[30;47m");
        for x in -2..width + 2 {
            out.push(match (dark(x, y), dark(x, y + 1)) {
                (true, true) => '█',
                (true, false) => '▀',
                (false, true) => '▄',
                (false, false) => ' ',
            });
        }
        out.push_str("\x1b[0m\n");
    }
    out
}

pub fn pair_confirm(data_dir: &Path, bootstrap: &str, sas: &str) -> Result<(), CliError> {
    let app = application(data_dir)?;
    let pending = app
        .pending_pairing()
        .map_err(cli_error)?
        .ok_or_else(|| CliError::Domain("no pairing is waiting on this device".into()))?;
    let result = app
        .confirm_pairing(bootstrap, &pending.session_id, sas)
        .map_err(cli_error)?;
    render(result.operation);
    Ok(())
}

pub fn pair_cancel(data_dir: &Path, session_id: &str) -> Result<(), CliError> {
    let session_id = hex::decode(session_id)
        .map_err(|error| CliError::Domain(format!("pairing session id: {error}")))?;
    let result = application(data_dir)?
        .cancel_pairing(&session_id)
        .map_err(cli_error)?;
    render(result.operation);
    Ok(())
}
