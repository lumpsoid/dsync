//! The `Replica` contract through `RemoteReplica` <-> `ReplicaServer` over
//! a duplex connection, against a real `LocalReplica` on the far side: the
//! cases of `protocol_round_trip_test.dart`, `remote_agent_test.dart` and
//! `agent_server_test.dart` that are not about metrics.

use std::io;

use dsync_core::{Body, FileOp, LockError, Replica, ReplicaError, Stage, body_channel};
use dsync_domain::{
    ArchiveCommit, BucketCount, Glob, Precondition, ProfileId, ReplicaRoot, RuleSet, Side, Status,
};

use crate::served::Served;
use crate::support::{
    PROFILE, Site, apply, exchange, failing_body, meta, path, recorded, with_deadline,
};

#[tokio::test]
async fn a_scan_write_and_commit_round_trip_lands_both_sides_in_sync() {
    let site = Site::new();
    site.put(Side::A, "top.txt", "top");
    site.put(Side::A, "deep/er/file.bin", vec![7u8; 300_000]);
    site.put(Side::B, "only-b.txt", "b");
    let a = site.replica(Side::A);
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    with_deadline("lock", b.lock()).await.unwrap();

    let exchanged = with_deadline("exchange", exchange(&a, b)).await;
    assert_eq!(exchanged.plan.actions.len(), 3);
    with_deadline("apply", apply(&a, b, &exchanged)).await;

    assert_eq!(site.get(Side::B, "top.txt"), b"top");
    assert_eq!(site.get(Side::B, "deep/er/file.bin"), vec![7u8; 300_000]);
    assert_eq!(site.get(Side::A, "only-b.txt"), b"b");
    for relative in ["top.txt", "deep/er/file.bin", "only-b.txt"] {
        assert_eq!(
            site.archive(Side::B).get(&path(relative)),
            Some(&site.state_of(Side::B, relative)),
            "{relative} archived on the far side"
        );
    }
    // The next run over the wire finds nothing to do.
    let again = with_deadline("second exchange", exchange(&a, b)).await;
    assert!(again.plan.actions.is_empty(), "{:?}", again.plan.actions);
    served.close().await;
}

#[tokio::test]
async fn hello_reports_the_far_sides_replica_and_create_root_makes_a_missing_one() {
    let site = Site::new();
    std::fs::remove_dir(site.root(Side::B)).unwrap();
    let served = Served::new(&site, Side::B).await;
    let info = with_deadline("hello", served.replica.hello())
        .await
        .unwrap();
    assert!(matches!(
        info.root,
        ReplicaRoot::Missing {
            archived_files: 0,
            ..
        }
    ));
    assert_eq!(info.last_commit, None);
    assert_eq!(
        info.archive_path,
        Some(site.log(Side::B).display().to_string())
    );
    with_deadline("create_root", served.replica.create_root())
        .await
        .unwrap();
    assert!(site.root(Side::B).is_dir());
    served.close().await;
}

#[tokio::test]
async fn a_request_before_hello_is_refused() {
    let site = Site::new();
    let served = Served::new(&site, Side::B).await;
    let refused = with_deadline("lock", served.replica.lock()).await;
    assert!(
        matches!(&refused, Err(ReplicaError::Refused(why)) if why.contains("hello")),
        "{refused:?}"
    );
    // The session is over, and nothing took the lock.
    with_deadline("the session's end", served.serving)
        .await
        .unwrap()
        .unwrap();
    with_deadline("local lock", site.replica(Side::B).lock())
        .await
        .unwrap();
}

#[tokio::test]
async fn lock_and_unlock_take_and_release_the_real_lock() {
    let site = Site::new();
    let served = Served::new(&site, Side::B).await;
    with_deadline("hello", served.replica.hello())
        .await
        .unwrap();
    with_deadline("lock", served.replica.lock()).await.unwrap();
    let local = site.replica(Side::B);
    assert!(matches!(
        with_deadline("contended lock", local.lock()).await,
        Err(ReplicaError::Lock(LockError::Held { .. }))
    ));
    with_deadline("unlock", served.replica.unlock())
        .await
        .unwrap();
    with_deadline("local lock", local.lock()).await.unwrap();
    served.close().await;
}

#[tokio::test]
async fn a_lock_held_on_the_far_side_comes_back_as_held() {
    let site = Site::new();
    let local = site.replica(Side::B);
    with_deadline("local lock", local.lock()).await.unwrap();
    let served = Served::new(&site, Side::B).await;
    with_deadline("hello", served.replica.hello())
        .await
        .unwrap();
    let refused = with_deadline("remote lock", served.replica.lock()).await;
    assert!(
        matches!(&refused, Err(ReplicaError::Lock(LockError::Held { path })) if path == &site.state().lock(&ProfileId::parse(PROFILE).unwrap(), Side::B)),
        "{refused:?}"
    );
    served.close().await;
}

#[tokio::test]
async fn the_lock_is_released_when_the_connection_drops_mid_run() {
    let site = Site::new();
    site.put(Side::B, "f", "x");
    let served = Served::new(&site, Side::B).await;
    with_deadline("hello", served.replica.hello())
        .await
        .unwrap();
    with_deadline("lock", served.replica.lock()).await.unwrap();
    with_deadline(
        "commit",
        served
            .replica
            .commit(vec![ArchiveCommit::Intent(path("f"))]),
    )
    .await
    .unwrap();
    let local = site.replica(Side::B);
    assert!(
        with_deadline("contended lock", local.lock()).await.is_err(),
        "the remote session holds the lock"
    );

    // No unlock: the client just goes away.
    drop(served.replica);
    with_deadline("the session's end", served.serving)
        .await
        .unwrap()
        .unwrap();
    with_deadline("local lock", local.lock()).await.unwrap();
    // What it committed before it went is there for the next holder.
    assert!(site.archive(Side::B).is_untrusted(&path("f")));
}

#[tokio::test]
async fn the_scan_applies_the_initiators_rules_on_the_far_side() {
    let site = Site::new();
    site.put(Side::B, "keep.txt", "k");
    site.put(Side::B, "build/out.o", "o");
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    let rules = RuleSet::new(vec![Glob::new("build").unwrap()], vec![]);
    let opened = with_deadline("open_scan", b.open_scan(&rules))
        .await
        .unwrap();
    let paths: Vec<_> = opened
        .changed
        .entries
        .iter()
        .map(|entry| entry.path.as_str())
        .collect();
    assert_eq!(paths, ["keep.txt"]);
    served.close().await;
}

#[tokio::test]
async fn read_streams_the_current_bytes_and_a_missing_file_fails_as_the_local_one_does() {
    let site = Site::new();
    let content: Vec<u8> = (0..1_000_000u32).map(|n| n as u8).collect();
    site.put(Side::B, "big", &content);
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    let body = with_deadline("read", b.read(&path("big")))
        .await
        .unwrap()
        .body;
    assert_eq!(
        with_deadline("collect", body.collect()).await.unwrap(),
        content
    );

    let missing = with_deadline("read", b.read(&path("missing"))).await;
    let Err(ReplicaError::File {
        op,
        path: at,
        source,
    }) = missing
    else {
        panic!("not a file error: {:?}", missing.map(|_| ()));
    };
    assert_eq!(op, FileOp::Read);
    assert_eq!(at, site.file(Side::B, "missing"));
    assert_eq!(source.kind(), io::ErrorKind::NotFound);
    served.close().await;
}

#[tokio::test]
async fn write_lands_through_the_wire_and_returns_what_landed() {
    let site = Site::new();
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    let content = vec![5u8; 700_000];
    let landed = with_deadline(
        "write",
        b.write(
            &path("d/w.bin"),
            Body::from_bytes(content.clone()),
            meta(0o600),
            Precondition::Absent,
        ),
    )
    .await
    .unwrap();
    assert_eq!(site.get(Side::B, "d/w.bin"), content);
    assert_eq!(landed, site.state_of(Side::B, "d/w.bin").meta);
    served.close().await;
}

#[tokio::test]
async fn a_failed_write_leaves_the_session_usable() {
    let site = Site::new();
    site.put(Side::B, "file", "not a folder");
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();

    // Answered early, with most of a large body still to send: the client
    // stops sending and the server drains what was in flight.
    let refused = with_deadline(
        "write under a file",
        b.write(
            &path("file/x"),
            Body::from_bytes(vec![1; 3_000_000]),
            meta(0o644),
            Precondition::Absent,
        ),
    )
    .await;
    let Err(ReplicaError::Write(error)) = refused else {
        panic!("not a write error: {refused:?}");
    };
    assert_eq!(error.path, path("file/x"));
    assert_eq!(error.stage, Stage::Mkdir);

    // A body that fails part-way fails the write, never lands as short.
    let torn = with_deadline(
        "write of a failing body",
        b.write(
            &path("torn"),
            failing_body(b"half").await,
            meta(0o644),
            Precondition::Absent,
        ),
    )
    .await;
    assert!(matches!(torn, Err(ReplicaError::Write(_))), "{torn:?}");

    // A body whose source goes away unfinished is cut short, not short.
    let (sender, body) = body_channel(2);
    sender.send(b"partial".to_vec()).await.unwrap();
    drop(sender);
    let cut = with_deadline(
        "write of a cut body",
        b.write(&path("cut"), body, meta(0o644), Precondition::Absent),
    )
    .await;
    assert!(matches!(cut, Err(ReplicaError::Write(_))), "{cut:?}");

    // And the session carries on.
    with_deadline(
        "write after the failures",
        b.write(
            &path("ok"),
            Body::from_bytes(b"fine".to_vec()),
            meta(0o644),
            Precondition::Absent,
        ),
    )
    .await
    .unwrap();
    assert_eq!(site.get(Side::B, "ok"), b"fine");
    served.close().await;
}

#[tokio::test]
async fn delete_and_remove_empty_dirs_reach_the_real_tree() {
    let site = Site::new();
    site.put(Side::B, "a/b/f", "x");
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    let expect = site.expect(Side::B, "a/b/f");
    with_deadline("delete", b.delete(&path("a/b/f"), expect))
        .await
        .unwrap();
    with_deadline("remove_empty_dirs", b.remove_empty_dirs(&path("a/b/f")))
        .await
        .unwrap();
    assert!(!site.file(Side::B, "a").exists());
    assert!(site.root(Side::B).is_dir());
    served.close().await;
}

#[tokio::test]
async fn commits_persist_through_the_real_archive() {
    let site = Site::new();
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    with_deadline("lock", b.lock()).await.unwrap();
    with_deadline(
        "commit",
        b.commit(vec![
            ArchiveCommit::Upsert {
                path: path("u"),
                file: recorded("u"),
            },
            ArchiveCommit::Upsert {
                path: path("gone"),
                file: recorded("g"),
            },
            ArchiveCommit::Delete(path("gone")),
            ArchiveCommit::Intent(path("marked")),
            ArchiveCommit::Intent(path("withdrawn")),
        ]),
    )
    .await
    .unwrap();
    // A mark is durable when the call returns, without an unlock.
    let archive = site.archive(Side::B);
    assert!(archive.is_untrusted(&path("marked")));
    with_deadline(
        "withdraw",
        b.commit(vec![ArchiveCommit::Withdraw(path("withdrawn"))]),
    )
    .await
    .unwrap();
    with_deadline("unlock", b.unlock()).await.unwrap();
    with_deadline("compact", b.compact()).await.unwrap();

    let archive = site.archive(Side::B);
    assert_eq!(archive.get(&path("u")), Some(&recorded("u")));
    assert_eq!(archive.get(&path("gone")), None);
    assert!(archive.is_untrusted(&path("marked")));
    assert!(!archive.is_untrusted(&path("withdrawn")));
    served.close().await;
}

#[tokio::test]
async fn scan_tickets_are_checked_on_the_far_side() {
    let site = Site::new();
    site.put(Side::B, "f", "x");
    let local = site.replica(Side::A);
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    // A ticket another replica issued names no exchange open over there.
    let foreign = with_deadline("local scan", local.open_scan(&RuleSet::default()))
        .await
        .unwrap();
    let count = BucketCount::for_entries(1);
    let refused = with_deadline("digests", b.scan_digests(foreign.next, count, &[])).await;
    assert!(matches!(refused, Err(ReplicaError::NoScan)), "{refused:?}");
    // Its own exchange runs.
    let opened = with_deadline("open_scan", b.open_scan(&RuleSet::default()))
        .await
        .unwrap();
    assert!(matches!(
        opened.changed.entries[0].status,
        Status::Created(_)
    ));
    let digested = with_deadline("digests", b.scan_digests(opened.next, count, &[]))
        .await
        .unwrap();
    assert_eq!(digested.digests.as_slice().len(), 1);
    served.close().await;
}
