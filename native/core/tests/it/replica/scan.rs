//! `open_scan` and the exchange phases behind its tickets.

use std::fs;

use dsync_core::{Listing, Replica, ReplicaError};
use dsync_domain::{
    ArchiveCommit, BucketCount, FileMeta, FileState, RuleSet, Side, Status, Unchanged,
    temp_name_for,
};

use crate::replica::support::{Site, as_found, exchange, hash_of, path, seed, with_deadline};

#[tokio::test]
async fn a_new_file_is_created_against_an_empty_archive() {
    let site = Site::new();
    site.put(Side::A, "a.txt", "hello");
    let replica = site.locked(Side::A).await;

    let opened = with_deadline("scan", replica.open_scan(&RuleSet::default()))
        .await
        .unwrap();

    let entry = &opened.changed.entries[0];
    assert_eq!(entry.path, path("a.txt"));
    assert!(matches!(entry.status, Status::Created(_)));
}

#[tokio::test]
async fn a_rehash_that_confirms_the_content_refreshes_the_archive_keys() {
    let site = Site::new();
    site.put(Side::A, "a.txt", "hello");
    let real = site.state_of(Side::A, "a.txt");
    let drifted = FileState {
        meta: FileMeta {
            mtime_us: real.meta.mtime_us - 1_000_000,
            ..real.meta
        },
        hash: real.hash,
    };
    let replica = site.locked(Side::A).await;

    with_deadline("scan", async {
        replica
            .commit(vec![ArchiveCommit::Upsert {
                path: path("a.txt"),
                file: drifted,
            }])
            .await
            .unwrap();
        let _ = replica.open_scan(&RuleSet::default()).await.unwrap();
        replica.unlock().await.unwrap();
    })
    .await;

    // Without the write-back the fast path never matches again, and this
    // file is rehashed on every run (SPEC §5.2 step 2).
    assert_eq!(
        site.archive(Side::A)
            .get(&path("a.txt"))
            .copied()
            .map(as_found),
        Some(as_found(real))
    );
}

#[tokio::test]
async fn an_unchanged_file_whose_keys_match_writes_nothing() {
    let site = Site::new();
    site.put(Side::A, "a.txt", "hello");
    let replica = site.locked(Side::A).await;
    with_deadline("seed", seed(&replica)).await;
    let before = fs::read(site.log(Side::A)).unwrap();

    with_deadline("scan", async {
        let _ = replica.open_scan(&RuleSet::default()).await.unwrap();
        replica.unlock().await.unwrap();
    })
    .await;

    assert_eq!(fs::read(site.log(Side::A)).unwrap(), before);
}

#[tokio::test]
async fn a_scratch_file_from_a_crashed_write_is_not_scanned() {
    let site = Site::new();
    site.put(Side::A, "a.txt", "hello");
    site.put(Side::A, &temp_name_for("a.txt", 4242, 7), "half a file");
    let replica = site.locked(Side::A).await;

    let opened = with_deadline("scan", replica.open_scan(&RuleSet::default()))
        .await
        .unwrap();

    let paths: Vec<_> = opened.changed.entries.iter().map(|e| &e.path).collect();
    assert_eq!(paths, [&path("a.txt")]);
}

#[tokio::test]
async fn unchanged_entries_cross_only_where_the_digests_disagree() {
    let site = Site::new();
    for side in [Side::A, Side::B] {
        site.put(side, "same", "same on both");
    }
    let a = site.locked(Side::A).await;
    let b = site.locked(Side::B).await;
    with_deadline("seed", async {
        seed(&a).await;
        seed(&b).await;
    })
    .await;
    site.put(Side::A, "new", "only on a");

    let agreeing = with_deadline("exchange", exchange(&a, &b)).await;

    // Phase 1 carries `new`; `same` is proven equal by digest and never
    // crosses.
    assert!(matches!(
        agreeing.status(Side::A, "new"),
        Some(Status::Created(_))
    ));
    assert_eq!(agreeing.status(Side::A, "same"), None);
    assert_eq!(agreeing.status(Side::B, "same"), None);

    // Positive control: unchanged on both sides against each side's own
    // archive, yet not the same file. Its bucket disagrees, so phase 3
    // fetches it from both.
    site.put(Side::A, "differs", "a's own");
    site.put(Side::B, "differs", "b's own");
    with_deadline("seed", async {
        seed(&a).await;
        seed(&b).await;
    })
    .await;

    let disagreeing = with_deadline("exchange", exchange(&a, &b)).await;

    assert!(matches!(
        disagreeing.status(Side::A, "differs"),
        Some(Status::Unchanged {
            by: Unchanged::MetadataMatched,
            ..
        })
    ));
    assert_eq!(
        disagreeing
            .status(Side::B, "differs")
            .and_then(|s| s.file().copied())
            .map(|f| f.hash),
        Some(hash_of("b's own"))
    );
}

#[tokio::test]
async fn a_ticket_only_opens_the_phase_of_the_replica_that_issued_it() {
    let site = Site::new();
    let a = site.locked(Side::A).await;
    let b = site.locked(Side::B).await;

    with_deadline("scans", async {
        let opened = a.open_scan(&RuleSet::default()).await.unwrap();
        let count = BucketCount::for_entries(0);
        assert!(matches!(
            b.scan_digests(opened.next, count, Listing::from_vec(Vec::new()))
                .await,
            Err(ReplicaError::NoScan)
        ));
        // Positive control: the same step on the replica that scanned.
        let opened = a.open_scan(&RuleSet::default()).await.unwrap();
        let digested = a
            .scan_digests(opened.next, count, Listing::from_vec(Vec::new()))
            .await
            .unwrap();
        assert!(
            a.scan_buckets(&digested.next, &[])
                .await
                .unwrap()
                .is_empty()
        );
    })
    .await;
}
