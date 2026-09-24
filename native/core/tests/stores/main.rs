//! The durable stores in the state directory, against real temp dirs.

mod archive_inventory;
mod archive_store;
mod atomic_write;
mod identity_store;
mod paired_device_store;
mod profile_store;
mod replica_lock;
mod run_marker;
mod state_dirs;
mod support;

use dsync_core::ReplicaLock;
use dsync_core::atomic_write::stage;

use support::{READY, wait_for_parent};

/// Plays a role in a child process started by [`support::ChildProcess`];
/// passes as a no-op in an ordinary run.
#[test]
fn child_role() {
    let Some((role, path)) = support::child_role() else {
        return;
    };
    match role.as_str() {
        // Takes the real lock and holds it until released or killed.
        "hold-lock" => {
            let _lock = ReplicaLock::acquire(&path).unwrap();
            println!("{READY}");
            wait_for_parent();
        }
        // Writes a replacement for `path` and is killed before swapping it
        // in: the window between a compaction's temp write and its rename.
        "stage-then-die" => {
            let _staged = stage(&path, atomic_write::REPLACEMENT).unwrap();
            println!("{READY}");
            wait_for_parent();
            panic!("the parent kills this child before releasing it");
        }
        other => panic!("unknown role {other}"),
    }
}
