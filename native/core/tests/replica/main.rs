//! The `Replica` contract over `LocalReplica` on real temp dirs: hello,
//! lock, the scan exchange, reads, the write path and its crash safety -
//! and the same contract through `RemoteReplica` <-> `ReplicaServer`, with
//! the protocol and its transports. No mock replicas (plan D4).

mod child;
mod commit;
mod crash;
mod hello_lock;
mod pipelining;
mod read;
mod remote;
mod removal;
mod scan;
mod served;
#[cfg(unix)]
mod ssh;
mod support;
mod torn;
#[cfg(unix)]
mod unix;
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
