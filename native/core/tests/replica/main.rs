//! The `Replica` contract over `LocalReplica` on real temp dirs: hello,
//! lock, the scan exchange, reads, the write path and its crash safety.
//! No mock replicas (plan D4).

mod child;
mod commit;
mod crash;
mod hello_lock;
mod read;
mod removal;
mod scan;
mod support;
mod torn;
mod write;
mod write_target;

/// Plays a role in a child process started by [`child::ChildProcess`];
/// passes as a no-op in an ordinary run.
#[test]
fn child_role() {
    let Some((role, path)) = child::child_role() else {
        return;
    };
    match role.as_str() {
        "tear-write" => torn::tear_write(&path),
        other => panic!("unknown role {other}"),
    }
}
