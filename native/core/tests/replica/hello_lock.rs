//! `hello`, `create_root`, `lock` and `unlock`.

use std::fs;

use dsync_core::{LockError, Replica, ReplicaError};
use dsync_domain::{ArchiveCommit, ReplicaRoot, RuleSet, Side};

use crate::support::{Site, path, recorded, with_deadline};

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
