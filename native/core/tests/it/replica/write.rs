//! `write`: landing a body through the writer pool (SPEC §7.2-§7.6).

use std::fs;
use std::time::{Duration, Instant, UNIX_EPOCH};

use dsync_core::{Body, LocalReplica, Replica, ReplicaError, Stage, body_channel};
use dsync_domain::{FileMeta, Precondition, STAGING_DIR, Side};

use crate::replica::support::{
    MTIME_US, Site, as_stat, expect_at, failing_body, path, source_of, temp_files_under,
    with_deadline,
};

async fn write(replica: &LocalReplica, relative: &str, content: &str, mode: u32) -> FileMeta {
    with_deadline(
        "write",
        replica.write(
            &path(relative),
            Body::from_bytes(content.as_bytes().to_vec()),
            source_of(content, mode),
            expect_at(&replica.root().join(relative)),
        ),
    )
    .await
    .unwrap()
}

fn mtime_us(file: &std::path::Path) -> i64 {
    let modified = fs::metadata(file).unwrap().modified().unwrap();
    i64::try_from(modified.duration_since(UNIX_EPOCH).unwrap().as_micros()).unwrap()
}

#[cfg(unix)]
#[tokio::test]
async fn lands_the_bytes_mtime_and_mode_and_returns_what_landed() {
    let site = Site::new();
    let replica = site.replica(Side::B);

    let landed = write(&replica, "a.txt", "hello", 0o640).await;

    assert_eq!(site.get(Side::B, "a.txt"), b"hello");
    assert_eq!(
        as_stat(landed),
        FileMeta {
            size: 5,
            mtime_us: MTIME_US,
            mode: 0o640,
            read_us: 0,
        }
    );
    assert_eq!(
        as_stat(landed),
        as_stat(site.state_of(Side::B, "a.txt").meta)
    );
    assert!(temp_files_under(&site.root(Side::B)).is_empty());
}

#[cfg(unix)]
#[tokio::test]
async fn a_mode_the_new_file_already_has_and_one_it_does_not_both_land() {
    let site = Site::new();
    let replica = site.replica(Side::B);

    assert_eq!(write(&replica, "a.txt", "x", 0o644).await.mode, 0o644);
    assert_eq!(write(&replica, "b.txt", "x", 0o600).await.mode, 0o600);
}

#[tokio::test]
async fn times_every_stage_inside_the_span_that_contains_it() {
    let site = Site::new();
    let replica = site.replica(Side::B);
    let wall = Instant::now();

    write(&replica, "a.txt", "hello", 0o644).await;
    write(&replica, "sub/b.txt", "hello", 0o600).await;

    let stats = replica.write_stats();
    assert_eq!(stats.files, 2);
    assert_eq!(stats.writers, 16);
    // The staging folder and `sub`, once each.
    assert_eq!(stats.stage(Stage::Mkdir).count, 2);
    assert_eq!(stats.stage(Stage::Write).count, 2);
    assert!(stats.staged() > Duration::ZERO);
    assert!(stats.staged() <= wall.elapsed());
}

#[tokio::test]
async fn creates_parent_folders_as_needed() {
    let site = Site::new();

    write(&site.replica(Side::B), "sub/dir/a.txt", "nested", 0o644).await;

    assert_eq!(site.get(Side::B, "sub/dir/a.txt"), b"nested");
}

#[tokio::test]
async fn a_parent_is_created_once_a_session_and_forgotten_when_a_write_fails() {
    let site = Site::new();
    let replica = site.replica(Side::B);
    write(&replica, "sub/a.txt", "x", 0o644).await;
    // Removed behind the replica's back: the lock does not stop that.
    fs::remove_dir_all(site.file(Side::B, "sub")).unwrap();

    // The memo is what fails this: a create per file would have put the
    // folder straight back.
    let failed = with_deadline(
        "write",
        replica.write(
            &path("sub/b.txt"),
            Body::from_bytes(b"x".to_vec()),
            source_of(b"x", 0o644),
            Precondition::Absent,
        ),
    )
    .await;
    assert!(matches!(failed, Err(ReplicaError::Write(_))), "{failed:?}");

    // And the failure forgot it, so the next path under it recovers.
    write(&replica, "sub/c.txt", "x", 0o644).await;
    assert_eq!(site.get(Side::B, "sub/c.txt"), b"x");
}

#[tokio::test]
async fn a_folder_this_session_pruned_is_created_again_not_trusted() {
    let site = Site::new();
    let replica = site.replica(Side::B);

    write(&replica, "sub/a.txt", "x", 0o644).await;
    with_deadline("prune", async {
        let expect = site.expect(Side::B, "sub/a.txt");
        replica.delete(&path("sub/a.txt"), expect).await.unwrap();
        replica.remove_empty_dirs(&path("sub/a.txt")).await.unwrap();
    })
    .await;
    assert!(!site.file(Side::B, "sub").exists());

    write(&replica, "sub/b.txt", "x", 0o644).await;
    assert_eq!(site.get(Side::B, "sub/b.txt"), b"x");
}

#[tokio::test]
async fn overwrites_an_existing_target() {
    let site = Site::new();
    site.put(Side::B, "a.txt", "old");

    write(&site.replica(Side::B), "a.txt", "new", 0o644).await;

    assert_eq!(site.get(Side::B, "a.txt"), b"new");
}

#[tokio::test]
async fn a_body_failing_mid_way_fails_the_write_and_leaves_the_target_whole() {
    let site = Site::new();
    let target = site.put(Side::B, "a.txt", "the old content, longer than the new");
    let before = mtime_us(&target);
    let replica = site.replica(Side::B);

    let result = with_deadline("write", async {
        let body = failing_body(b"partial").await;
        let expect = site.expect(Side::B, "a.txt");
        let source = source_of(b"partial and the rest", 0o644);
        replica.write(&path("a.txt"), body, source, expect).await
    })
    .await;

    let Err(ReplicaError::Write(error)) = result else {
        panic!("expected a write error, got {result:?}");
    };
    assert_eq!(error.stage, Stage::Wait);
    // The old bytes and mtime, and the temp gone (SPEC §7.6).
    assert_eq!(
        site.get(Side::B, "a.txt"),
        b"the old content, longer than the new"
    );
    assert_eq!(mtime_us(&target), before);
    assert!(temp_files_under(&site.root(Side::B)).is_empty());
}

#[tokio::test]
async fn a_body_whose_sender_goes_away_unfinished_is_cut_short_not_complete() {
    let site = Site::new();
    let replica = site.replica(Side::B);

    let result = with_deadline("write", async {
        let (sender, body) = body_channel(2);
        sender.send(b"all it sent".to_vec()).await.unwrap();
        drop(sender);
        let expect = site.expect(Side::B, "a.txt");
        let source = source_of(b"all it sent and the rest", 0o644);
        replica.write(&path("a.txt"), body, source, expect).await
    })
    .await;

    let Err(ReplicaError::Write(error)) = result else {
        panic!("expected a write error, got {result:?}");
    };
    assert_eq!(error.kind(), std::io::ErrorKind::UnexpectedEof);
}

#[tokio::test]
async fn streams_into_a_temp_in_the_staging_folder_and_renames_it_on() {
    let site = Site::new();
    site.put(Side::B, "a.txt", "old");
    let replica = site.replica(Side::B);

    with_deadline("write", async {
        let (sender, body) = body_channel(2);
        let target = path("a.txt");
        let source = source_of(b"first half second half", 0o644);
        let write = replica.write(&target, body, source, site.expect(Side::B, "a.txt"));
        let feed = async {
            sender.send(b"first half ".to_vec()).await.unwrap();
            // Mid-write: the temp holds the first half, the target the old.
            let staged = || {
                let temps = temp_files_under(&site.root(Side::B));
                temps.iter().any(|temp| {
                    temp.parent() == Some(&site.root(Side::B).join(STAGING_DIR))
                        && fs::read(temp).unwrap() == b"first half "
                })
            };
            while !staged() {
                tokio::task::yield_now().await;
            }
            assert_eq!(site.get(Side::B, "a.txt"), b"old");
            sender.send(b"second half".to_vec()).await.unwrap();
            sender.finish().await.unwrap();
        };
        let (landed, ()) = tokio::join!(write, feed);
        landed.unwrap();
    })
    .await;

    assert_eq!(site.get(Side::B, "a.txt"), b"first half second half");
    assert!(temp_files_under(&site.root(Side::B)).is_empty());
}

#[cfg(unix)]
#[tokio::test]
async fn a_write_dropped_mid_body_lands_nothing_and_leaves_no_scratch() {
    let site = Site::new();
    site.put(Side::B, "a.txt", "old");
    let replica = site.replica(Side::B);

    with_deadline("cancelled write", async {
        let (sender, body) = body_channel(2);
        let at = path("a.txt");
        let expect = site.expect(Side::B, "a.txt");
        let mut write =
            Box::pin(replica.write(&at, body, source_of(b"partial and the rest", 0o644), expect));
        sender.send(b"partial".to_vec()).await.unwrap();
        // Drive the write until the writer is streaming into its scratch
        // file, then drop it the way a run's second stop does.
        loop {
            tokio::select! {
                biased;
                _ = &mut write => panic!("the write finished without its end"),
                () = tokio::task::yield_now() => {}
            }
            if !temp_files_under(&site.root(Side::B)).is_empty() {
                break;
            }
        }
        drop(write);
        while !temp_files_under(&site.root(Side::B)).is_empty() {
            tokio::task::yield_now().await;
        }
    })
    .await;

    assert_eq!(site.get(Side::B, "a.txt"), b"old");
}

#[tokio::test]
async fn a_target_no_longer_what_the_scan_saw_is_left_untouched() {
    let site = Site::new();
    site.put(Side::B, "edited", "as scanned");
    let scanned = site.expect(Side::B, "edited");
    site.put(Side::B, "edited", "edited since");
    let replica = site.replica(Side::B);

    let edited = with_deadline(
        "write",
        replica.write(
            &path("edited"),
            Body::from_bytes(b"new".to_vec()),
            source_of(b"new", 0o644),
            scanned,
        ),
    )
    .await;
    // Created since a scan that saw nothing there, in a folder that did
    // not exist either: no folder is left behind.
    site.put(Side::B, "sub/created", "made meanwhile");
    let created = with_deadline(
        "write",
        replica.write(
            &path("sub/created"),
            Body::from_bytes(b"new".to_vec()),
            source_of(b"new", 0o644),
            Precondition::Absent,
        ),
    )
    .await;

    assert!(
        matches!(edited, Err(ReplicaError::Changed(_))),
        "{edited:?}"
    );
    assert!(
        matches!(created, Err(ReplicaError::Changed(_))),
        "{created:?}"
    );
    assert_eq!(site.get(Side::B, "edited"), b"edited since");
    assert_eq!(site.get(Side::B, "sub/created"), b"made meanwhile");
    assert!(temp_files_under(&site.root(Side::B)).is_empty());
}
