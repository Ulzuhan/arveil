use std::process::Command;

use arveil_app::ProfileGuard;

#[test]
fn legacy_cli_commands_respect_the_profile_process_lock() {
    let profile =
        std::env::temp_dir().join(format!("arveil-cli-profile-lock-{}", std::process::id()));
    let guard = ProfileGuard::acquire(&profile).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_arveil"))
        .args(["status", "--data-dir"])
        .arg(&profile)
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("already in use by another process"));
    drop(guard);
    std::fs::remove_dir_all(profile).ok();
}
