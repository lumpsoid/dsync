//! `hello`, `create_root`, `lock` and `unlock`.

use std::fs;

use std::path::Path;

use dsync_core::{LocalReplica, LockError, Replica, ReplicaError};
use dsync_domain::{ArchiveCommit, ReplicaRoot, RuleSet, Side, Tuning};

use crate::replica::child::{ChildProcess, READY, wait_for_parent};
use crate::replica::support::{OTHER_PROFILE, PROFILE, Site, path, recorded, with_deadline};

fn upsert(relative: &str) -> ArchiveCommit {
    ArchiveCommit::Upsert {
        path: path(relative),
        file: recorded("x"),
    }
}

#[tokio::test]
async fn hello_reports_no_last_commit_before_the_log_exists() {
    let site = Site::new();
    let replica = site.replica(Side::A);

    let info = with_deadline("hello", replica.hello()).await.unwrap();

    assert_eq!(info.last_commit, None);
    assert_eq!(info.root, ReplicaRoot::Present);
    assert_eq!(
        info.archive_path.as_deref(),
        Some(site.log(Side::A).to_str().unwrap())
    );
}

#[tokio::test]
async fn hello_reports_the_logs_mtime_once_a_commit_is_written() {
    let site = Site::new();
    let replica = site.replica(Side::A);
    with_deadline("commit", async {
        replica.commit(vec![upsert("a.txt")]).await.unwrap();
        replica.unlock().await.unwrap();
    })
    .await;
    let written = fs::metadata(site.log(Side::A)).unwrap().modified().unwrap();

    let info = with_deadline("hello", replica.hello()).await.unwrap();

    assert_eq!(info.last_commit, Some(written));
}

#[tokio::test]
async fn a_missing_root_is_reported_with_its_archived_count_until_created() {
    let site = Site::new();
    let replica = site.replica(Side::A);
    with_deadline("commit", async {
        replica
            .commit(vec![upsert("a.txt"), upsert("b.txt")])
            .await
            .unwrap();
    })
    .await;
    fs::remove_dir(site.root(Side::A)).unwrap();

    let missing = with_deadline("hello", replica.hello()).await.unwrap();
    assert_eq!(
        missing.root,
        ReplicaRoot::Missing {
            root_path: site.root(Side::A).to_str().unwrap().to_owned(),
            archived_files: 2,
        }
    );

    with_deadline("create_root", replica.create_root())
        .await
        .unwrap();
    let created = with_deadline("hello", replica.hello()).await.unwrap();
    assert_eq!(created.root, ReplicaRoot::Present);
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
pub fn assert_folder_in_use(result: Result<(), ReplicaError>, folder: &Path) {
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
