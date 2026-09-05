//! Thin CLI presentation for reusable enrollment and pairing services.

use std::io::Write;
use std::path::Path;

use arveil_app::Application;

use crate::carrier::CliError;
use crate::chat::{cli_error, render};

fn application(data_dir: &Path) -> Result<Application, CliError> {
    Application::open(data_dir).map_err(|error| CliError::FileSystem(error.to_string()))
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

pub fn pair_approve(data_dir: &Path, bootstrap: &str, code: &str) -> Result<(), CliError> {
    let result = application(data_dir)?
        .approve_pairing(bootstrap, code)
        .map_err(cli_error)?;
    render(result.operation);
    Ok(())
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
