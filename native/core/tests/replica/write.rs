//! `write`: landing a body through the writer pool (SPEC §7.2-§7.6).

use std::fs;
use std::time::{Duration, Instant, UNIX_EPOCH};

use dsync_core::{Body, LocalReplica, Replica, ReplicaError, Stage, body_channel};
use dsync_domain::{FileMeta, Side};

use crate::support::{MTIME_US, Site, failing_body, meta, path, temp_files_under, with_deadline};

async fn write(replica: &LocalReplica, relative: &str, content: &str, mode: u32) -> FileMeta {
    with_deadline(
        "write",
        replica.write(
            &path(relative),
            Body::from_bytes(content.as_bytes().to_vec()),
            meta(mode),
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
        landed,
        FileMeta {
            size: 5,
            mtime_us: MTIME_US,
            mode: 0o640,
        }
    );
    assert_eq!(landed, site.state_of(Side::B, "a.txt").meta);
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
    assert_eq!(stats.stage(Stage::Mkdir).count, 1);
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
            meta(0o644),
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
        replica.delete(&path("sub/a.txt")).await.unwrap();
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
async fn a_body_failing_mid_way_fails_the_write_and_leaves_the_target_torn() {
    let site = Site::new();
    let target = site.put(Side::B, "a.txt", "the old content, longer than the new");
    let before = mtime_us(&target);
    let replica = site.replica(Side::B);

    let result = with_deadline("write", async {
        let body = failing_body(b"partial").await;
        replica.write(&path("a.txt"), body, meta(0o644)).await
    })
    .await;

    let Err(ReplicaError::Write(error)) = result else {
        panic!("expected a write error, got {result:?}");
    };
    assert_eq!(error.stage, Stage::Wait);
    // Torn: neither the old bytes nor a finished new file, and no mtime
    // propagated. The caller's mark is what makes this safe (SPEC §7.6).
    assert_eq!(site.get(Side::B, "a.txt"), b"partial");
    assert_ne!(mtime_us(&target), MTIME_US);
    assert!(mtime_us(&target) >= before);
}

#[tokio::test]
async fn a_body_whose_sender_goes_away_unfinished_is_cut_short_not_complete() {
    let site = Site::new();
    let replica = site.replica(Side::B);

    let result = with_deadline("write", async {
        let (sender, body) = body_channel(2);
        sender.send(b"all it sent".to_vec()).await.unwrap();
        drop(sender);
        replica.write(&path("a.txt"), body, meta(0o644)).await
    })
    .await;

    let Err(ReplicaError::Write(error)) = result else {
        panic!("expected a write error, got {result:?}");
    };
    assert_eq!(error.kind(), std::io::ErrorKind::UnexpectedEof);
}

#[tokio::test]
async fn writes_in_place_with_no_scratch_file_at_any_point() {
    let site = Site::new();
    site.put(Side::B, "a.txt", "old");
    let replica = site.replica(Side::B);

    with_deadline("write", async {
        let (sender, body) = body_channel(2);
        let target = path("a.txt");
        let write = replica.write(&target, body, meta(0o644));
        let feed = async {
            sender.send(b"first half ".to_vec()).await.unwrap();
            // Mid-write: the target already holds the first half.
            while site.get(Side::B, "a.txt") != b"first half " {
                tokio::task::yield_now().await;
            }
            assert!(temp_files_under(&site.root(Side::B)).is_empty());
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

/// The pool's byte budget in this test, in chunks of [`CHUNK`].
const BUDGET_CHUNKS: usize = 4;
const CHUNK: usize = 1024;

/// How long a send must stay blocked to count as waiting on the budget.
const BLOCKED: Duration = Duration::from_millis(300);

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread")]
async fn a_stalled_writer_bounds_received_but_unwritten_bytes_and_the_sender_waits() {
    use dsync_domain::Tuning;
    use std::io::Read;

    let site = Site::new();
    // A named pipe with nobody reading: opening it to write blocks, which
    // stalls the writer that takes this file before it writes a byte.
    let fifo = site.file(Side::B, "stalled");
    let made = std::process::Command::new("mkfifo")
        .arg(&fifo)
        .status()
        .unwrap();
    assert!(made.success());
    let replica = site.replica_with(
        Side::B,
        Tuning {
            writer_buffer_bytes: BUDGET_CHUNKS * CHUNK,
            ..Tuning::DEFAULT
        },
    );
    let (sender, body) = body_channel(1);

    let write = tokio::spawn(async move {
        let landed = replica.write(&path("stalled"), body, meta(0o644)).await;
        (replica, landed)
    });

    // The budget's worth goes into the pool, one more is held by the write
    // waiting for budget, one more sits in the body's own buffer - and the
    // next send waits.
    let mut sent = 0;
    loop {
        let chunk = vec![u8::try_from(sent % 256).unwrap(); CHUNK];
        match tokio::time::timeout(BLOCKED, sender.send(chunk)).await {
            Ok(result) => {
                result.unwrap();
                sent += 1;
                assert!(sent <= BUDGET_CHUNKS + 2, "the sender never waited");
            }
            Err(_) => break,
        }
    }
    assert_eq!(sent, BUDGET_CHUNKS + 2);

    // Positive control: once the writer drains, the same sender runs to
    // the end and every byte arrives in order.
    let drained = tokio::task::spawn_blocking(move || {
        let mut all = Vec::new();
        fs::File::open(&fifo)
            .unwrap()
            .read_to_end(&mut all)
            .unwrap();
        all
    });
    let total = with_deadline("drain", async {
        let mut total = sent;
        for _ in 0..BUDGET_CHUNKS {
            let chunk = vec![u8::try_from(total % 256).unwrap(); CHUNK];
            sender.send(chunk.clone()).await.unwrap();
            total += 1;
        }
        sender.finish().await.unwrap();
        let (_replica, landed) = write.await.unwrap();
        landed.unwrap();
        total
    })
    .await;
    let all = with_deadline("reader", drained).await.unwrap();
    let expected: Vec<u8> = (0..total)
        .flat_map(|i| vec![u8::try_from(i % 256).unwrap(); CHUNK])
        .collect();
    assert_eq!(all, expected);
}

#[cfg(unix)]
#[tokio::test]
async fn a_write_dropped_mid_body_lands_nothing_and_leaves_no_scratch() {
    let site = Site::new();
    let target = site.put(Side::B, "a.txt", "old");
    // A second name, so the write goes through a scratch file.
    fs::hard_link(&target, site.dir().join("elsewhere.txt")).unwrap();
    let replica = site.replica(Side::B);

    with_deadline("cancelled write", async {
        let (sender, body) = body_channel(2);
        let at = path("a.txt");
        let mut write = Box::pin(replica.write(&at, body, meta(0o644)));
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
