//! A `LocalReplica` opened with a spool: `stage` lands at once while its
//! writers keep up, spills to spool files while they are behind, waits
//! when neither will do, and lands in stage order; its lock, unlock and
//! drop own the spool's lifetime. Writers are held busy with
//! [`LandingHold`], never by timing.

use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::pin;
use std::sync::Arc;
use std::time::Duration;

use dsync_core::{
    Body, LandingHold, LocalReplica, LockError, RemoteReplica, Replica, ReplicaError, body_channel,
};
use dsync_domain::{LockFacts, Precondition, STAGING_DIR, Side, Tuning};

use crate::cut_link::CutLink;
use crate::replica::served::{Served, still_pending};
use crate::replica::support::{
    Site, failing_body, path, source_of, temp_files_under, with_deadline,
};

/// How long a stage, an unlock or a landing that must wait is watched for
/// finishing anyway. A wait that is not there shows up well within it.
const STILL: Duration = Duration::from_millis(200);

/// A spool of `room` bytes, on all the volume's free space, with
/// `writers` writers.
fn tuning(writers: usize, room: u64) -> Tuning {
    Tuning {
        writers,
        spool_bytes: room,
        spool_reserve_bytes: 0,
        ..Tuning::DEFAULT
    }
}

/// Side B, spooled with `tuning` and locked, with exactly the room asked
/// for: never less for a fuller volume, so no test's waits depend on it.
async fn spooled(site: &Site, tuning: Tuning) -> LocalReplica {
    let replica = site.spooled(Side::B, tuning);
    let facts = with_deadline("lock", replica.lock()).await.unwrap();
    assert_eq!(facts.spool_room, tuning.spool_bytes, "the volume is short");
    replica
}

/// Side B's spool files now, in each session's folder; none when there
/// is no spool folder.
fn spool_paths(site: &Site) -> Vec<PathBuf> {
    let Ok(sessions) = fs::read_dir(site.spool(Side::B)) else {
        return Vec::new();
    };
    let mut paths = Vec::new();
    for session in sessions {
        for file in fs::read_dir(session.unwrap().path()).unwrap() {
            paths.push(file.unwrap().path());
        }
    }
    paths.sort();
    paths
}

/// The names of side B's spool files now.
fn spool_files(site: &Site) -> Vec<String> {
    spool_paths(site)
        .iter()
        .map(|file| file.file_name().unwrap().to_string_lossy().into_owned())
        .collect()
}

/// The folder of side B's one spool session.
fn session_folder(site: &Site) -> PathBuf {
    let sessions: Vec<PathBuf> = fs::read_dir(site.spool(Side::B))
        .unwrap()
        .map(|session| session.unwrap().path())
        .collect();
    assert_eq!(sessions.len(), 1, "{sessions:?}");
    sessions.into_iter().next().unwrap()
}

/// Stages `content` at `name`, new on side B.
async fn stage(replica: &LocalReplica, name: &str, content: &[u8]) -> Result<(), ReplicaError> {
    replica
        .stage(
            &path(name),
            Body::from_bytes(content.to_vec()),
            source_of(content, 0o644),
            Precondition::Absent,
        )
        .await
}

async fn staged(replica: &LocalReplica, name: &str, content: &[u8]) {
    with_deadline(name, stage(replica, name, content))
        .await
        .unwrap();
}

/// The next `count` landings, in the order they answered, each landed.
async fn landed(replica: &LocalReplica, count: usize) -> Vec<String> {
    let mut order = Vec::new();
    while order.len() < count {
        let landings = with_deadline("take_landed", replica.take_landed())
            .await
            .unwrap();
        assert!(
            !landings.landed.is_empty(),
            "answered with nothing while {count} were due"
        );
        for (at, result) in landings.landed {
            result.unwrap_or_else(|error| panic!("{at}: {error}"));
            order.push(at.as_str().to_owned());
        }
    }
    order
}

/// Asserts `work` has not finished within [`STILL`].
async fn still_waiting<F: Future + Unpin>(work: &mut F, label: &str) {
    assert!(
        tokio::time::timeout(STILL, work).await.is_err(),
        "{label} finished while it should wait"
    );
}

#[tokio::test]
async fn lock_reports_the_room_and_no_room_is_no_spool() {
    let site = Site::new();
    let replica = site.spooled(Side::B, tuning(1, 1 << 20));
    let facts = with_deadline("lock", replica.lock()).await.unwrap();
    assert_eq!(facts.spool_room, 1 << 20, "the cap, under the free space");
    assert!(site.spool(Side::B).is_dir());
    with_deadline("unlock", replica.unlock()).await.unwrap();
    assert!(!site.spool(Side::B).exists(), "removed at unlock");

    // A reserve past any free space leaves no room: no spool, as if off.
    let starved = Tuning {
        spool_reserve_bytes: u64::MAX,
        ..tuning(1, 1 << 20)
    };
    for tuning in [starved, tuning(1, 0)] {
        let replica = site.spooled(Side::B, tuning);
        let facts = with_deadline("lock", replica.lock()).await.unwrap();
        assert_eq!(facts.spool_room, 0);
        let refused = with_deadline("stage", stage(&replica, "f", b"x")).await;
        assert!(
            matches!(&refused, Err(ReplicaError::Refused(why)) if why.contains("no spool")),
            "{refused:?}"
        );
        with_deadline("unlock", replica.unlock()).await.unwrap();
    }
    assert!(!site.file(Side::B, "f").exists());
}

#[tokio::test]
async fn writers_that_keep_up_take_each_body_with_no_spool_file() {
    let site = Site::new();
    let replica = spooled(&site, tuning(2, 1 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));

    staged(&replica, "a", b"first").await;
    staged(&replica, "b", b"second").await;

    // Both on a writer, held there, and nothing spooled.
    with_deadline("held", hold.until_held(2)).await;
    assert_eq!(spool_files(&site), Vec::<String>::new());
    // Positive control: with both writers busy the next one spills.
    staged(&replica, "c", b"third").await;
    assert_eq!(spool_files(&site), ["0"]);

    hold.release();
    let mut order = landed(&replica, 3).await;
    order.sort();
    assert_eq!(order, ["a", "b", "c"]);
    assert_eq!(site.get(Side::B, "a"), b"first");
    assert_eq!(site.get(Side::B, "c"), b"third");
    assert_eq!(spool_files(&site), Vec::<String>::new());
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn busy_writers_spill_to_spool_files_that_land_in_stage_order() {
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 1 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));

    staged(&replica, "f0", b"zero").await;
    for (name, content) in [("f1", b"one"), ("f2", b"two"), ("f3", b"333")] {
        staged(&replica, name, content).await;
    }

    assert_eq!(spool_files(&site), ["0", "1", "2"]);
    let spooled_bytes = *replica.spool_queued_bytes().unwrap().borrow();
    assert_eq!(
        spooled_bytes, 9,
        "the three spooled, not the one on a writer"
    );
    // A long poll: nothing has landed, so it waits.
    let mut polling = pin!(replica.take_landed());
    still_waiting(&mut polling, "a take_landed with every landing held").await;
    hold.release();
    let first = with_deadline("take_landed", &mut polling).await.unwrap();
    let mut order: Vec<String> = first
        .landed
        .into_iter()
        .map(|(at, result)| {
            result.unwrap();
            at.as_str().to_owned()
        })
        .collect();
    assert!(!order.is_empty());
    let rest = 4 - order.len();
    order.extend(landed(&replica, rest).await);
    assert_eq!(order, ["f0", "f1", "f2", "f3"]);
    assert_eq!(site.get(Side::B, "f2"), b"two");
    assert_eq!(spool_files(&site), Vec::<String>::new());
    let settled = with_deadline("take_landed", replica.take_landed())
        .await
        .unwrap();
    assert_eq!((settled.landed.len(), settled.queued), (0, 0));
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_full_spool_holds_the_next_stage_until_a_landing_frees_room() {
    const SIZE: usize = 1000;
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 2 * SIZE as u64)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    let content = |byte: u8| vec![byte; SIZE];

    staged(&replica, "f0", &content(0)).await;
    staged(&replica, "f1", &content(1)).await;
    staged(&replica, "f2", &content(2)).await;
    let third = content(3);
    let mut f3 = pin!(stage(&replica, "f3", &third));
    still_waiting(&mut f3, "a stage into a full spool").await;

    // f0 lands; f1 goes to the writer, but its room is still its own.
    hold.release_one();
    with_deadline("f1 on its writer", hold.until_arrived(2)).await;
    still_waiting(&mut f3, "a stage while the spool's room is landing").await;
    // f1 lands and frees its room: f3 spills into it.
    hold.release_one();
    with_deadline("f3", &mut f3).await.unwrap();
    assert_eq!(spool_files(&site), ["1", "2"]);

    hold.release();
    assert_eq!(landed(&replica, 4).await, ["f0", "f1", "f2", "f3"]);
    assert_eq!(site.get(Side::B, "f3"), content(3));
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_file_larger_than_the_whole_room_waits_for_a_writer_and_lands_with_no_spool_file() {
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 100)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    let large = vec![7u8; 1000];

    staged(&replica, "small", b"small").await;
    let mut staging = pin!(stage(&replica, "large", &large));
    still_waiting(&mut staging, "a stage larger than the room").await;
    assert_eq!(spool_files(&site), Vec::<String>::new());

    hold.release_one();
    with_deadline("large", &mut staging).await.unwrap();
    // On its writer, held there, and never spooled.
    with_deadline("large on its writer", hold.until_held(1)).await;
    assert_eq!(spool_files(&site), Vec::<String>::new());

    hold.release();
    assert_eq!(landed(&replica, 2).await, ["small", "large"]);
    assert_eq!(site.get(Side::B, "large"), large);
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_stage_behind_a_spooled_body_still_arriving_spills_behind_it() {
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 1 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    let mut queued = replica.spool_queued_bytes().unwrap();
    let arriving = vec![1u8; 2048];

    staged(&replica, "f0", b"zero").await;
    let (sender, body) = body_channel(1);
    let f1 = path("f1");
    let staging = replica.stage(&f1, body, source_of(&arriving, 0o644), Precondition::Absent);
    let script = async {
        sender.send(arriving[..1024].to_vec()).await.unwrap();
        // Its place is taken: it spills, behind nothing.
        let size = arriving.len() as u64;
        with_deadline("f1 placed", queued.wait_for(|bytes| *bytes == size))
            .await
            .unwrap();
        // The writer comes free while f1 is still arriving.
        hold.release_one();
        assert_eq!(landed(&replica, 1).await, ["f0"]);

        staged(&replica, "f2", b"two").await;

        // f2 waits behind f1 in the spool rather than taking the free
        // writer and landing first.
        assert_eq!(spool_files(&site), ["0", "1"]);
        assert_eq!(hold.held(), 0);
        sender.send(arriving[1024..].to_vec()).await.unwrap();
        sender.finish().await.unwrap();
    };
    let (staged_f1, ()) = with_deadline("f1 and f2", async { tokio::join!(staging, script) }).await;
    staged_f1.unwrap();

    hold.release();
    assert_eq!(landed(&replica, 2).await, ["f1", "f2"]);
    assert_eq!(site.get(Side::B, "f1"), arriving);
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_spooled_body_whose_source_moved_fails_its_stage_and_leaves_nothing_behind() {
    let site = Site::new();
    let scanned = vec![5u8; 4096];
    let source = site.put(Side::A, "f.bin", &scanned);
    let target = site.put(Side::B, "f.bin", b"old bytes");
    let (old_mtime, expect_b) = (
        fs::metadata(&target).unwrap().modified().unwrap(),
        site.expect(Side::B, "f.bin"),
    );
    let source_state = site.state_of(Side::A, "f.bin");
    let expect_a = site.expect(Side::A, "f.bin");
    let a = site.replica(Side::A);
    // The room holds exactly this file.
    let replica = spooled(&site, tuning(1, scanned.len() as u64)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    staged(&replica, "busy", b"busy").await;

    // Edited after the scan, at the same size: only its mtime moved.
    fs::write(&source, vec![6u8; 4096]).unwrap();
    let (body, moved) = with_deadline("read", a.read(&path("f.bin")))
        .await
        .unwrap()
        .checked(expect_a);
    let failed = with_deadline(
        "stage",
        replica.stage(&path("f.bin"), body, source_state, expect_b),
    )
    .await;

    assert!(moved.happened());
    assert!(matches!(failed, Err(ReplicaError::Write(_))), "{failed:?}");
    assert_eq!(spool_files(&site), Vec::<String>::new());
    let spooled_bytes = *replica.spool_queued_bytes().unwrap().borrow();
    assert_eq!(spooled_bytes, 0, "no entry left in the queue");
    // Its room is free again: a file that needs all of it spills at once.
    staged(&replica, "next.bin", &scanned).await;
    assert_eq!(spool_files(&site), ["1"]);

    hold.release();
    assert_eq!(landed(&replica, 2).await, ["busy", "next.bin"]);
    assert_eq!(site.get(Side::B, "f.bin"), b"old bytes");
    assert_eq!(
        fs::metadata(&target).unwrap().modified().unwrap(),
        old_mtime
    );
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_body_that_fails_on_its_way_to_a_free_writer_fails_its_stage_and_reports_no_landing() {
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 1 << 20)).await;

    let failed = with_deadline(
        "stage",
        replica.stage(
            &path("f"),
            failing_body(b"half").await,
            source_of(b"half and the rest", 0o644),
            Precondition::Absent,
        ),
    )
    .await;

    assert!(matches!(failed, Err(ReplicaError::Write(_))), "{failed:?}");
    let landings = with_deadline("take_landed", replica.take_landed())
        .await
        .unwrap();
    assert_eq!((landings.landed.len(), landings.queued), (0, 0));
    assert!(!site.file(Side::B, "f").exists());
    // Positive control: the writer is free again, and takes the next.
    staged(&replica, "g", b"whole").await;
    assert_eq!(landed(&replica, 1).await, ["g"]);
    assert_eq!(spool_files(&site), Vec::<String>::new());
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn unlock_waits_for_a_held_landing_then_sweeps_staging_and_spool() {
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 1 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    staged(&replica, "f0", b"zero").await;
    staged(&replica, "f1", b"one").await;
    with_deadline("f0 on its writer", hold.until_held(1)).await;

    let mut unlocking = pin!(replica.unlock());
    still_waiting(&mut unlocking, "an unlock with a landing held").await;
    hold.release();
    with_deadline("unlock", &mut unlocking).await.unwrap();

    assert_eq!(site.get(Side::B, "f0"), b"zero");
    assert_eq!(site.get(Side::B, "f1"), b"one");
    assert!(!site.root(Side::B).join(STAGING_DIR).exists());
    assert!(!site.spool(Side::B).exists());
}

#[tokio::test]
async fn a_spooled_replica_dropped_without_unlock_lands_nothing_more() {
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 1 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    staged(&replica, "f0", b"zero").await;
    staged(&replica, "f1", b"one").await;
    staged(&replica, "f2", b"two").await;
    with_deadline("f0 on its writer", hold.until_held(1)).await;

    drop(replica);
    // The write already on a writer goes on; the queue behind it does not.
    hold.release_one();
    let mut next = pin!(hold.until_arrived(2));
    still_waiting(&mut next, "a spooled landing after the drop").await;

    let fresh = site.spooled(Side::B, tuning(1, 1 << 20));
    with_deadline("a fresh lock", fresh.lock()).await.unwrap();
    assert_eq!(spool_files(&site), Vec::<String>::new(), "swept at lock");
    hold.release();
    with_deadline("settle", fresh.settle()).await;
    assert!(!site.file(Side::B, "f1").exists());
    assert!(!site.file(Side::B, "f2").exists());
    with_deadline("unlock", fresh.unlock()).await.unwrap();
}

#[tokio::test]
async fn queued_bytes_fall_chunk_by_chunk_through_one_large_held_landing() {
    const CHUNK: usize = 4096;
    let site = Site::new();
    let replica = spooled(
        &site,
        Tuning {
            read_buffer_bytes: CHUNK,
            writer_buffer_bytes: CHUNK,
            ..tuning(1, 1 << 20)
        },
    )
    .await;
    let hold = LandingHold::at(&site.root(Side::B));
    let mut queued = replica.spool_queued_bytes().unwrap();
    let large = vec![9u8; 16 * CHUNK];
    let size = large.len() as u64;

    staged(&replica, "busy", b"busy").await;
    assert_eq!(*queued.borrow(), 0, "a body on a writer is not queued");
    staged(&replica, "large", &large).await;
    assert_eq!(*queued.borrow(), size);

    // The large file goes to the writer and is held there: its first
    // chunks are handed over, the rest wait on the budget.
    hold.release_one();
    with_deadline("large on its writer", hold.until_arrived(2)).await;
    let part = *with_deadline(
        "a chunk handed over",
        queued.wait_for(|bytes| *bytes < size),
    )
    .await
    .unwrap();
    assert!(part > 0, "the whole file went at once");
    assert_eq!(
        (size - part) % CHUNK as u64,
        0,
        "{part} is not whole chunks"
    );

    hold.release();
    with_deadline("all handed over", queued.wait_for(|bytes| *bytes == 0))
        .await
        .unwrap();
    assert_eq!(landed(&replica, 2).await, ["busy", "large"]);
    assert_eq!(site.get(Side::B, "large"), large);
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_spool_file_out_of_space_fails_the_stage_as_out_of_space() {
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 1 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    staged(&replica, "busy", b"busy").await;
    // The first spool file, on a device that is always full.
    std::os::unix::fs::symlink(Path::new("/dev/full"), session_folder(&site).join("0")).unwrap();

    let failed = with_deadline("stage", stage(&replica, "f", b"no room for me")).await;

    let error = failed.unwrap_err();
    assert!(error.out_of_space(), "{error:?}");
    assert_eq!(spool_files(&site), Vec::<String>::new());
    hold.release();
    assert_eq!(landed(&replica, 1).await, ["busy"]);
    assert!(!site.file(Side::B, "f").exists());
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_spooled_stage_dropped_mid_body_gives_back_its_entry_room_and_file() {
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 1 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    let mut queued = replica.spool_queued_bytes().unwrap();
    staged(&replica, "busy", b"busy").await;
    let content = vec![4u8; 2048];
    let (sender, body) = body_channel(1);
    let at = path("dropped");

    {
        let mut staging =
            pin!(replica.stage(&at, body, source_of(&content, 0o644), Precondition::Absent));
        let size = content.len() as u64;
        let placed = async {
            sender.send(content[..1024].to_vec()).await.unwrap();
            queued.wait_for(|bytes| *bytes == size).await.unwrap();
        };
        tokio::select! {
            staged = &mut staging => panic!("a stage half-sent answered: {staged:?}"),
            () = with_deadline("spilled", placed) => {}
        }
    }

    assert_eq!(*queued.borrow(), 0);
    // The writer of the half-written file is done with it by the time the
    // spool settles; until then it may still be closing it.
    hold.release();
    with_deadline("settle", replica.settle()).await;
    assert_eq!(spool_files(&site), Vec::<String>::new());
    assert_eq!(landed(&replica, 1).await, ["busy"]);
    assert!(!site.file(Side::B, "dropped").exists());
    // Its room is back: a file that needs all of it still spills.
    let hold = LandingHold::at(&site.root(Side::B));
    staged(&replica, "busy2", b"busy").await;
    staged(&replica, "whole", &vec![1u8; 1 << 20]).await;
    assert_eq!(spool_files(&site), ["1"]);
    hold.release();
    assert_eq!(landed(&replica, 2).await, ["busy2", "whole"]);
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_stage_dropped_while_handing_its_body_to_a_writer_leaves_nothing_landing() {
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 1 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    let content = vec![4u8; 2048];
    let (sender, body) = body_channel(1);
    let at = path("dropped");

    {
        let mut staging =
            pin!(replica.stage(&at, body, source_of(&content, 0o644), Precondition::Absent));
        let handed = async {
            sender.send(content[..1024].to_vec()).await.unwrap();
            hold.until_arrived(1).await;
        };
        tokio::select! {
            staged = &mut staging => panic!("a stage half-sent answered: {staged:?}"),
            () = with_deadline("on its writer", handed) => {}
        }
    }

    hold.release();
    with_deadline("settle", replica.settle()).await;
    let landings = with_deadline("take_landed", replica.take_landed())
        .await
        .unwrap();
    assert_eq!((landings.landed.len(), landings.queued), (0, 0));
    assert!(!site.file(Side::B, "dropped").exists());
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_body_longer_than_its_source_fails_its_stage_before_it_is_all_taken() {
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 1 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    staged(&replica, "busy", b"busy").await;
    let (sender, body) = body_channel(1);
    let feeder = tokio::spawn(async move {
        for _ in 0..64 {
            sender.send(vec![2u8; 1024]).await?;
        }
        sender.finish().await
    });

    let failed = with_deadline(
        "stage",
        replica.stage(
            &path("long"),
            body,
            source_of(vec![2u8; 1024], 0o644),
            Precondition::Absent,
        ),
    )
    .await;

    let Err(ReplicaError::Write(error)) = failed else {
        panic!("{failed:?}");
    };
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    assert!(
        with_deadline("feeder", feeder).await.unwrap().is_err(),
        "the rest of the body was taken"
    );
    assert_eq!(*replica.spool_queued_bytes().unwrap().borrow(), 0);
    hold.release();
    with_deadline("settle", replica.settle()).await;
    assert_eq!(spool_files(&site), Vec::<String>::new());
    assert_eq!(landed(&replica, 1).await, ["busy"]);
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_new_session_never_names_a_spool_file_as_an_old_one_did() {
    let site = Site::new();
    let replica = spooled(&site, tuning(1, 1 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    staged(&replica, "f0", b"zero").await;
    staged(&replica, "f1", b"one").await;
    let old = spool_paths(&site);
    assert_eq!(old.len(), 1);
    drop(replica);

    let fresh = spooled(&site, tuning(1, 1 << 20)).await;
    staged(&fresh, "g0", b"zero").await;
    staged(&fresh, "g1", b"one").await;

    let new = spool_paths(&site);
    assert_eq!(new.len(), 1);
    // A landing the old session left on a writer removes only its own.
    assert_ne!(new, old);
    hold.release();
    let mut order = landed(&fresh, 2).await;
    order.sort();
    assert_eq!(order, ["g0", "g1"]);
    assert_eq!(site.get(Side::B, "g1"), b"one");
    with_deadline("unlock", fresh.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_stage_waiting_behind_the_queue_takes_a_writer_freed_once_the_lander_empties_it() {
    let site = Site::new();
    let replica = Arc::new(spooled(&site, tuning(3, 100)).await);
    let hold = LandingHold::at(&site.root(Side::B));
    // Three plain writes take every writer, their bodies still arriving.
    let mut senders = Vec::new();
    let mut writes = Vec::new();
    for name in ["w0", "w1", "w2"] {
        let (sender, body) = body_channel(1);
        senders.push(sender);
        let replica = replica.clone();
        writes.push(tokio::spawn(async move {
            replica
                .write(
                    &path(name),
                    body,
                    source_of(b"w", 0o644),
                    Precondition::Absent,
                )
                .await
        }));
        hold.release_one();
    }
    with_deadline("writes on their writers", hold.until_arrived(3)).await;
    staged(&replica, "queued", &[3u8; 50]).await;
    assert_eq!(spool_files(&site), ["0"]);
    let large = vec![5u8; 1000];
    let mut waiting = pin!(stage(&replica, "large", &large));
    still_waiting(&mut waiting, "a stage larger than the room").await;

    // Two writers come free, with no landing of the spool's to say so:
    // the Lander takes one for the queued file, held on its writer.
    let mut senders = senders.into_iter();
    let first = senders.next().unwrap();
    for (sender, write) in senders.zip(writes.drain(1..)) {
        sender.send(b"w".to_vec()).await.unwrap();
        sender.finish().await.unwrap();
        with_deadline("write", write).await.unwrap().unwrap();
    }
    with_deadline("queued on its writer", hold.until_held(1)).await;

    // The other is free, and the queue is empty: the large stage takes it.
    with_deadline("large", &mut waiting).await.unwrap();

    hold.release();
    first.send(b"w".to_vec()).await.unwrap();
    first.finish().await.unwrap();
    with_deadline("write", writes.pop().unwrap())
        .await
        .unwrap()
        .unwrap();
    let mut order = landed(&replica, 2).await;
    order.sort();
    assert_eq!(order, ["large", "queued"]);
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

/// Side B served spooled with `tuning` through a link the test can cut,
/// said hello to and locked, with exactly the room asked for.
async fn served_spooled(site: &Site, tuning: Tuning) -> (Served, CutLink) {
    let (served, link) = Served::spooled_through_link(site, Side::B, tuning).await;
    with_deadline("hello", served.replica.hello())
        .await
        .unwrap();
    let facts = with_deadline("lock", served.replica.lock()).await.unwrap();
    assert_eq!(facts.spool_room, tuning.spool_bytes, "the volume is short");
    (served, link)
}

/// Stages `content` at `name`, new on side B, through the link.
async fn staged_through(replica: &RemoteReplica, name: &str, content: &[u8]) {
    let at = path(name);
    let staging = replica.stage(
        &at,
        Body::from_bytes(content.to_vec()),
        source_of(content, 0o644),
        Precondition::Absent,
    );
    with_deadline(name, staging).await.unwrap();
}

fn assert_held(locked: Result<LockFacts, ReplicaError>) {
    assert!(
        matches!(locked, Err(ReplicaError::Lock(LockError::Held { .. }))),
        "{locked:?}"
    );
}

#[tokio::test]
async fn a_served_session_cut_off_lands_every_staged_file_before_its_lock_goes() {
    let site = Site::new();
    let (served, link) = served_spooled(&site, tuning(1, 1 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    let files: [(&str, &[u8]); 3] = [("a", b"first"), ("b", b"second"), ("c", b"third")];
    for (name, content) in files {
        staged_through(&served.replica, name, content).await;
    }
    with_deadline("a on the writer", hold.until_held(1)).await;
    assert_eq!(spool_files(&site), ["0", "1"]);

    link.cut();
    let Served {
        replica,
        mut serving,
    } = served;
    drop(replica);
    let contender = site.replica(Side::B);
    // Each landing in turn, the lock held by the cut session until the
    // last has landed.
    for (landing, (name, _)) in (1..).zip(files) {
        assert_held(with_deadline("a contended lock", contender.lock()).await);
        assert!(still_pending(&mut serving).await, "ended before {name}");
        assert!(!site.file(Side::B, name).exists(), "{name} landed early");
        hold.release_one();
        if landing < files.len() as u64 {
            with_deadline("the next landing", hold.until_arrived(landing + 1)).await;
        }
    }
    with_deadline("the session's end", &mut serving)
        .await
        .unwrap()
        .ok();

    for (name, content) in files {
        assert_eq!(site.get(Side::B, name), content);
    }
    assert_eq!(spool_paths(&site), Vec::<PathBuf>::new());
    assert_eq!(temp_files_under(&site.root(Side::B)), Vec::<PathBuf>::new());
    with_deadline("the lock, once landed", contender.lock())
        .await
        .unwrap();
    with_deadline("unlock", contender.unlock()).await.unwrap();
}

#[tokio::test]
async fn a_served_stage_cut_mid_body_leaves_no_spool_file_and_its_target_untouched() {
    let site = Site::new();
    site.put(Side::B, "cut.bin", b"old bytes");
    let expect = site.expect(Side::B, "cut.bin");
    let (served, link) = served_spooled(&site, tuning(1, 4 << 20)).await;
    let hold = LandingHold::at(&site.root(Side::B));
    staged_through(&served.replica, "busy", b"busy").await;
    with_deadline("busy on the writer", hold.until_held(1)).await;

    // Twice the body's credit and more, so the far side has taken part of
    // it - spilling it, its writer being busy - before the last send goes.
    const CHUNK: usize = 64 * 1024;
    let content = vec![9u8; 32 * CHUNK];
    let (sender, body) = body_channel(1);
    let staging = {
        let replica = served.replica.clone();
        let source = source_of(&content, 0o644);
        tokio::spawn(async move { replica.stage(&path("cut.bin"), body, source, expect).await })
    };
    for chunk in content.chunks(CHUNK).take(12) {
        with_deadline("a chunk", sender.send(chunk.to_vec()))
            .await
            .unwrap();
    }
    // Positive control: the cut stage is spilling.
    assert_eq!(spool_files(&site), ["0"]);

    link.cut();
    let staged = with_deadline("the cut stage", staging).await.unwrap();
    assert!(staged.is_err(), "{staged:?}");
    let Served {
        replica,
        mut serving,
    } = served;
    drop(replica);
    assert!(still_pending(&mut serving).await, "ended with busy held");
    hold.release();
    with_deadline("the session's end", serving)
        .await
        .unwrap()
        .ok();

    assert_eq!(spool_paths(&site), Vec::<PathBuf>::new());
    assert_eq!(site.get(Side::B, "cut.bin"), b"old bytes");
    assert_eq!(site.get(Side::B, "busy"), b"busy");
    assert_eq!(temp_files_under(&site.root(Side::B)), Vec::<PathBuf>::new());
}
