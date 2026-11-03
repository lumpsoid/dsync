//! Fixtures for the replica tests: two replica roots and a state dir in a
//! temp dir, the deadline every async test runs under, and the exchange and
//! copy a run would drive, in SPEC order, over any [`Replica`], local or
//! remote.

use std::fs;
use std::future::Future;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use dsync_core::{
    ArchiveHeader, ArchiveStore, Body, LocalReplica, Replica, StateDir, body_channel,
};
use dsync_domain::{
    Action, Archive, ArchiveCommit, BucketCount, ContentHash, EntryId, FileMeta, FileState, Jobs,
    Plan, Precondition, RelPath, RootKind, RuleSet, ScanEntry, Side, Status, Tuning,
    UnreadablePaths, is_temp_file_name, reconcile, status_list,
};
use tempfile::TempDir;

/// Every async test's own deadline: a few seconds, far above what any of
/// them takes.
pub const DEADLINE: Duration = Duration::from_secs(5);

pub async fn with_deadline<T>(label: &str, work: impl Future<Output = T>) -> T {
    tokio::time::timeout(DEADLINE, work)
        .await
        .unwrap_or_else(|_| panic!("{label} did not finish within {DEADLINE:?}"))
}

pub const PROFILE: &str = "0123456789abcdef0123456789abcdef";
/// A second profile: another pair that shares a folder with [`PROFILE`]'s.
pub const OTHER_PROFILE: &str = "fedcba9876543210fedcba9876543210";

pub fn path(text: &str) -> RelPath {
    RelPath::parse(text).unwrap()
}

pub fn hash_of(content: impl AsRef<[u8]>) -> ContentHash {
    let digest = ring::digest::digest(&ring::digest::SHA256, content.as_ref());
    ContentHash::from_digest(digest.as_ref().try_into().unwrap())
}

/// An archive record of `content`, with arbitrary metadata.
pub fn recorded(content: &str) -> FileState {
    FileState {
        meta: FileMeta {
            size: content.len() as u64,
            mtime_us: 1,
            mode: 0o644,
        },
        hash: hash_of(content),
    }
}

/// 2024-01-01T00:00:00Z.
pub const MTIME_US: i64 = 1_704_067_200_000_000;

/// A write's source, scanned holding `content`: `mode`, at [`MTIME_US`].
pub fn source_of(content: impl AsRef<[u8]>, mode: u32) -> FileState {
    FileState {
        meta: FileMeta {
            size: content.as_ref().len() as u64,
            mtime_us: MTIME_US,
            mode,
        },
        hash: hash_of(content),
    }
}

/// A body that delivers `prefix`, then fails the way a read that broke
/// part-way does.
pub async fn failing_body(prefix: &[u8]) -> Body {
    let (sender, body) = body_channel(2);
    if !prefix.is_empty() {
        sender.send(prefix.to_vec()).await.unwrap();
    }
    sender.fail(io::Error::other("boom")).await.unwrap();
    body
}

/// Two replica roots, `a` and `b`, and the state dir both sides' archives
/// and locks live in.
pub struct Site {
    dir: PathBuf,
    /// Removes `dir` on drop, for the site a test made.
    _owned: Option<TempDir>,
}

impl Site {
    pub fn new() -> Site {
        let owned = tempfile::tempdir().unwrap();
        let site = Site {
            dir: owned.path().to_path_buf(),
            _owned: Some(owned),
        };
        fs::create_dir(site.root(Side::A)).unwrap();
        fs::create_dir(site.root(Side::B)).unwrap();
        site
    }

    /// The site a parent test made at `dir`, for a child process.
    pub fn at(dir: &Path) -> Site {
        Site {
            dir: dir.to_path_buf(),
            _owned: None,
        }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn root(&self, side: Side) -> PathBuf {
        self.dir.join(side.to_string())
    }

    pub fn state(&self) -> StateDir {
        StateDir::new(self.dir.join("state"))
    }

    pub fn file(&self, side: Side, relative: &str) -> PathBuf {
        self.root(side).join(relative)
    }

    /// Writes `content` at `relative` on `side`, creating its folders.
    pub fn put(&self, side: Side, relative: &str, content: impl AsRef<[u8]>) -> PathBuf {
        let file = self.file(side, relative);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, content).unwrap();
        file
    }

    pub fn get(&self, side: Side, relative: &str) -> Vec<u8> {
        fs::read(self.file(side, relative)).unwrap()
    }

    pub fn replica(&self, side: Side) -> LocalReplica {
        self.replica_with(side, Tuning::DEFAULT)
    }

    /// `side`'s replica with its lock taken, as a run holds it: the
    /// archive is read only under the lock.
    pub async fn locked(&self, side: Side) -> LocalReplica {
        let replica = self.replica(side);
        with_deadline("lock", replica.lock()).await.unwrap();
        replica
    }

    pub fn replica_with(&self, side: Side, tuning: Tuning) -> LocalReplica {
        self.replica_at(&self.root(side), PROFILE, side, tuning)
    }

    /// The replica at `root`, side `side` of `profile`, in this site's
    /// state dir.
    pub fn replica_at(
        &self,
        root: &Path,
        profile: &str,
        side: Side,
        tuning: Tuning,
    ) -> LocalReplica {
        LocalReplica::open(
            dsync_core::Root::folder(root.to_str().unwrap().to_owned()),
            self.state(),
            EntryId::parse(profile).unwrap(),
            side,
            Jobs::DEFAULT,
            tuning,
            dsync_core::Symlinks::AsRuled,
        )
    }

    pub fn log(&self, side: Side) -> PathBuf {
        self.state()
            .archive_log(&EntryId::parse(PROFILE).unwrap(), side)
    }

    /// `side`'s archive as the next run would read it off disk.
    pub fn archive(&self, side: Side) -> Archive {
        let header = ArchiveHeader {
            entry_id: EntryId::parse(PROFILE).unwrap(),
            root_path: self.root(side).to_str().unwrap().to_owned(),
        };
        ArchiveStore::open(self.log(side), header, &Tuning::DEFAULT)
            .unwrap()
            .archive()
            .clone()
    }

    /// What is on disk at `relative` on `side`, as a scan would record it.
    /// What a scan would see at `relative` on `side` now: the precondition
    /// a write or delete there carries (SPEC §7.6).
    pub fn expect(&self, side: Side, relative: &str) -> Precondition {
        expect_at(&self.file(side, relative))
    }

    pub fn state_of(&self, side: Side, relative: &str) -> FileState {
        let file = self.file(side, relative);
        let metadata = fs::metadata(&file).unwrap();
        let mtime = metadata.modified().unwrap().duration_since(UNIX_EPOCH);
        FileState {
            meta: FileMeta {
                size: metadata.len(),
                mtime_us: i64::try_from(mtime.unwrap().as_micros()).unwrap(),
                mode: mode_of(&metadata),
            },
            hash: hash_of(fs::read(&file).unwrap()),
        }
    }
}

/// What a scan would see at `file` now: the precondition a write or
/// delete there carries (SPEC §7.6).
pub fn expect_at(file: &Path) -> Precondition {
    match fs::metadata(file) {
        Ok(metadata) => {
            let mtime = metadata.modified().unwrap().duration_since(UNIX_EPOCH);
            Precondition::File {
                size: metadata.len(),
                mtime_us: i64::try_from(mtime.unwrap().as_micros()).unwrap(),
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Precondition::Absent,
        Err(error) => panic!("stat {}: {error}", file.display()),
    }
}

#[cfg(unix)]
pub fn mode_of(metadata: &fs::Metadata) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    metadata.permissions().mode() & 0o7777
}

#[cfg(not(unix))]
pub fn mode_of(_: &fs::Metadata) -> u32 {
    0o644
}

#[cfg(unix)]
pub fn set_mode(file: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(file, fs::Permissions::from_mode(mode)).unwrap();
}

/// Scratch files (SPEC §7.2) anywhere under `dir`. A write that finished,
/// or failed, leaves none.
pub fn temp_files_under(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for entry in fs::read_dir(dir).unwrap() {
        let entry = entry.unwrap();
        let kind = entry.file_type().unwrap();
        if kind.is_dir() {
            found.extend(temp_files_under(&entry.path()));
        } else if is_temp_file_name(&entry.file_name().to_string_lossy()) {
            found.push(entry.path());
        }
    }
    found
}

/// Both sides' status lists after SPEC §6.1's three-phase exchange, and
/// the plan reconciling them.
pub struct Exchanged {
    pub plan: Plan,
    pub a: Vec<ScanEntry>,
    pub b: Vec<ScanEntry>,
}

impl Exchanged {
    pub fn status(&self, side: Side, relative: &str) -> Option<Status> {
        let list = match side {
            Side::A => &self.a,
            Side::B => &self.b,
        };
        list.iter()
            .find(|entry| entry.path.as_str() == relative)
            .map(|entry| entry.status)
    }

    /// The plan's actions, without their reversals.
    pub fn actions(&self) -> Vec<Action> {
        self.plan.actions.iter().map(|p| p.action.clone()).collect()
    }
}

/// Scans both replicas and exchanges the scans the way a run does.
pub async fn exchange(a: &impl Replica, b: &impl Replica) -> Exchanged {
    let rules = RuleSet::default();
    let opened_a = a.open_scan(&rules).await.unwrap();
    let opened_b = b.open_scan(&rules).await.unwrap();
    let count = BucketCount::for_entries(
        opened_a
            .changed
            .tally
            .total()
            .max(opened_b.changed.tally.total()),
    );
    let digested_a = a
        .scan_digests(opened_a.next, count, &opened_b.changed.paths())
        .await
        .unwrap();
    let digested_b = b
        .scan_digests(opened_b.next, count, &opened_a.changed.paths())
        .await
        .unwrap();
    let disagreeing = digested_a
        .digests
        .disagreeing_with(&digested_b.digests)
        .unwrap();
    let fetched_a = a
        .scan_buckets(&digested_a.next, &disagreeing)
        .await
        .unwrap();
    let fetched_b = b
        .scan_buckets(&digested_b.next, &disagreeing)
        .await
        .unwrap();
    let unreadable = UnreadablePaths::new(
        opened_a
            .changed
            .unreadable()
            .roots()
            .iter()
            .chain(opened_b.changed.unreadable().roots())
            .cloned(),
    );
    let list_a = status_list(opened_a.changed.entries, digested_a.owed, fetched_a);
    let list_b = status_list(opened_b.changed.entries, digested_b.owed, fetched_b);
    Exchanged {
        plan: reconcile(
            list_a.clone(),
            list_b.clone(),
            &unreadable,
            &dsync_domain::UnfinishedApply::default(),
            RootKind::Folder,
        ),
        a: list_a,
        b: list_b,
    }
}

/// Records every file `replica`, locked, holds as synced: what a first run
/// that found both sides already equal leaves behind. Locked again after,
/// for the run that follows it.
pub async fn seed(replica: &impl Replica) {
    let opened = replica.open_scan(&RuleSet::default()).await.unwrap();
    let upserts = opened
        .changed
        .entries
        .iter()
        .filter_map(|entry| match entry.status {
            Status::Created(file) => Some(ArchiveCommit::Upsert {
                path: entry.path.clone(),
                file,
            }),
            _ => None,
        })
        .collect();
    replica.commit(upserts).await.unwrap();
    replica.unlock().await.unwrap();
    replica.lock().await.unwrap();
}

/// How far [`copy`] gets before it stops.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CopyUntil {
    /// Every step, both commits included.
    Done,
    /// The destination's commit lands; the source's never does.
    DestinationCommitted,
}

/// Copies `relative` from `from` to `to` in SPEC's order: the read, the
/// write over what the destination's scan saw there (`expect`), then the
/// upsert on each side.
pub async fn copy(
    from: &impl Replica,
    to: &impl Replica,
    relative: &str,
    source: FileState,
    expect: Precondition,
    until: CopyUntil,
) {
    let at = path(relative);
    let body = from.read(&at).await.unwrap().body;
    let landed = to.write(&at, body, source, expect).await.unwrap();
    to.commit(vec![ArchiveCommit::Upsert {
        path: at.clone(),
        file: FileState {
            meta: landed,
            hash: source.hash,
        },
    }])
    .await
    .unwrap();
    if until == CopyUntil::Done {
        from.commit(vec![ArchiveCommit::Upsert {
            path: at,
            file: source,
        }])
        .await
        .unwrap();
    }
}

/// Applies `exchanged`'s plan the way a run does, for the actions these
/// tests produce - copies and commit-only records - then makes both
/// archives durable, and locks both again for the run after it.
pub async fn apply(a: &impl Replica, b: &impl Replica, exchanged: &Exchanged) {
    for action in exchanged.actions().iter() {
        let relative = action.path().as_str();
        let scanned = |side| {
            exchanged
                .status(side, relative)
                .and_then(|status| status.file().copied())
        };
        let file_on = |side| scanned(side).expect("a side the action reads has the file");
        let expect = |side| Precondition::of(scanned(side).as_ref());
        match action {
            Action::Copy { from: Side::A, .. } => {
                let (source, expect) = (file_on(Side::A), expect(Side::B));
                copy(a, b, relative, source, expect, CopyUntil::Done).await;
            }
            Action::Copy { from: Side::B, .. } => {
                let (source, expect) = (file_on(Side::B), expect(Side::A));
                copy(b, a, relative, source, expect, CopyUntil::Done).await;
            }
            Action::CommitOnly { path } => {
                let upsert = |side| {
                    vec![ArchiveCommit::Upsert {
                        path: path.clone(),
                        file: file_on(side),
                    }]
                };
                a.commit(upsert(Side::A)).await.unwrap();
                b.commit(upsert(Side::B)).await.unwrap();
            }
            Action::Delete { .. } => panic!("no test here deletes"),
            Action::CopyAside { .. } => panic!("the reconciler never proposes a copy aside"),
        }
    }
    a.unlock().await.unwrap();
    b.unlock().await.unwrap();
    a.lock().await.unwrap();
    b.lock().await.unwrap();
}
