//! `hello`, `create_root`, `lock` and `unlock`.

use std::fs;

use std::path::Path;

use dsync_core::{LocalReplica, LockError, Replica, ReplicaError};
use dsync_domain::{ArchiveCommit, ArchiveFacts, ReplicaRoot, RuleSet, Side, Tuning};

use crate::replica::child::{ChildProcess, READY, wait_for_parent};
use crate::replica::support::{OTHER_PROFILE, PROFILE, Site, path, recorded, with_deadline};

fn upsert(relative: &str) -> ArchiveCommit {
    ArchiveCommit::Upsert {
        path: path(relative),
        file: recorded("x"),
    }
}

#[tokio::test]
async fn hello_reports_the_root_and_where_the_archive_lives() {
    let site = Site::new();
    let replica = site.replica(Side::A);

    let root = with_deadline("hello", replica.hello()).await.unwrap();

    assert_eq!(root.root, ReplicaRoot::Present);
    assert_eq!(
        root.archive_path.as_deref(),
        Some(site.log(Side::A).to_str().unwrap())
    );
}

#[tokio::test]
async fn lock_reports_no_last_commit_before_the_log_exists() {
    let site = Site::new();
    let replica = site.replica(Side::A);

    let archive = with_deadline("lock", replica.lock()).await.unwrap();

    assert_eq!(
        archive,
        ArchiveFacts {
            last_commit: None,
            archived_files: 0,
        }
    );
}

#[tokio::test]
async fn lock_reports_the_logs_mtime_and_count_once_a_commit_is_written() {
    let site = Site::new();
    let replica = site.replica(Side::A);
    with_deadline("commit", async {
        replica.lock().await.unwrap();
        replica.commit(vec![upsert("a.txt")]).await.unwrap();
        replica.unlock().await.unwrap();
    })
    .await;
    let written = fs::metadata(site.log(Side::A)).unwrap().modified().unwrap();

    let archive = with_deadline("lock", replica.lock()).await.unwrap();

    assert_eq!(
        archive,
        ArchiveFacts {
            last_commit: Some(written),
            archived_files: 1,
        }
    );
}

#[tokio::test]
async fn a_missing_root_is_reported_by_hello_and_its_archived_count_by_lock() {
    let site = Site::new();
    let replica = site.replica(Side::A);
    with_deadline("commit", async {
        replica.lock().await.unwrap();
        replica
            .commit(vec![upsert("a.txt"), upsert("b.txt")])
            .await
            .unwrap();
        replica.unlock().await.unwrap();
    })
    .await;
    fs::remove_dir(site.root(Side::A)).unwrap();

    let missing = with_deadline("hello", replica.hello()).await.unwrap();
    assert_eq!(
        missing.root,
        ReplicaRoot::Missing {
            root_path: site.root(Side::A).to_str().unwrap().to_owned(),
        }
    );
    let archive = with_deadline("lock", replica.lock()).await.unwrap();
    assert_eq!(archive.archived_files, 2);

    with_deadline("create_root", replica.create_root())
        .await
        .unwrap();
    let created = with_deadline("hello", replica.hello()).await.unwrap();
    assert_eq!(created.root, ReplicaRoot::Present);
}

fn not_locked<T: std::fmt::Debug>(result: Result<T, ReplicaError>) -> bool {
    matches!(result, Err(ReplicaError::NotLocked))
}

#[tokio::test]
async fn the_archive_is_refused_to_a_replica_that_does_not_hold_its_lock() {
    let site = Site::new();
    site.put(Side::A, "a.txt", "a");
    let replica = site.replica(Side::A);

    with_deadline("unlocked", async {
        assert!(not_locked(replica.open_scan(&RuleSet::default()).await));
        assert!(not_locked(replica.commit(vec![upsert("a.txt")]).await));
        assert!(not_locked(replica.compact().await));
    })
    .await;
    assert!(!site.log(Side::A).exists(), "an unlocked commit landed");

    // Positive control: under the lock each is served.
    with_deadline("locked", async {
        replica.lock().await.unwrap();
        let _ = replica.open_scan(&RuleSet::default()).await.unwrap();
        replica.commit(vec![upsert("a.txt")]).await.unwrap();
        replica.compact().await.unwrap();
        replica.unlock().await.unwrap();
    })
    .await;

    // Unlocking gives up the archive with the lock.
    with_deadline("unlocked again", async {
        assert!(not_locked(replica.open_scan(&RuleSet::default()).await));
        assert!(not_locked(replica.commit(vec![upsert("a.txt")]).await));
        assert!(not_locked(replica.compact().await));
    })
    .await;
}

#[tokio::test]
async fn only_the_lock_reads_the_archive() {
    let site = Site::new();
    fs::create_dir_all(site.log(Side::A).parent().unwrap()).unwrap();
    fs::write(site.log(Side::A), "not an archive\n").unwrap();
    let replica = site.replica(Side::A);

    // Opening and `hello` read nothing of it, so neither sees it is
    // corrupt; the lock is the first to.
    with_deadline("hello", replica.hello()).await.unwrap();
    let refused = with_deadline("lock", replica.lock()).await;
    assert!(
        matches!(refused, Err(ReplicaError::Archive(_))),
        "{refused:?}"
    );
    // The refused archive gave its lock back.
    let other = site.replica(Side::A);
    fs::remove_file(site.log(Side::A)).unwrap();
    with_deadline("lock", other.lock()).await.unwrap();
}

#[tokio::test]
async fn a_session_reads_its_archive_once_at_the_lock() {
    let site = Site::new();
    site.put(Side::A, "a.txt", "hello");
    let earlier = site.replica(Side::A);
    with_deadline("an earlier run", async {
        earlier.lock().await.unwrap();
        earlier
            .commit(vec![ArchiveCommit::Upsert {
                path: path("a.txt"),
                file: site.state_of(Side::A, "a.txt"),
            }])
            .await
            .unwrap();
        earlier.unlock().await.unwrap();
    })
    .await;
    let replica = site.replica(Side::A);

    let opened = with_deadline("hello, lock, scan", async {
        replica.hello().await.unwrap();
        replica.lock().await.unwrap();
        // Gone from disk after the lock: a scan that read the log again
        // would find nothing archived and report a.txt created.
        fs::remove_file(site.log(Side::A)).unwrap();
        replica.open_scan(&RuleSet::default()).await.unwrap()
    })
    .await;

    assert!(opened.changed.entries.is_empty(), "{:?}", opened.changed);
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_held_lock_refuses_the_next_run_until_unlocked() {
    let site = Site::new();
    let first = site.replica(Side::A);
    let second = site.replica(Side::A);
    let other_side = site.replica(Side::B);

    with_deadline("locks", async {
        first.lock().await.unwrap();
        assert!(matches!(
            second.lock().await,
            Err(ReplicaError::Lock(LockError::Held { .. }))
        ));
        // Positive control: the refusal is about this replica's lock.
        other_side.lock().await.unwrap();

        first.unlock().await.unwrap();
        second.lock().await.unwrap();
        second.unlock().await.unwrap();
        other_side.unlock().await.unwrap();
    })
    .await;
}

#[tokio::test]
async fn unlock_makes_buffered_commits_durable_first() {
    let site = Site::new();
    let replica = site.replica(Side::A);

    with_deadline("lock and commit", async {
        replica.lock().await.unwrap();
        replica.commit(vec![upsert("a.txt")]).await.unwrap();
    })
    .await;
    // Batched: not on disk yet.
    assert_eq!(site.archive(Side::A).len(), 0);

    with_deadline("unlock", replica.unlock()).await.unwrap();

    assert!(site.archive(Side::A).get(&path("a.txt")).is_some());
}

#[tokio::test]
async fn lock_replays_what_another_run_committed_since_the_replica_opened() {
    let site = Site::new();
    site.put(Side::A, "a.txt", "hello");
    let late = site.replica(Side::A);
    let earlier = site.replica(Side::A);

    let opened = with_deadline("runs", async {
        earlier.lock().await.unwrap();
        earlier
            .commit(vec![ArchiveCommit::Upsert {
                path: path("a.txt"),
                file: site.state_of(Side::A, "a.txt"),
            }])
            .await
            .unwrap();
        earlier.unlock().await.unwrap();

        late.lock().await.unwrap();
        let opened = late.open_scan(&RuleSet::default()).await.unwrap();
        late.unlock().await.unwrap();
        opened
    })
    .await;

    // Scanned against the archive as the earlier run left it, not as it
    // was when `late` was opened: nothing changed.
    assert!(opened.changed.entries.is_empty(), "{:?}", opened.changed);
}

/// Asserts `result` is the refusal of a folder in use, naming `folder`.
pub fn assert_folder_in_use(result: Result<ArchiveFacts, ReplicaError>, folder: &Path) {
    let folder = std::fs::canonicalize(folder).unwrap();
    assert!(
        matches!(&result, Err(ReplicaError::Lock(LockError::FolderInUse { folder: named, .. }))
            if named == &folder),
        "{result:?}"
    );
}

fn under(site: &Site, root: &Path, profile: &str) -> LocalReplica {
    site.replica_at(root, profile, Side::A, Tuning::DEFAULT)
}

#[tokio::test]
async fn the_same_folder_under_another_profile_is_refused_until_unlocked() {
    let site = Site::new();
    let root = site.root(Side::A);
    let first = under(&site, &root, PROFILE);
    let second = under(&site, &root, OTHER_PROFILE);

    with_deadline("locks", async {
        first.lock().await.unwrap();
        assert_folder_in_use(second.lock().await, &root);

        first.unlock().await.unwrap();
        second.lock().await.unwrap();
        second.unlock().await.unwrap();
    })
    .await;
}

#[tokio::test]
async fn different_folders_under_different_profiles_do_not_contend() {
    let site = Site::new();
    let first = under(&site, &site.root(Side::A), PROFILE);
    let second = under(&site, &site.root(Side::B), OTHER_PROFILE);

    with_deadline("locks", async {
        first.lock().await.unwrap();
        second.lock().await.unwrap();
        first.unlock().await.unwrap();
        second.unlock().await.unwrap();
    })
    .await;
}

#[tokio::test]
async fn a_root_not_created_yet_is_locked_as_the_folder_it_becomes() {
    let site = Site::new();
    let fresh = site.root(Side::A).join("not/yet");
    let first = under(&site, &fresh, PROFILE);

    with_deadline("lock and create", async {
        first.lock().await.unwrap();
        first.create_root().await.unwrap();
    })
    .await;
    assert!(fresh.is_dir());

    // Keyed the same before and after it existed: another profile's run
    // on the folder the first run created is still refused.
    let second = under(&site, &fresh, OTHER_PROFILE);
    with_deadline("contended lock", async {
        assert_folder_in_use(second.lock().await, &fresh);
        first.unlock().await.unwrap();
        second.lock().await.unwrap();
        second.unlock().await.unwrap();
    })
    .await;
}

#[test]
fn a_killed_holder_releases_the_folder() {
    let site = Site::new();
    let mut holder = ChildProcess::spawn("hold-folder", site.dir());
    holder.wait_until_ready();
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let replica = site.replica(Side::A);
    assert_folder_in_use(
        runtime.block_on(with_deadline("contended lock", replica.lock())),
        &site.root(Side::A),
    );

    holder.kill();
    holder.wait();

    runtime
        .block_on(with_deadline("lock", replica.lock()))
        .unwrap();
}

/// The child's side of [`a_killed_holder_releases_the_folder`]: side A's
/// folder locked under [`OTHER_PROFILE`], held until killed.
pub fn hold_folder(dir: &Path) {
    let site = Site::at(dir);
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let replica = under(&site, &site.root(Side::A), OTHER_PROFILE);
    runtime.block_on(replica.lock()).unwrap();
    println!("{READY}");
    wait_for_parent();
}
