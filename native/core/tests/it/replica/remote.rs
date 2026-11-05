//! The `Replica` contract through `RemoteReplica` <-> `ReplicaServer` over
//! a duplex connection, against a real `LocalReplica` on the far side: the
//! cases of `protocol_round_trip_test.dart`, `remote_agent_test.dart` and
//! `agent_server_test.dart` that are not about metrics.

use std::io;
use std::sync::atomic::Ordering;

use dsync_core::{Body, FileOp, Listing, LockError, Replica, ReplicaError, Stage, body_channel};
use dsync_domain::{
    ArchiveCommit, ArchiveFacts, BucketCount, EntryId, Glob, LockFacts, Precondition, ReplicaRoot,
    RuleSet, Side, SpoolSetting, Status, Tuning,
};

use crate::replica::hello_lock::assert_folder_in_use;
use crate::replica::served::Served;
use crate::replica::support::{
    OTHER_PROFILE, PROFILE, Site, apply, as_found, as_stat, exchange, failing_body, path, recorded,
    source_of, temp_files_under, with_deadline,
};

#[tokio::test]
async fn a_scan_write_and_commit_round_trip_lands_both_sides_in_sync() {
    let site = Site::new();
    site.put(Side::A, "top.txt", "top");
    site.put(Side::A, "deep/er/file.bin", vec![7u8; 300_000]);
    site.put(Side::B, "only-b.txt", "b");
    let a = site.locked(Side::A).await;
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
            site.archive(Side::B)
                .get(&path(relative))
                .copied()
                .map(as_found),
            Some(as_found(site.state_of(Side::B, relative))),
            "{relative} archived on the far side"
        );
    }
    // The next run over the wire finds nothing to do.
    let again = with_deadline("second exchange", exchange(&a, b)).await;
    assert!(again.plan.actions.is_empty(), "{:?}", again.plan.actions);
    served.close().await;
}

#[tokio::test]
async fn hello_and_lock_report_the_far_sides_replica_and_create_root_makes_a_missing_one() {
    let site = Site::new();
    std::fs::remove_dir(site.root(Side::B)).unwrap();
    let served = Served::new(&site, Side::B).await;
    let root = with_deadline("hello", served.replica.hello())
        .await
        .unwrap();
    assert!(matches!(root.root, ReplicaRoot::Missing { .. }));
    assert_eq!(
        root.archive_path,
        Some(site.log(Side::B).display().to_string())
    );
    let locked = with_deadline("lock", served.replica.lock()).await.unwrap();
    // The far side opened it with no spool: no room for a stage.
    assert_eq!(
        locked,
        LockFacts {
            archive: ArchiveFacts {
                last_commit: None,
                archived_files: 0,
            },
            spool_room: 0,
        }
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
async fn a_lock_held_on_the_far_side_comes_back_as_held_naming_only_its_file() {
    let site = Site::new();
    let local = site.replica(Side::B);
    with_deadline("local lock", local.lock()).await.unwrap();
    let served = Served::new(&site, Side::B).await;
    with_deadline("hello", served.replica.hello())
        .await
        .unwrap();
    let refused = with_deadline("remote lock", served.replica.lock()).await;
    let lock = site
        .state()
        .lock(&EntryId::parse(PROFILE).unwrap(), Side::B);
    assert!(
        matches!(&refused, Err(ReplicaError::Lock(LockError::Held { path }))
            if Some(path.as_os_str()) == lock.file_name()),
        "{refused:?}"
    );
    served.close().await;
}

#[tokio::test]
async fn a_folder_held_under_another_profile_on_the_far_side_comes_back_as_in_use() {
    let site = Site::new();
    let other = site.replica_at(
        &site.root(Side::B),
        OTHER_PROFILE,
        Side::A,
        Tuning::DEFAULT,
        SpoolSetting::Off,
    );
    with_deadline("local lock", other.lock()).await.unwrap();
    let served = Served::new(&site, Side::B).await;
    with_deadline("hello", served.replica.hello())
        .await
        .unwrap();
    assert_folder_in_use(
        with_deadline("remote lock", served.replica.lock()).await,
        &site.root(Side::B),
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
        served.replica.commit(vec![ArchiveCommit::Upsert {
            path: path("f"),
            file: recorded("x"),
        }]),
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
    assert_eq!(site.archive(Side::B).get(&path("f")), Some(&recorded("x")));
}

#[tokio::test]
async fn the_scan_applies_the_initiators_rules_on_the_far_side() {
    let site = Site::new();
    site.put(Side::B, "keep.txt", "k");
    site.put(Side::B, "build/out.o", "o");
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    with_deadline("lock", b.lock()).await.unwrap();
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
async fn every_scan_listing_past_a_body_s_credit_crosses_the_link_whole() {
    // Long names, so each listing is several times the 256 KiB a body may
    // send before its first grant.
    const FILES: usize = 4_000;
    let name = |n: usize| format!("{n:04}-{}", "x".repeat(200));
    let site = Site::new();
    for n in 0..FILES {
        site.put(Side::B, &name(n), "f");
    }
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    with_deadline("lock", b.lock()).await.unwrap();
    let opened = with_deadline("open_scan", b.open_scan(&RuleSet::default()))
        .await
        .unwrap();
    let mut scanned: Vec<_> = opened
        .changed
        .entries
        .iter()
        .map(|entry| entry.path.as_str().to_owned())
        .collect();
    scanned.sort();
    assert_eq!(scanned, (0..FILES).map(name).collect::<Vec<_>>());

    // The other side's paths, none of them held unchanged here.
    let peer_changed = (0..FILES).map(|n| path(&format!("peer/{}", name(n))));
    let count = BucketCount::for_entries(FILES);
    let digested = with_deadline(
        "digests",
        b.scan_digests(
            opened.next,
            count,
            Listing::from_vec(peer_changed.collect()),
        ),
    )
    .await
    .unwrap();
    assert_eq!(digested.digests.as_slice().len(), count.get() as usize);
    assert!(digested.owed.is_empty());
    let every: Vec<_> = (0..count.get()).filter_map(|n| count.bucket(n)).collect();
    let fetched = with_deadline("buckets", b.scan_buckets(&digested.next, &every))
        .await
        .unwrap();
    assert!(fetched.is_empty(), "{fetched:?}");
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
async fn a_read_dropped_after_its_first_chunk_stops_the_far_side_and_frees_its_path() {
    const BIG: usize = 16 * 1024 * 1024;
    let site = Site::new();
    site.put(Side::B, "big", vec![7u8; BIG]);
    let (served, sent) = Served::counting(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    let mut body = with_deadline("read", b.read(&path("big")))
        .await
        .unwrap()
        .body;
    let first = with_deadline("first chunk", body.next()).await.unwrap();
    assert!(first.is_some_and(|chunk| !chunk.is_empty()));
    drop(body);

    // The path's next read waits for the far side to end the first one:
    // by then it has sent all it ever will of it.
    let again = with_deadline("the same path's next read", b.read(&path("big")))
        .await
        .unwrap();
    let stopped_at = sent.load(Ordering::SeqCst);
    assert!(
        stopped_at < BIG / 4,
        "the far side sent {stopped_at} bytes of a {BIG}-byte file"
    );
    let content = with_deadline("collect", again.body.collect())
        .await
        .unwrap();
    assert_eq!(content.len(), BIG);
    // The count does see a whole file go by.
    assert!(sent.load(Ordering::SeqCst) > BIG);
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
            source_of(&content, 0o600),
            Precondition::Absent,
        ),
    )
    .await
    .unwrap();
    assert_eq!(site.get(Side::B, "d/w.bin"), content);
    assert_eq!(
        as_stat(landed),
        as_stat(site.state_of(Side::B, "d/w.bin").meta)
    );
    served.close().await;
}

#[tokio::test]
async fn a_body_that_does_not_hash_to_its_source_never_replaces_the_far_target() {
    let site = Site::new();
    site.put(Side::B, "f", "old");
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    let f = path("f");
    let write = |body: &[u8]| {
        b.write(
            &f,
            Body::from_bytes(body.to_vec()),
            source_of(b"hello", 0o644),
            site.expect(Side::B, "f"),
        )
    };

    // Same size as the source: only the hash, carried by the request,
    // tells them apart on the far side.
    let corrupt = with_deadline("corrupt write", write(b"hellO")).await;

    let Err(ReplicaError::Write(error)) = corrupt else {
        panic!("not a write error: {corrupt:?}");
    };
    assert_eq!(
        (error.stage, error.kind()),
        (Stage::Write, io::ErrorKind::InvalidData)
    );
    assert_eq!(site.get(Side::B, "f"), b"old");
    assert!(temp_files_under(&site.root(Side::B)).is_empty());

    // Positive control: the bytes the source holds land.
    with_deadline("whole write", write(b"hello")).await.unwrap();
    assert_eq!(site.get(Side::B, "f"), b"hello");
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
            source_of(vec![1; 3_000_000], 0o644),
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
            source_of(b"half and the rest", 0o644),
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
        b.write(
            &path("cut"),
            body,
            source_of(b"partial and the rest", 0o644),
            Precondition::Absent,
        ),
    )
    .await;
    assert!(matches!(cut, Err(ReplicaError::Write(_))), "{cut:?}");

    // And the session carries on.
    with_deadline(
        "write after the failures",
        b.write(
            &path("ok"),
            Body::from_bytes(b"fine".to_vec()),
            source_of(b"fine", 0o644),
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
        ]),
    )
    .await
    .unwrap();
    with_deadline("compact", b.compact()).await.unwrap();
    with_deadline("unlock", b.unlock()).await.unwrap();

    let archive = site.archive(Side::B);
    assert_eq!(archive.get(&path("u")), Some(&recorded("u")));
    assert_eq!(archive.get(&path("gone")), None);
    served.close().await;
}

#[tokio::test]
async fn scan_tickets_are_checked_on_the_far_side() {
    let site = Site::new();
    site.put(Side::B, "f", "x");
    let local = site.locked(Side::A).await;
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    with_deadline("lock", b.lock()).await.unwrap();
    // A ticket another replica issued names no exchange open over there.
    let foreign = with_deadline("local scan", local.open_scan(&RuleSet::default()))
        .await
        .unwrap();
    let count = BucketCount::for_entries(1);
    let refused = with_deadline(
        "digests",
        b.scan_digests(foreign.next, count, Listing::from_vec(Vec::new())),
    )
    .await;
    assert!(matches!(refused, Err(ReplicaError::NoScan)), "{refused:?}");
    // Its own exchange runs.
    let opened = with_deadline("open_scan", b.open_scan(&RuleSet::default()))
        .await
        .unwrap();
    assert!(matches!(
        opened.changed.entries[0].status,
        Status::Created(_)
    ));
    let digested = with_deadline(
        "digests",
        b.scan_digests(opened.next, count, Listing::from_vec(Vec::new())),
    )
    .await
    .unwrap();
    assert_eq!(digested.digests.as_slice().len(), 1);
    served.close().await;
}
