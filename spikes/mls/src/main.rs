//! Runs both spike baselines. The real evidence is in `cargo test`.

mod mlsrs_spike;
mod mlsrs_sqlite;
mod openmls_spike;

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
}
