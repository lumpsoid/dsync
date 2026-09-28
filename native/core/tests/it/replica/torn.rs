//! A copy written in place and torn at every point it has (SPEC §7.6,
//! Dart's `torn_write_test`), driven over `LocalReplica` in SPEC's order:
//! intent, write, upserts. A write that never started, or that finished
//! and lost only its commits, converges on the next run. One that left a
//! partial file comes back as a conflict labelled interrupted - a partial
//! file and a user's edit look the same on disk - and nothing on B is ever
//! copied over A.
//!
//! A "run" is fresh replicas over the same roots and state dir. A killed
//! run is a real killed process, or replicas ended by [`killed`]: their
//! locks released and nothing buffered flushed, which is what a dead
//! process leaves.

use std::path::Path;

use dsync_core::{LocalReplica, Replica, body_channel};
use dsync_domain::{Action, ArchiveCommit, Side, Status};

use crate::replica::child::{ChildProcess, READY, wait_for_parent};
use crate::replica::support::{
    Site, apply, exchange, failing_body, hash_of, meta, path, seed, with_deadline,
};

/// Long enough that every tear point is a different file, and unlike
/// [`OLD`] at every length.
const SOURCE: &[u8] = b"the source content, version two - the source content, version two";
const OLD: &[u8] = b"old";

/// The cells of SPEC §7.6 a tear can happen in, each leaving the next run
/// to copy `f` from A to B.
#[derive(Clone, Copy, Debug)]
enum Cell {
    /// B unchanged, A modified.
    OrdinaryPull,
    /// A created, B never saw it.
    FirstSync,
}

const CELLS: [Cell; 2] = [Cell::OrdinaryPull, Cell::FirstSync];

async fn arrange(cell: Cell) -> Site {
    let site = Site::new();
    if let Cell::OrdinaryPull = cell {
        site.put(Side::A, "f", OLD);
        site.put(Side::B, "f", OLD);
        seed(&site.locked(Side::A).await).await;
        seed(&site.locked(Side::B).await).await;
    }
    site.put(Side::A, "f", SOURCE);
    site
}

/// Ends `replicas` as a killed process would: their locks go, and every
/// commit they still buffer goes with them - each log stays as it was on
/// disk.
fn killed(site: &Site, replicas: (LocalReplica, LocalReplica)) {
    let on_disk = Side::BOTH.map(|side| (site.log(side), std::fs::read(site.log(side)).ok()));
    drop(replicas);
    for (log, bytes) in on_disk {
        match bytes {
            Some(bytes) => std::fs::write(log, bytes).unwrap(),
            None => {
                let _ = std::fs::remove_file(log);
            }
        }
    }
}

/// The run that tears: the plan copies `f` to B, B's mark goes down
/// durably, then `tear` does whatever it does to the write.
async fn torn_run<F, T>(site: &Site, tear: F) -> (LocalReplica, LocalReplica)
where
    F: AsyncFnOnce(&LocalReplica) -> T,
{
    let a = site.locked(Side::A).await;
    let b = site.locked(Side::B).await;
    let exchanged = exchange(&a, &b).await;
    assert_eq!(
        exchanged.actions(),
        [Action::Copy {
            path: path("f"),
            from: Side::A,
            bytes: SOURCE.len() as u64,
        }]
    );
    b.commit(vec![ArchiveCommit::Intent(path("f"))])
        .await
        .unwrap();
    tear(&b).await;
    (a, b)
}

/// The run after a tear that left a partial file on B, and the one after
/// it: `f` is a conflict labelled interrupted, B is not copied over A, and
/// the mark stays until the user settles it.
async fn expect_interrupted(site: &Site) {
    for _ in 0..2 {
        let a = site.locked(Side::A).await;
        let b = site.locked(Side::B).await;
        let exchanged = exchange(&a, &b).await;
        let [conflict] = exchanged.plan.conflicts.as_slice() else {
            panic!("expected one conflict: {:?}", exchanged.plan);
        };
        assert_eq!(conflict.path, path("f"));
        assert!(conflict.interrupted());
        assert!(matches!(conflict.b, Some(Status::Untrusted(_))));
        assert!(exchanged.plan.actions.is_empty(), "neither side is written");
        assert_eq!(site.get(Side::A, "f"), SOURCE, "A is untouched");
        assert!(site.archive(Side::B).is_untrusted(&path("f")));
        apply(&a, &b, &exchanged).await;
    }
}

/// The run after a tear that converges by itself: `f` lands on B, nothing
/// comes back to A, and the run after that finds nothing to do.
async fn expect_converges(site: &Site) {
    let a = site.locked(Side::A).await;
    let b = site.locked(Side::B).await;
    let recovery = exchange(&a, &b).await;
    assert!(recovery.plan.conflicts.is_empty(), "{:?}", recovery.plan);
    assert!(
        !recovery
            .plan
            .actions
            .iter()
            .any(|proposal| matches!(proposal.action, Action::Copy { from: Side::B, .. })),
        "nothing on B is ever copied back over A"
    );
    apply(&a, &b, &recovery).await;
    assert_eq!(site.get(Side::A, "f"), SOURCE);
    assert_eq!(site.get(Side::B, "f"), SOURCE);

    let settled = exchange(&a, &b).await;
    assert!(settled.plan.actions.is_empty(), "{:?}", settled.plan);
    assert!(settled.plan.conflicts.is_empty());
    let archive = site.archive(Side::B);
    assert_eq!(archive.untrusted().count(), 0);
    assert_eq!(
        archive.get(&path("f")).map(|f| f.hash),
        Some(hash_of(SOURCE))
    );
}

#[tokio::test]
async fn a_body_failing_part_way_leaves_an_interrupted_conflict() {
    for cell in CELLS {
        for at in [0, 1, SOURCE.len() / 2, SOURCE.len() - 1] {
            let site = with_deadline("arrange", arrange(cell)).await;
            with_deadline("tear and recover", async {
                torn_run(&site, async |b: &LocalReplica| {
                    let body = failing_body(&SOURCE[..at]).await;
                    let expect = site.expect(Side::B, "f");
                    let written = b.write(&path("f"), body, meta(0o644), expect).await;
                    assert!(written.is_err(), "{cell:?} at {at}");
                })
                .await;
                assert_eq!(site.get(Side::B, "f"), &SOURCE[..at], "{cell:?} at {at}");
                expect_interrupted(&site).await;
            })
            .await;
        }
    }
}

#[tokio::test]
async fn killed_after_the_mark_before_the_write_converges() {
    for cell in CELLS {
        let site = with_deadline("arrange", arrange(cell)).await;
        with_deadline("tear and recover", async {
            let (a, b) = torn_run(&site, async |_: &LocalReplica| {}).await;
            killed(&site, (a, b));
            assert!(site.archive(Side::B).is_untrusted(&path("f")));
            expect_converges(&site).await;
        })
        .await;
    }
}

#[tokio::test]
async fn a_write_whose_commit_batch_is_lost_converges() {
    for cell in CELLS {
        let site = with_deadline("arrange", arrange(cell)).await;
        with_deadline("tear and recover", async {
            let (a, b) = torn_run(&site, async |b: &LocalReplica| {
                let body = a_whole_body();
                let expect = site.expect(Side::B, "f");
                b.write(&path("f"), body, meta(0o644), expect)
                    .await
                    .unwrap();
            })
            .await;
            // The upserts never reach either replica; the run ends cleanly.
            a.unlock().await.unwrap();
            b.unlock().await.unwrap();
            expect_converges(&site).await;
        })
        .await;
    }
}

#[tokio::test]
async fn a_write_killed_before_its_commits_are_flushed_converges() {
    for cell in CELLS {
        let site = with_deadline("arrange", arrange(cell)).await;
        with_deadline("tear and recover", async {
            let (a, b) = torn_run(&site, async |b: &LocalReplica| {
                let expect = site.expect(Side::B, "f");
                let landed = b
                    .write(&path("f"), a_whole_body(), meta(0o644), expect)
                    .await
                    .unwrap();
                b.commit(vec![ArchiveCommit::Upsert {
                    path: path("f"),
                    file: dsync_domain::FileState {
                        meta: landed,
                        hash: hash_of(SOURCE),
                    },
                }])
                .await
                .unwrap();
            })
            .await;
            // Killed: the buffered upsert dies with the process.
            killed(&site, (a, b));
            assert!(site.archive(Side::B).is_untrusted(&path("f")));
            expect_converges(&site).await;
        })
        .await;
    }
}

#[tokio::test]
async fn a_compaction_with_a_mark_open_carries_the_mark() {
    let site = with_deadline("arrange", arrange(Cell::OrdinaryPull)).await;
    with_deadline("tear, compact and recover", async {
        let (a, b) = torn_run(&site, async |b: &LocalReplica| {
            let body = failing_body(&SOURCE[..3]).await;
            let expect = site.expect(Side::B, "f");
            assert!(
                b.write(&path("f"), body, meta(0o644), expect)
                    .await
                    .is_err()
            );
        })
        .await;
        b.compact().await.unwrap();
        a.unlock().await.unwrap();
        b.unlock().await.unwrap();
        let log = std::fs::read_to_string(site.log(Side::B)).unwrap();
        assert_eq!(log.lines().filter(|l| l.contains("\"intent\"")).count(), 1);
        expect_interrupted(&site).await;
    })
    .await;
}

#[tokio::test]
async fn a_users_edit_to_a_marked_file_after_a_crash_is_a_conflict_never_overwritten() {
    let site = with_deadline("arrange", arrange(Cell::OrdinaryPull)).await;
    with_deadline("crash, edit and recover", async {
        let (a, b) = torn_run(&site, async |_: &LocalReplica| {}).await;
        killed(&site, (a, b));
        site.put(Side::B, "f", "the user's edit, made after the crash");

        let a = site.locked(Side::A).await;
        let b = site.locked(Side::B).await;
        let next = exchange(&a, &b).await;

        assert!(next.plan.conflicts[0].interrupted());
        assert!(next.plan.actions.is_empty());
        assert_eq!(
            site.get(Side::B, "f"),
            b"the user's edit, made after the crash"
        );
    })
    .await;
}

fn a_whole_body() -> dsync_core::Body {
    dsync_core::Body::from_bytes(SOURCE.to_vec())
}

/// The child's half of the kill test: marks `f` on B, starts writing
/// [`SOURCE`] in place, and stops the body half-way until it is killed.
pub fn tear_write(dir: &Path) {
    let site = Site::at(dir);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let b = site.locked(Side::B).await;
        b.commit(vec![ArchiveCommit::Intent(path("f"))])
            .await
            .unwrap();
        let (sender, body) = body_channel(1);
        let expect = site.expect(Side::B, "f");
        let _write =
            tokio::spawn(async move { b.write(&path("f"), body, meta(0o644), expect).await });
        sender
            .send(SOURCE[..SOURCE.len() / 2].to_vec())
            .await
            .unwrap();
        // Absent until the write creates it, on a first sync.
        let half = Some(&SOURCE[..SOURCE.len() / 2]);
        while std::fs::read(site.file(Side::B, "f")).ok().as_deref() != half {
            tokio::task::yield_now().await;
        }
        println!("{READY}");
        tokio::task::spawn_blocking(wait_for_parent).await.unwrap();
        panic!("the parent kills this child before releasing it");
    });
}

#[tokio::test(flavor = "multi_thread")]
async fn a_process_killed_mid_write_leaves_the_path_untrusted_and_its_bytes_never_trusted() {
    for cell in CELLS {
        let site = with_deadline("arrange", arrange(cell)).await;

        let mut child = ChildProcess::spawn("tear-write", site.dir());
        child.wait_until_ready();
        child.kill();
        child.wait();

        let torn = &SOURCE[..SOURCE.len() / 2];
        assert_eq!(site.get(Side::B, "f"), torn, "{cell:?}: torn on disk");
        let archive = site.archive(Side::B);
        assert!(archive.is_untrusted(&path("f")));
        assert_ne!(
            archive.get(&path("f")).map(|f| f.hash),
            Some(hash_of(torn)),
            "the partial bytes are never recorded"
        );
        with_deadline("recovery", expect_interrupted(&site)).await;
    }
}
