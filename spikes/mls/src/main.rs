//! Runs both spike baselines. The real evidence is in `cargo test`.

mod interop;
mod mlsrs_policy;
mod mlsrs_spike;
mod mlsrs_sqlite;
mod openmls_spike;
mod openmls_sqlite;

fn main() {
    let (epoch, plaintext) = openmls_spike::baseline();
    println!(
        "openmls 0.9  : epoch {epoch}, decrypted {:?}",
        String::from_utf8_lossy(&plaintext)
    );

    let (sender, adds, before, after) = openmls_spike::q2_reject_unauthorized_commit();
    println!(
        "openmls 0.9  : Q2 commit from leaf {sender} with {adds} add(s) rejected before merge; epoch {before} -> {after}"
    );

    match mlsrs_spike::baseline() {
        Ok((epoch, plaintext)) => println!(
            "mls-rs 0.56  : epoch {epoch}, decrypted {:?}",
            String::from_utf8_lossy(&plaintext)
        ),
        Err(e) => println!("mls-rs 0.56  : baseline failed: {e}"),
    }

    match mlsrs_spike::explicit_write_model() {
        Ok((before, after)) => {
            println!("mls-rs 0.56  : loadable before write_to_storage = {before}, after = {after}")
        }
        Err(e) => println!("mls-rs 0.56  : explicit write check failed: {e}"),
    }

    match mlsrs_sqlite::q1_shared_transaction() {
        Ok(o) => println!(
            "mls-rs 0.56  : Q1 (outbox rows, group rows, loadable) after rollback = {:?}, after commit = {:?}",
            o.after_rollback, o.after_commit
        ),
        Err(e) => println!("mls-rs 0.56  : Q1 failed: {e}"),
    }

    match mlsrs_policy::q2_reject_unauthorized_commit() {
        Ok(o) => println!(
            "mls-rs 0.56  : Q2 refused via MlsRules ({}); epoch {} -> {}; own commit -> {}; bob still reads = {}",
            o.rejection,
            o.epoch_before,
            o.epoch_after,
            o.epoch_after_own_commit,
            o.bob_reads_later_message
        ),
        Err(e) => println!("mls-rs 0.56  : Q2 failed: {e}"),
    }

    let o = openmls_sqlite::q1_shared_transaction();
    println!(
        "openmls 0.9  : Q1 (kv rows, outbox rows, loadable) before = {}, after rollback = {:?}, after commit = {:?}, loaded epoch = {:?}",
        o.kv_rows_before, o.after_rollback, o.after_commit, o.loaded_epoch
    );

    let o = interop::run();
    println!(
        "interop      : mls-rs(arveil-core) <-> openmls: read {:?} / {:?}; epochs {} / {}; openmls commit refused: {}",
        String::from_utf8_lossy(&o.openmls_read),
        String::from_utf8_lossy(&o.mlsrs_read),
        o.openmls_epoch,
        o.mlsrs_epoch,
        o.policy_rejection
    );
}
