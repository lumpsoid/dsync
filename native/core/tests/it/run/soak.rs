//! The convergence soak (`convergence_soak_test.dart`) and the idempotent
//! second run (`idempotent_second_run_e2e_test.dart`).
//!
//! Each round stages a few random creates, rewrites, resizes and deletes -
//! each path on at most one side - and, one round in four, a deliberate
//! conflict; then syncs in batch mode. A round without a conflict must exit
//! 0 and converge; one with a conflict must exit 1, leave that path exactly
//! as each side had it, and converge everywhere else; once the user makes
//! the two sides agree, the next run is clean. After every sync each
//! archive must describe its own disk exactly.
//!
//! Seeded: `DSYNC_SOAK_SEED` replays a failure (the seed is printed with
//! every round), `DSYNC_SOAK_ROUNDS` lengthens the soak.

use std::collections::BTreeMap;
use std::fs;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use dsync_core::BatchDecider;
use dsync_domain::{ContentHash, ReplicaOp, Side};

use crate::run::support::{Site, run, served, with_deadline};

const DEFAULT_ROUNDS: usize = 12;

/// The paths a soak plays with, and the size each is seeded at. Nested
/// folders, so deletes empty folders and copies create them.
const POOL: [(&str, usize); 10] = [
    ("top.txt", 12),
    ("docs/a.md", 300),
    ("docs/empty", 0),
    ("docs/deep/c.bin", 5000),
    ("docs/deep/d.bin", 70_000),
    ("media/x.jpg", 2048),
    ("media/y.jpg", 1),
    ("media/sub/z.raw", 300_000),
    ("notes/n1", 64),
    ("notes/n2", 4096),
];

/// xorshift64*: small, seedable, and the same on every machine.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    fn coin(&mut self) -> bool {
        self.next() & 1 == 1
    }

    fn bytes(&mut self, size: usize) -> Vec<u8> {
        (0..size).map(|_| self.next() as u8).collect()
    }

    fn size(&mut self) -> usize {
        match self.below(8) {
            0 => 0,
            1 => 256 * 1024 + self.below(2048),
            _ => self.below(4096),
        }
    }
}

fn from_env(name: &str) -> Option<u64> {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
}

#[derive(Clone, Copy, Debug)]
enum Reach {
    Local,
    Served,
}

struct Soak {
    site: Site,
    reach: Reach,
    rng: Rng,
    /// Every write gets a distinct mtime, so a same-size rewrite is always
    /// seen by the fast path's mtime check whatever the clock's grain.
    stamp: u64,
    label: String,
}

/// A staged conflict: what each side must still hold after the run.
struct Conflict {
    path: String,
    on_a: Option<Vec<u8>>,
    on_b: Option<Vec<u8>>,
}

impl Soak {
    fn new(reach: Reach, seed: u64) -> Soak {
        Soak {
            site: Site::new(),
            reach,
            rng: Rng(seed.max(1)),
            stamp: 1_600_000_000,
            label: format!("soak {reach:?} seed {seed} (DSYNC_SOAK_SEED={seed})"),
        }
    }

    fn write(&mut self, side: Side, path: &str, bytes: &[u8]) {
        let file = self.site.put(side, path, bytes);
        self.stamp += 1;
        fs::File::options()
            .write(true)
            .open(&file)
            .unwrap()
            .set_modified(UNIX_EPOCH + Duration::from_secs(self.stamp))
            .unwrap();
    }

    fn remove(&self, side: Side, path: &str) {
        fs::remove_file(self.site.file(side, path)).unwrap();
    }

    async fn sync(&self) -> u8 {
        let site = &self.site;
        let finished = match self.reach {
            Reach::Local => {
                run(
                    site,
                    site.replica(Side::A),
                    site.replica(Side::B),
                    &mut BatchDecider,
                )
                .await
            }
            Reach::Served => {
                let (b, serving) = served(site, Side::B).await;
                let finished = run(site, site.replica(Side::A), b, &mut BatchDecider).await;
                with_deadline("the session's end", serving)
                    .await
                    .unwrap()
                    .unwrap();
                finished
            }
        };
        assert!(
            finished.errors().is_empty(),
            "{}: {:?}",
            self.label,
            finished.errors()
        );
        finished.exit_code()
    }

    async fn run(&mut self, rounds: usize) {
        for (index, (path, size)) in POOL.iter().enumerate() {
            let bytes = self.rng.bytes(*size);
            let side = if index % 2 == 0 { Side::A } else { Side::B };
            self.write(side, path, &bytes);
        }
        eprintln!("{}: round 0 seeds {} paths", self.label, POOL.len());
        assert_eq!(self.sync().await, 0, "{}: the first sync", self.label);
        self.expect_converged(None);
        for round in 1..=rounds {
            self.round(round).await;
        }
    }

    async fn round(&mut self, round: usize) {
        let conflict = self.stage_conflict();
        let staged = self.stage_mutations(conflict.as_ref().map(|c| c.path.clone()));
        eprintln!(
            "{}: round {round}: {}{}",
            self.label,
            staged.join("; "),
            conflict
                .as_ref()
                .map_or(String::new(), |c| format!("; conflict on {}", c.path))
        );
        let code = self.sync().await;
        let Some(conflict) = conflict else {
            assert_eq!(
                code, 0,
                "{} round {round}: a round without a conflict",
                self.label
            );
            self.expect_converged(None);
            return;
        };
        assert_eq!(
            code, 1,
            "{} round {round}: an unresolved conflict exits 1",
            self.label
        );
        for (side, expected) in [(Side::A, &conflict.on_a), (Side::B, &conflict.on_b)] {
            assert_eq!(
                &self.site.get(side, &conflict.path),
                expected,
                "{} round {round}: the conflict on {} moved on {side}",
                self.label,
                conflict.path
            );
        }
        self.expect_converged(Some(&conflict.path));
        // The user makes the sides agree: the next run commits it.
        match conflict.on_a {
            Some(bytes) => self.write(Side::B, &conflict.path, &bytes),
            None => self.remove(Side::B, &conflict.path),
        }
        assert_eq!(
            self.sync().await,
            0,
            "{} round {round}: once resolved",
            self.label
        );
        self.expect_converged(None);
    }

    fn stage_mutations(&mut self, exclude: Option<String>) -> Vec<String> {
        let present = self.site.tree(Side::A);
        let mut paths: Vec<&str> = POOL
            .iter()
            .map(|(path, _)| *path)
            .filter(|path| exclude.as_deref() != Some(*path))
            .collect();
        for i in (1..paths.len()).rev() {
            paths.swap(i, self.rng.below(i + 1));
        }
        let count = 1 + self.rng.below(4);
        let mut staged = Vec::new();
        for path in paths.into_iter().take(count) {
            let side = if self.rng.coin() { Side::A } else { Side::B };
            let Some(current) = present.get(path) else {
                let size = self.rng.size();
                let bytes = self.rng.bytes(size);
                self.write(side, path, &bytes);
                staged.push(format!("created {path} ({size} B) on {side}"));
                continue;
            };
            match self.rng.below(4) {
                0 => {
                    self.remove(side, path);
                    staged.push(format!("deleted {path} on {side}"));
                }
                1 if !current.is_empty() => {
                    let bytes = self.rng.bytes(current.len());
                    self.write(side, path, &bytes);
                    staged.push(format!("rewrote {path} in place on {side}"));
                }
                _ => {
                    let mut size = self.rng.size();
                    if size == current.len() {
                        size += 1;
                    }
                    let bytes = self.rng.bytes(size);
                    self.write(side, path, &bytes);
                    staged.push(format!("resized {path} to {size} B on {side}"));
                }
            }
        }
        staged
    }

    fn stage_conflict(&mut self) -> Option<Conflict> {
        if self.rng.below(4) != 0 {
            return None;
        }
        let present = self.site.tree(Side::A);
        let shared: Vec<&String> = present.keys().collect();
        let absent: Vec<&str> = POOL
            .iter()
            .map(|(path, _)| *path)
            .filter(|path| !present.contains_key(*path))
            .collect();
        let mut kinds = Vec::new();
        if !shared.is_empty() {
            kinds.extend(["both edit", "edit versus delete"]);
        }
        if !absent.is_empty() {
            kinds.push("both create");
        }
        let unlike = |rng: &mut Rng, lengths: &[usize]| {
            let mut size = rng.size();
            while lengths.contains(&size) {
                size += 1;
            }
            rng.bytes(size)
        };
        match kinds[self.rng.below(kinds.len())] {
            "both create" => {
                let path = absent[self.rng.below(absent.len())].to_owned();
                let on_a = unlike(&mut self.rng, &[]);
                let on_b = unlike(&mut self.rng, &[on_a.len()]);
                self.write(Side::A, &path, &on_a);
                self.write(Side::B, &path, &on_b);
                Some(Conflict {
                    path,
                    on_a: Some(on_a),
                    on_b: Some(on_b),
                })
            }
            "both edit" => {
                let path = shared[self.rng.below(shared.len())].clone();
                let current = present[&path].len();
                let on_a = unlike(&mut self.rng, &[current]);
                let on_b = unlike(&mut self.rng, &[current, on_a.len()]);
                self.write(Side::A, &path, &on_a);
                self.write(Side::B, &path, &on_b);
                Some(Conflict {
                    path,
                    on_a: Some(on_a),
                    on_b: Some(on_b),
                })
            }
            _ => {
                let path = shared[self.rng.below(shared.len())].clone();
                let delete_on_a = self.rng.coin();
                let (editor, deleter) = if delete_on_a {
                    (Side::B, Side::A)
                } else {
                    (Side::A, Side::B)
                };
                let edited = unlike(&mut self.rng, &[present[&path].len()]);
                self.write(editor, &path, &edited);
                self.remove(deleter, &path);
                Some(Conflict {
                    path,
                    on_a: (!delete_on_a).then(|| edited.clone()),
                    on_b: delete_on_a.then_some(edited),
                })
            }
        }
    }

    /// Both trees hold the same files, and each archive describes its own
    /// disk exactly: an entry missing makes the next scan report a create,
    /// one stale a change that already synced (SPEC §5.2, §7.3).
    fn expect_converged(&self, exempt: Option<&str>) {
        let mut trees = [self.site.tree(Side::A), self.site.tree(Side::B)];
        for tree in &mut trees {
            if let Some(path) = exempt {
                tree.remove(path);
            }
        }
        assert_eq!(
            trees[0].keys().collect::<Vec<_>>(),
            trees[1].keys().collect::<Vec<_>>(),
            "{}: the replicas hold different paths",
            self.label
        );
        assert!(
            trees[0] == trees[1],
            "{}: the replicas hold different content",
            self.label
        );
        for (side, tree) in Side::BOTH.into_iter().zip(&trees) {
            let archive = self.site.archive(side);
            let archived: BTreeMap<String, (u64, i64, ContentHash)> = archive
                .entries()
                .filter(|(path, _)| Some(path.as_str()) != exempt)
                .map(|(path, file)| {
                    (
                        path.as_str().to_owned(),
                        (file.meta.size, file.meta.mtime_us, file.hash),
                    )
                })
                .collect();
            let on_disk: BTreeMap<String, (u64, i64, ContentHash)> = tree
                .iter()
                .map(|(path, bytes)| {
                    let modified = fs::metadata(self.site.file(side, path))
                        .unwrap()
                        .modified()
                        .unwrap();
                    (
                        path.clone(),
                        (bytes.len() as u64, micros(modified), hash(bytes)),
                    )
                })
                .collect();
            assert_eq!(
                archived, on_disk,
                "{}: {side}'s archive against its disk",
                self.label
            );
        }
    }
}

fn micros(at: SystemTime) -> i64 {
    i64::try_from(at.duration_since(UNIX_EPOCH).unwrap().as_micros()).unwrap()
}

fn hash(bytes: &[u8]) -> ContentHash {
    let digest = ring::digest::digest(&ring::digest::SHA256, bytes);
    ContentHash::from_digest(digest.as_ref().try_into().unwrap())
}

async fn soak(reach: Reach) {
    let rounds = from_env("DSYNC_SOAK_ROUNDS").map_or(DEFAULT_ROUNDS, |r| r as usize);
    let seed = from_env("DSYNC_SOAK_SEED").unwrap_or_else(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .subsec_nanos()
            .into()
    });
    let mut soak = Soak::new(reach, seed);
    eprintln!("{}: {rounds} rounds", soak.label);
    soak.run(rounds).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn every_round_converges_local_to_local() {
    soak(Reach::Local).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn every_round_converges_over_the_protocol() {
    soak(Reach::Served).await;
}

#[tokio::test]
async fn a_second_run_against_an_unchanged_pair_is_a_true_no_op() {
    let site = Site::new();
    site.put(Side::A, "a/one", "1");
    site.put(Side::B, "b/two", "22");
    site.put(Side::A, "top", "");
    let first = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut BatchDecider,
    )
    .await;
    assert_eq!(first.exit_code(), 0);
    let logs = |site: &Site| Side::BOTH.map(|side| fs::read(site.log(side)).unwrap());
    let before = logs(&site);

    let second = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut BatchDecider,
    )
    .await;

    assert_eq!(second.exit_code(), 0);
    assert!(second.results().is_empty());
    assert_eq!(logs(&site), before, "the archives were not rewritten");
    let metrics = &second.report.metrics;
    for side in Side::BOTH {
        assert!(!metrics.replica(side).ops.contains_key(&ReplicaOp::Commit));
        assert!(!metrics.replica(side).ops.contains_key(&ReplicaOp::Compact));
    }
    // Positive control: the first run did commit.
    assert!(first.report.metrics.a.ops.contains_key(&ReplicaOp::Commit));
}
