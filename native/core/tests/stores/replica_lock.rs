//! The cases of `test/dsync_core/lock/replica_lock_test.dart` and
//! `replica_lock_unclean_stop_characterization_test.dart`.
//!
//! Dart's "release is a no-op when acquire was never called" has no port:
//! a `ReplicaLock` exists only once acquired, and releasing is dropping it.

use std::path::PathBuf;

use dsync_core::{LockError, ReplicaLock};
use tempfile::TempDir;

use crate::support::ChildProcess;

fn lock_file(dir: &TempDir) -> PathBuf {
    dir.path().join("replica.lock")
}

fn assert_held(result: Result<ReplicaLock, LockError>) {
    match result {
        Err(LockError::Held { .. }) => {}
        other => panic!("expected the lock to be held, got {other:?}"),
    }
}

#[test]
fn creates_the_lock_file_and_succeeds_when_nothing_holds_it() {
    let dir = tempfile::tempdir().unwrap();
    let lock = ReplicaLock::acquire(&lock_file(&dir)).unwrap();
    assert!(lock_file(&dir).exists());
    assert_eq!(lock.path(), lock_file(&dir));
}

#[test]
fn creates_the_state_directory_too() {
    let dir = tempfile::tempdir().unwrap();
    let nested = dir.path().join("state/dsync/p-a.lock");
    let _lock = ReplicaLock::acquire(&nested).unwrap();
    assert!(nested.exists());
}

#[test]
fn is_refused_while_this_process_already_holds_it() {
    let dir = tempfile::tempdir().unwrap();
    let _held = ReplicaLock::acquire(&lock_file(&dir)).unwrap();
    assert_held(ReplicaLock::acquire(&lock_file(&dir)));
}

#[test]
fn holds_against_a_second_spelling_of_the_same_path() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("sub")).unwrap();
    let _held = ReplicaLock::acquire(&lock_file(&dir)).unwrap();
    assert_held(ReplicaLock::acquire(
        &dir.path().join("sub/../replica.lock"),
    ));
    assert_held(ReplicaLock::acquire(&dir.path().join("./replica.lock")));
}

#[test]
fn a_release_frees_it_for_the_next_holder_in_this_process() {
    let dir = tempfile::tempdir().unwrap();
    drop(ReplicaLock::acquire(&lock_file(&dir)).unwrap());
    drop(ReplicaLock::acquire(&lock_file(&dir)).unwrap());
}

#[test]
fn a_refused_acquire_leaves_the_lock_to_its_holder() {
    let dir = tempfile::tempdir().unwrap();
    let held = ReplicaLock::acquire(&lock_file(&dir)).unwrap();
    assert_held(ReplicaLock::acquire(&lock_file(&dir)));

    // The refusal claimed nothing and released nothing: the holder still
    // holds it, and dropping the holder is what frees it.
    assert_held(ReplicaLock::acquire(&lock_file(&dir)));
    drop(held);
    ReplicaLock::acquire(&lock_file(&dir)).unwrap();
}

#[test]
fn locks_on_different_paths_are_independent() {
    let dir = tempfile::tempdir().unwrap();
    let _a = ReplicaLock::acquire(&dir.path().join("p-a.lock")).unwrap();
    let _b = ReplicaLock::acquire(&dir.path().join("p-b.lock")).unwrap();
}

#[test]
fn is_refused_while_another_process_holds_it_and_free_once_it_lets_go() {
    let dir = tempfile::tempdir().unwrap();
    let mut holder = ChildProcess::spawn("hold-lock", &lock_file(&dir));
    holder.wait_until_ready();

    assert_held(ReplicaLock::acquire(&lock_file(&dir)));

    holder.release();
    assert!(holder.wait().success());
    ReplicaLock::acquire(&lock_file(&dir)).unwrap();
}

#[test]
fn a_killed_holder_releases_it_and_its_leftover_file_is_no_obstacle() {
    let dir = tempfile::tempdir().unwrap();
    let mut holder = ChildProcess::spawn("hold-lock", &lock_file(&dir));
    holder.wait_until_ready();
    assert_held(ReplicaLock::acquire(&lock_file(&dir)));

    holder.kill();
    holder.wait();

    // The file outlives the holder; the kernel's lock did not.
    assert!(lock_file(&dir).exists());
    ReplicaLock::acquire(&lock_file(&dir)).unwrap();
}
