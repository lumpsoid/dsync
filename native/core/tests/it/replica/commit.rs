//! `commit` and `compact`: batches through the archive store, an intent
//! durable before the call returns, and a failed batch reported as failed.

use std::fs;

use dsync_core::{Replica, ReplicaError};
use dsync_domain::{ArchiveCommit, Side};

use crate::replica::support::{Site, path, recorded, with_deadline};

fn upsert(relative: &str, content: &str) -> ArchiveCommit {
    ArchiveCommit::Upsert {
        path: path(relative),
        file: recorded(content),
    }
}

#[tokio::test]
async fn an_upsert_and_a_tombstone_land_in_order() {
    let site = Site::new();
    let replica = site.locked(Side::A).await;

    with_deadline("commits", async {
        replica
            .commit(vec![upsert("a.txt", "a"), upsert("b.txt", "b")])
            .await
            .unwrap();
        replica
            .commit(vec![ArchiveCommit::Delete(path("a.txt"))])
            .await
            .unwrap();
        replica.unlock().await.unwrap();
    })
    .await;

    let archive = site.archive(Side::A);
    assert_eq!(archive.get(&path("a.txt")), None);
    assert_eq!(archive.get(&path("b.txt")), Some(&recorded("b")));
}

#[tokio::test]
async fn a_batch_holding_an_intent_is_on_disk_when_the_call_returns() {
    let site = Site::new();
    let replica = site.locked(Side::A).await;

    with_deadline("upsert", replica.commit(vec![upsert("a.txt", "a")]))
        .await
        .unwrap();
    // Positive control: an upsert alone is buffered.
    assert_eq!(site.archive(Side::A).len(), 0);

    with_deadline(
        "intent",
        replica.commit(vec![ArchiveCommit::Intent(path("b.txt"))]),
    )
    .await
    .unwrap();

    // Read off disk with the replica still open and unflushed.
    let archive = site.archive(Side::A);
    assert!(archive.is_untrusted(&path("b.txt")));
    assert!(
        archive.get(&path("a.txt")).is_some(),
        "the batch before it too"
    );
}

#[tokio::test]
async fn compact_folds_the_log_to_one_line_per_path() {
    let site = Site::new();
    let replica = site.locked(Side::A).await;

    with_deadline("commits", async {
        replica.commit(vec![upsert("a.txt", "a")]).await.unwrap();
        replica.commit(vec![upsert("a.txt", "a")]).await.unwrap();
        replica.unlock().await.unwrap();
    })
    .await;
    assert_eq!(
        fs::read_to_string(site.log(Side::A))
            .unwrap()
            .lines()
            .count(),
        3
    );

    with_deadline("compact", async {
        replica.lock().await.unwrap();
        replica.compact().await.unwrap();
    })
    .await;

    // The header, and the one surviving upsert.
    assert_eq!(
        fs::read_to_string(site.log(Side::A))
            .unwrap()
            .lines()
            .count(),
        2
    );
}

#[cfg(unix)]
#[tokio::test]
async fn a_batch_that_cannot_be_made_durable_fails_and_earlier_batches_stand() {
    use crate::replica::support::set_mode;

    let site = Site::new();
    let replica = site.locked(Side::A).await;
    with_deadline("first batch", async {
        replica
            .commit(vec![ArchiveCommit::Intent(path("a.txt"))])
            .await
            .unwrap();
    })
    .await;
    let log = site.log(Side::A);
    set_mode(&log, 0o444);
    if fs::OpenOptions::new().append(true).open(&log).is_ok() {
        eprintln!("skipped: permission bits do not bind for this user (root?)");
        set_mode(&log, 0o644);
        return;
    }

    let failed = with_deadline(
        "failing batch",
        replica.commit(vec![
            upsert("a.txt", "a"),
            ArchiveCommit::Intent(path("b.txt")),
        ]),
    )
    .await;
    set_mode(&log, 0o644);

    assert!(
        matches!(failed, Err(ReplicaError::Archive(_))),
        "{failed:?}"
    );
    // What reached the disk is the earlier batch; the failed one's
    // commits are not durable, which is why the caller fails every action
    // in it.
    let on_disk = site.archive(Side::A);
    assert!(on_disk.is_untrusted(&path("a.txt")));
    assert!(on_disk.get(&path("a.txt")).is_none());
    assert!(!on_disk.is_untrusted(&path("b.txt")));
}
