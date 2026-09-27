//! A replica on this host's filesystem (SPEC §4.1): the root, its archive
//! store, its lock, its writer pool. Used for a local location directly,
//! and by the server a remote replica talks to.
//!
//! Blocking work - the archive's fsyncs, the scan, file reads, deletes -
//! runs on tokio's blocking pool (`spawn_blocking`); writes run on the
//! pool's own threads (plan D3). Never `tokio::fs`. This type builds no
//! runtime: its async methods run on the caller's.

use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};

use dsync_domain::{
    ArchiveCommit, Bucket, BucketCount, Digested, EntryId, FileMeta, Jobs, OnDisk, Precondition,
    RelPath, ReplicaInfo, RuleSet, ScanEntry, Side, Tuning,
};

use crate::archive_store::{ArchiveError, ArchiveStore};
use crate::body::{Body, BodySender, body_channel};
use crate::case_folding::probe_case_folding;
use crate::confinement::Confinement;
use crate::file_write::Destination;
use crate::local_root::{Located, Root};
use crate::replica::{
    BucketTicket, DigestTicket, DigestedScan, OpenedScan, Reading, Replica, Settled,
};
use crate::replica_error::{FileOp, ReplicaError};
use crate::replica_lock::RunLocks;
use crate::scan_session::ScanSession;
use crate::scanner::{Scanner, on_disk, on_disk_at};
use crate::state_dir::StateDir;
use crate::symlinks::Symlinks;
use crate::writer_pool::WriterPool;
use dsync_domain::WriteStats;

/// Chunks a read holds ready ahead of its consumer: one being taken, one
/// being read.
const READ_AHEAD_CHUNKS: usize = 1;

pub struct LocalReplica {
    shared: Arc<Shared>,
}

struct Shared {
    /// The only way to the replica's files ([`Root::locate`]).
    root: Arc<Root>,
    state: StateDir,
    entry_id: EntryId,
    side: Side,
    jobs: Jobs,
    tuning: Tuning,
    store: Mutex<ArchiveStore>,
    lock: Mutex<Option<RunLocks>>,
    scan: Mutex<ScanPhase>,
    /// Which links this replica goes through, checked on every path.
    confinement: Arc<Confinement>,
    destination: Arc<Destination>,
    /// Started by the first write: a replica only read from never starts
    /// its threads.
    writers: OnceLock<WriterPool>,
}

/// Where this replica's scan exchange stands (plan OQ3). The tickets make
/// the order unrepresentable for the caller; this is the state they stand
/// for.
enum ScanPhase {
    Closed,
    Opened(ScanSession),
    Digested(Digested),
}

impl LocalReplica {
    /// The replica at `root` (its text as the location names it is also
    /// the archive header's root), side `side` of `entry_id`, with its
    /// state in `state`, going through the `symlinks` it may. Replays the
    /// archive, so this blocks.
    pub fn open(
        root: Root,
        state: StateDir,
        entry_id: EntryId,
        side: Side,
        jobs: Jobs,
        tuning: Tuning,
        symlinks: Symlinks,
    ) -> Result<LocalReplica, ArchiveError> {
        let store =
            ArchiveStore::open_replica(&state, &entry_id, side, root.text().to_owned(), &tuning)?;
        let root = Arc::new(root);
        let confinement = Arc::new(Confinement::new(root.base().to_path_buf(), symlinks));
        Ok(LocalReplica {
            shared: Arc::new(Shared {
                destination: Arc::new(Destination::new(root.clone(), confinement.clone())),
                confinement,
                root,
                state,
                entry_id,
                side,
                jobs,
                tuning,
                store: Mutex::new(store),
                lock: Mutex::new(None),
                scan: Mutex::new(ScanPhase::Closed),
                writers: OnceLock::new(),
            }),
        })
    }

    /// The root itself: the folder, or the one file.
    pub fn root(&self) -> &Path {
        self.shared.root.path()
    }

    /// What this replica's writers have spent so far, stage by stage
    /// (SPEC §17).
    pub fn write_stats(&self) -> WriteStats {
        self.shared
            .writers
            .get()
            .map_or_else(WriteStats::default, WriterPool::stats)
    }

    /// Runs `work` against the shared state on the blocking pool.
    async fn blocking<T: Send + 'static>(
        &self,
        work: impl FnOnce(&Shared) -> T + Send + 'static,
    ) -> T {
        let shared = self.shared.clone();
        match tokio::task::spawn_blocking(move || work(&shared)).await {
            Ok(value) => value,
            Err(error) => match error.try_into_panic() {
                Ok(panic) => std::panic::resume_unwind(panic),
                Err(_) => panic!("the runtime shut down under a replica operation"),
            },
        }
    }
}

impl Shared {
    fn store(&self) -> MutexGuard<'_, ArchiveStore> {
        self.store.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn scan(&self) -> MutexGuard<'_, ScanPhase> {
        self.scan.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn held(&self) -> MutexGuard<'_, Option<RunLocks>> {
        self.lock.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn writers(&self) -> &WriterPool {
        self.writers.get_or_init(|| {
            WriterPool::start(
                self.tuning.writers,
                self.tuning.writer_buffer_bytes,
                self.destination.clone(),
            )
        })
    }

    fn file_error(&self, op: FileOp, path: PathBuf) -> impl FnOnce(io::Error) -> ReplicaError {
        move |source| ReplicaError::File { op, path, source }
    }

    /// Where `path` lands, or the refusal of a path outside the root,
    /// failing `op`.
    fn locate(&self, op: FileOp, path: &RelPath) -> Result<Located, ReplicaError> {
        self.root
            .locate(path)
            .map_err(self.file_error(op, PathBuf::from(path.as_str())))
    }
}

impl Replica for LocalReplica {
    async fn hello(&self) -> Result<ReplicaInfo, ReplicaError> {
        self.blocking(|shared| {
            let mut store = shared.store();
            let last_commit = store.last_commit()?;
            // The archive is only counted for a missing root, where the
            // refusal reports it (SPEC §4.5).
            let root = shared.root.state(|| store.archive().len() as u64);
            Ok(ReplicaInfo {
                last_commit,
                archive_path: Some(store.log_path().display().to_string()),
                root,
            })
        })
        .await
    }

    async fn lock(&self) -> Result<(), ReplicaError> {
        self.blocking(|shared| {
            let lock = RunLocks::acquire(
                &shared.state,
                &shared.entry_id,
                shared.side,
                shared.root.path(),
            )?;
            // Replayed again under the lock: a run that held it until now
            // may have committed since this replica was opened.
            let mut store = shared.store();
            store.flush()?;
            *store = ArchiveStore::open_replica(
                &shared.state,
                &shared.entry_id,
                shared.side,
                shared.root.text().to_owned(),
                &shared.tuning,
            )?;
            *shared.held() = Some(lock);
            Ok(())
        })
        .await
    }

    async fn unlock(&self) -> Result<(), ReplicaError> {
        self.blocking(|shared| {
            // Batched commits are made durable before the lock that says
            // this replica is this session's is given up (SPEC §8.2).
            let flushed = shared.store().flush();
            shared.held().take();
            Ok(flushed?)
        })
        .await
    }

    async fn create_root(&self) -> Result<(), ReplicaError> {
        self.blocking(|shared| {
            shared
                .root
                .create()
                .map_err(shared.file_error(FileOp::CreateRoot, shared.root.path().to_path_buf()))
        })
        .await
    }

    async fn open_scan(&self, rules: &RuleSet) -> Result<OpenedScan, ReplicaError> {
        let rules = rules.clone();
        let result = self
            .blocking(move |shared| {
                let scanner = Scanner::new(
                    shared.jobs,
                    probe_case_folding(shared.root.base()),
                    shared.confinement.symlinks().clone(),
                );
                let mut store = shared.store();
                let result = shared.root.scan(&scanner, store.archive(), &rules)?;
                store.commit(result.key_refreshes())?;
                Ok::<_, ReplicaError>(result)
            })
            .await?;
        let session = ScanSession::new(result);
        let changed = session.changed().clone();
        *self.shared.scan() = ScanPhase::Opened(session);
        Ok(OpenedScan {
            changed,
            next: DigestTicket::issue(),
        })
    }

    async fn scan_digests(
        &self,
        _ticket: DigestTicket,
        count: BucketCount,
        peer_changed: &[RelPath],
    ) -> Result<DigestedScan, ReplicaError> {
        let peer_changed = peer_changed.to_vec();
        self.blocking(move |shared| {
            let mut phase = shared.scan();
            let session = match std::mem::replace(&mut *phase, ScanPhase::Closed) {
                ScanPhase::Opened(session) => session,
                other => {
                    *phase = other;
                    return Err(ReplicaError::NoScan);
                }
            };
            let digested = session.digests(count, &peer_changed);
            let reply = DigestedScan {
                digests: digested.digests().clone(),
                owed: digested.owed().to_vec(),
                next: BucketTicket::issue(),
            };
            *phase = ScanPhase::Digested(digested);
            Ok(reply)
        })
        .await
    }

    async fn scan_buckets(
        &self,
        _ticket: &BucketTicket,
        buckets: &[Bucket],
    ) -> Result<Vec<ScanEntry>, ReplicaError> {
        match &*self.shared.scan() {
            ScanPhase::Digested(digested) => Ok(digested.entries_in(buckets)),
            ScanPhase::Closed | ScanPhase::Opened(_) => Err(ReplicaError::NoScan),
        }
    }

    async fn read(&self, path: &RelPath) -> Result<Reading, ReplicaError> {
        let path = path.clone();
        let file = self
            .blocking(move |shared| {
                let Located { path: source, rel } = shared.locate(FileOp::Read, &path)?;
                // A peer can read without scanning: the scan's skip is
                // not the only bound.
                shared
                    .confinement
                    .check(&rel)
                    .and_then(|()| File::open(&source))
                    .map_err(shared.file_error(FileOp::Read, source.clone()))
            })
            .await?;
        let (sender, body) = body_channel(READ_AHEAD_CHUNKS);
        let (settle, settled) = Settled::channel();
        let buffer = self.shared.tuning.read_buffer_bytes;
        tokio::task::spawn_blocking(move || send_file(file, buffer, sender, settle));
        Ok(Reading { body, settled })
    }

    async fn write(
        &self,
        path: &RelPath,
        body: Body,
        meta: FileMeta,
        expect: Precondition,
    ) -> Result<FileMeta, ReplicaError> {
        self.shared
            .writers()
            .write(path.clone(), body, meta, expect)
            .await
    }

    async fn delete(&self, path: &RelPath, expect: Precondition) -> Result<(), ReplicaError> {
        let path = path.clone();
        self.blocking(move |shared| {
            let Located { path: target, rel } = shared.locate(FileOp::Delete, &path)?;
            shared
                .confinement
                .check(&rel)
                .map_err(shared.file_error(FileOp::Delete, target.clone()))?;
            expect.check(on_disk_at(&target))?;
            fs::remove_file(&target).map_err(shared.file_error(FileOp::Delete, target.clone()))
        })
        .await
    }

    async fn remove_empty_dirs(&self, path: &RelPath) -> Result<(), ReplicaError> {
        let path = path.clone();
        self.blocking(move |shared| {
            // The folders above the path within the root: none for a
            // single-file root, whose folder is never removed.
            let rel = shared.locate(FileOp::RemoveDir, &path)?.rel;
            let mut ancestor = rel.parent();
            if let Some(folder) = &ancestor {
                shared.confinement.check(folder).map_err(
                    shared.file_error(FileOp::RemoveDir, folder.join_under(shared.root.base())),
                )?;
            }
            while let Some(folder) = ancestor {
                let at = folder.join_under(shared.root.base());
                match fs::remove_dir(&at) {
                    // Forgotten, so a later write into it this session
                    // creates it again instead of trusting it (SPEC §7.1
                    // runs deletes and copies in one apply).
                    Ok(()) => shared.destination.forget(&folder),
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::NotFound | io::ErrorKind::DirectoryNotEmpty
                        ) =>
                    {
                        break;
                    }
                    Err(error) => return Err(shared.file_error(FileOp::RemoveDir, at)(error)),
                }
                ancestor = folder.parent();
            }
            Ok(())
        })
        .await
    }

    async fn commit(&self, batch: Vec<ArchiveCommit>) -> Result<(), ReplicaError> {
        self.blocking(move |shared| {
            // A single-file root's archive records its one path, whoever
            // asks.
            for commit in &batch {
                shared.locate(FileOp::Commit, commit.path())?;
            }
            Ok(shared.store().commit(batch)?)
        })
        .await
    }

    async fn compact(&self) -> Result<(), ReplicaError> {
        self.blocking(|shared| Ok(shared.store().compact()?)).await
    }

    async fn close(self) -> Result<(), ReplicaError> {
        Ok(())
    }

    fn write_stats(&self) -> Option<WriteStats> {
        Some(LocalReplica::write_stats(self))
    }
}

/// Streams `file` into `sender`, `buffer` bytes a read, until the end or
/// the first error; stops early if the body is dropped. At the end, what
/// the file is by then goes to `settle`, before the body is finished: the
/// open file's own stat, so the check is of the bytes just read, whatever
/// has been renamed over its path since.
fn send_file(
    mut file: File,
    buffer: usize,
    sender: BodySender,
    settle: tokio::sync::oneshot::Sender<OnDisk>,
) {
    loop {
        let mut chunk = vec![0; buffer];
        match fill(&mut file, &mut chunk) {
            Ok(read) => {
                chunk.truncate(read);
                if read > 0 && sender.blocking_send(chunk).is_err() {
                    return;
                }
                if read < buffer {
                    let now = file
                        .metadata()
                        .map_or(OnDisk::Unknown, |meta| on_disk(&meta));
                    let _ = settle.send(now);
                    let _ = sender.blocking_finish();
                    return;
                }
            }
            Err(error) => {
                let _ = sender.blocking_fail(error);
                return;
            }
        }
    }
}

/// Reads until `chunk` is full or the file ends; how much was read.
fn fill(file: &mut File, chunk: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0;
    while filled < chunk.len() {
        match file.read(&mut chunk[filled..]) {
            Ok(0) => break,
            Ok(read) => filled += read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(filled)
}
