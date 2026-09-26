//! The one atomic-write helper: temp, fsync, rename, directory fsync.

use std::fs;

use dsync_core::atomic_write::{DirSync, stage, write_atomically};
use dsync_core::{ArchiveHeader, ArchiveInventory, ArchiveStore, StateDir};
use dsync_domain::{Side, Tuning, is_temp_file_name};

use crate::support::{ChildProcess, file, names_in, path, profile, upsert};

/// What the `stage-then-die` child stages over the log.
pub const REPLACEMENT: &[u8] = b"replacement that must never be swapped in\n";

#[test]
fn replaces_the_whole_file_and_leaves_no_temp() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("paired-devices.json");
    fs::write(&target, "old").unwrap();

    write_atomically(&target, b"new").unwrap();

    assert_eq!(fs::read_to_string(&target).unwrap(), "new");
    assert_eq!(names_in(dir.path()), ["paired-devices.json"]);
}

#[test]
fn creates_the_file_and_its_directory() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("state/identity.crt");

    write_atomically(&target, b"pem").unwrap();

    assert_eq!(fs::read_to_string(&target).unwrap(), "pem");
}

/// The directory is fsynced after the rename. There is no seam to count
/// the syscall without a mock; the helper reports which path it took, and
/// on unix that is the one that opened and synced the directory.
#[test]
fn the_directory_is_synced_after_the_rename_where_the_platform_can() {
    let dir = tempfile::tempdir().unwrap();
    let synced = write_atomically(&dir.path().join("f"), b"x").unwrap();
    let expected = if cfg!(unix) {
        DirSync::Synced
    } else {
        DirSync::Unsupported
    };
    assert_eq!(synced, expected);
}

#[test]
fn a_staged_file_dropped_uncommitted_leaves_the_target_and_no_temp() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("f");
    fs::write(&target, "old").unwrap();

    let staged = stage(&target, b"new").unwrap();
    let temp = staged.temp_path().to_owned();
    assert_eq!(fs::read_to_string(&temp).unwrap(), "new");
    assert!(is_temp_file_name(
        temp.file_name().unwrap().to_str().unwrap()
    ));
    assert_eq!(fs::read_to_string(&target).unwrap(), "old");
    drop(staged);

    assert_eq!(names_in(dir.path()), ["f"]);
}

/// A process killed between writing a compaction's replacement and
/// renaming it over the log: the old log is intact, still opens, still
/// lists, and a later compaction goes through.
#[test]
fn a_kill_between_the_temp_write_and_the_rename_leaves_the_old_log_intact() {
    let dir = tempfile::tempdir().unwrap();
    let state = StateDir::new(dir.path());
    let log = state.archive_log(&profile(), Side::A);
    let header = ArchiveHeader {
        entry_id: profile(),
        root_path: "/home/me/notes".into(),
    };
    let mut store = ArchiveStore::open(log.clone(), header.clone(), &Tuning::DEFAULT).unwrap();
    store
        .commit([upsert("a.txt", file(10, 1)), upsert("a.txt", file(99, 9))])
        .unwrap();
    drop(store);
    let before = fs::read(&log).unwrap();

    let mut child = ChildProcess::spawn("stage-then-die", &log);
    child.wait_until_ready();
    child.kill();
    child.wait();

    // The replacement reached the disk beside the log, and never replaced it.
    let temps: Vec<String> = names_in(dir.path())
        .into_iter()
        .filter(|name| is_temp_file_name(name))
        .collect();
    assert_eq!(temps.len(), 1, "{:?}", names_in(dir.path()));
    assert_eq!(fs::read(dir.path().join(&temps[0])).unwrap(), REPLACEMENT);
    assert_eq!(fs::read(&log).unwrap(), before);

    let mut reopened = ArchiveStore::open(log.clone(), header, &Tuning::DEFAULT).unwrap();
    assert_eq!(reopened.archive().get(&path("a.txt")), Some(&file(99, 9)));
    let listed = ArchiveInventory::new(state).list().unwrap();
    assert_eq!(listed.len(), 1, "the leftover temp is not an archive");

    reopened.compact().unwrap();
    assert_eq!(fs::read_to_string(&log).unwrap().lines().count(), 2);
}
