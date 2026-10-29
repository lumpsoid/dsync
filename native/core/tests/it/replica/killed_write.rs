//! A copy killed at every point it has (SPEC §7.2, §7.6), driven over
//! `LocalReplica` in SPEC's order: write, upserts. The bytes land in a temp
//! in the staging folder and reach the target only by the rename, so a
//! write that stops anywhere leaves the old file whole - or no file, on a
//! first sync - and the next run copies it again. Nothing on B is ever
//! copied over A, and no run reports a conflict.
//!
//! A "run" is fresh replicas over the same roots and state dir. A killed
//! run is a real killed process, or replicas ended by [`killed`]: their
//! locks released and nothing buffered flushed, which is what a dead
//! process leaves.

use std::path::{Path, PathBuf};

use dsync_core::{LocalReplica, Replica, body_channel};
use dsync_domain::{Action, ArchiveCommit, STAGING_DIR, Side};

use crate::replica::child::{ChildProcess, READY, wait_for_parent};
use crate::replica::support::{
    Site, apply, exchange, failing_body, hash_of, meta, path, seed, temp_files_under, with_deadline,
};

/// Long enough that every kill point is a different file, and unlike
/// [`OLD`] at every length.
const SOURCE: &[u8] = b"the source content, version two - the source content, version two";
const OLD: &[u8] = b"old";

/// The cells a kill can happen in, each leaving the next run to copy `f`
/// from A to B.
#[derive(Clone, Copy, Debug)]
enum Cell {
    /// B unchanged, A modified.
    OrdinaryPull,
    /// A created, B never saw it.
    FirstSync,
}

const CELLS: [Cell; 2] = [Cell::OrdinaryPull, Cell::FirstSync];

impl Cell {
    /// What B's `f` holds before the copy, and after any copy that did not
    /// finish.
    fn before(self) -> Option<&'static [u8]> {
        match self {
            Cell::OrdinaryPull => Some(OLD),
            Cell::FirstSync => None,
        }
    }
}

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

fn on_b(site: &Site) -> Option<Vec<u8>> {
    std::fs::read(site.file(Side::B, "f")).ok()
}

fn staging(site: &Site) -> PathBuf {
    site.root(Side::B).join(STAGING_DIR)
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

/// The run that is killed: the plan copies `f` to B, then `kill` does
/// whatever it does to the write.
async fn killed_run<F, T>(site: &Site, kill: F) -> (LocalReplica, LocalReplica)
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
    kill(&b).await;
    (a, b)
}

/// The run after a killed one: `f` lands on B, nothing comes back to A,
/// the staging folder is gone, and the run after that finds nothing to do.
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
    assert_eq!(
        site.archive(Side::B).get(&path("f")).map(|f| f.hash),
        Some(hash_of(SOURCE))
    );
    a.unlock().await.unwrap();
    b.unlock().await.unwrap();
    assert!(!staging(site).exists(), "unlock clears the staging folder");
}

#[tokio::test]
async fn a_body_failing_part_way_leaves_the_old_file_whole() {
    for cell in CELLS {
        for at in [0, 1, SOURCE.len() / 2, SOURCE.len() - 1] {
            let site = with_deadline("arrange", arrange(cell)).await;
            with_deadline("kill and recover", async {
                let (a, b) = killed_run(&site, async |b: &LocalReplica| {
                    let body = failing_body(&SOURCE[..at]).await;
                    let expect = site.expect(Side::B, "f");
                    let written = b.write(&path("f"), body, meta(0o644), expect).await;
                    assert!(written.is_err(), "{cell:?} at {at}");
                })
                .await;
                assert_eq!(on_b(&site).as_deref(), cell.before(), "{cell:?} at {at}");
                assert_eq!(
                    temp_files_under(&site.root(Side::B)),
                    Vec::<PathBuf>::new(),
                    "a failed write removes its temp"
                );
                a.unlock().await.unwrap();
                b.unlock().await.unwrap();
                expect_converges(&site).await;
            })
            .await;
        }
    }
}

#[tokio::test]
async fn a_write_whose_commit_batch_is_lost_converges() {
    for cell in CELLS {
        let site = with_deadline("arrange", arrange(cell)).await;
        with_deadline("kill and recover", async {
            let (a, b) = killed_run(&site, async |b: &LocalReplica| {
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
        with_deadline("kill and recover", async {
            let (a, b) = killed_run(&site, async |b: &LocalReplica| {
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
            expect_converges(&site).await;
        })
        .await;
    }
}

fn a_whole_body() -> dsync_core::Body {
    dsync_core::Body::from_bytes(SOURCE.to_vec())
}

/// The child's half of the kill test: starts writing [`SOURCE`] to B's `f`
/// and stops the body half-way, once those bytes are in the temp, until it
/// is killed.
pub fn tear_write(dir: &Path) {
    let site = Site::at(dir);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let b = site.locked(Side::B).await;
        let (sender, body) = body_channel(1);
        let expect = site.expect(Side::B, "f");
        let _write =
            tokio::spawn(async move { b.write(&path("f"), body, meta(0o644), expect).await });
        sender
            .send(SOURCE[..SOURCE.len() / 2].to_vec())
            .await
            .unwrap();
        let half = &SOURCE[..SOURCE.len() / 2];
        let staged = || {
            temp_files_under(&site.root(Side::B))
                .iter()
                .any(|temp| std::fs::read(temp).ok().as_deref() == Some(half))
        };
        while !staged() {
            tokio::task::yield_now().await;
        }
        println!("{READY}");
        tokio::task::spawn_blocking(wait_for_parent).await.unwrap();
        panic!("the parent kills this child before releasing it");
    });
}

#[tokio::test(flavor = "multi_thread")]
async fn a_process_killed_mid_write_leaves_the_old_file_whole_and_its_temp_swept() {
    for cell in CELLS {
        let site = with_deadline("arrange", arrange(cell)).await;

        let mut child = ChildProcess::spawn("tear-write", site.dir());
        child.wait_until_ready();
        child.kill();
        child.wait();

        assert_eq!(on_b(&site).as_deref(), cell.before(), "{cell:?}: target");
        let temps = temp_files_under(&site.root(Side::B));
        let [temp] = temps.as_slice() else {
            panic!("{cell:?}: one temp left in the staging folder");
        };
        assert!(temp.starts_with(staging(&site)), "{temp:?}");
        assert_eq!(
            site.archive(Side::B).get(&path("f")).is_some(),
            cell.before().is_some()
        );

        let b = site.locked(Side::B).await;
        assert!(!staging(&site).exists(), "{cell:?}: swept at lock");
        b.unlock().await.unwrap();
        with_deadline("recovery", expect_converges(&site)).await;
    }
}
