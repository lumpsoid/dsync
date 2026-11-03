//! A replica on this host's filesystem (SPEC §4.1): the root, its archive
//! store, its lock, its writer pool. Used for a local location directly,
//! and by the server a remote replica talks to.
//!
//! The archive is opened by the lock and dropped with it: a replica that
//! does not hold its lock has no archive to read, so each session replays
//! the log once, under the lock.
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
    ArchiveCommit, ArchiveFacts, Bucket, BucketCount, Digested, EntryId, FileMeta, FileState, Jobs,
    Naming, OnDisk, Platform, Precondition, RelPath, RootFacts, RuleSet, ScanEntry, Side, Tuning,
};

use crate::archive_store::ArchiveStore;
use crate::atomic_write::{parent_of, sync_dir};
use crate::body::{Body, BodySender, body_channel};
use crate::case_folding::probe_case_folding;
use crate::confinement::Confinement;
use crate::file_write::Destination;
use crate::listing::Listing;
use crate::local_root::{Located, Root};
use crate::replica::{
    BucketTicket, DigestTicket, DigestedScan, OpenedScan, Reading, Replica, Settled,
};
use crate::replica_error::{FileOp, ReplicaError};
use crate::replica_lock::RunLocks;
use crate::scan_session::ScanSession;
use crate::scanner::{Scanner, holds_at, on_disk};
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
    session: Mutex<Session>,
    scan: Mutex<ScanPhase>,
    /// Which links this replica goes through, checked on every path.
    confinement: Arc<Confinement>,
    destination: Arc<Destination>,
    /// Started by the first write: a replica only read from never starts
    /// its threads.
    writers: OnceLock<WriterPool>,
}

/// Whether this replica holds its lock, and with it the archive read under
/// it: there is no archive without the lock.
enum Session {
    Unlocked,
    /// `store` before `lock`: a store dropped without an unlock writes out
    /// its buffer before the lock that makes the archive this run's goes.
    Locked {
        store: Box<ArchiveStore>,
        lock: RunLocks,
    },
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
    /// state in `state`, going through the `symlinks` it may. Touches
    /// nothing on disk: the archive is read by [`Replica::lock`].
    pub fn open(
        root: Root,
        state: StateDir,
        entry_id: EntryId,
        side: Side,
        jobs: Jobs,
        tuning: Tuning,
        symlinks: Symlinks,
    ) -> LocalReplica {
        let root = Arc::new(root);
        let confinement = Arc::new(Confinement::new(root.base().to_path_buf(), symlinks));
        LocalReplica {
            shared: Arc::new(Shared {
                destination: Arc::new(Destination::new(root.clone(), confinement.clone())),
                confinement,
                root,
                state,
                entry_id,
                side,
                jobs,
                tuning,
                session: Mutex::new(Session::Unlocked),
                scan: Mutex::new(ScanPhase::Closed),
                writers: OnceLock::new(),
            }),
        }
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

    /// Runs `work` against the shared state on the blocking pool. A panic
    /// in `work` goes on unwinding in the caller; a runtime shutting down
    /// under it is a [`ReplicaError::Halted`].
    async fn blocking<T: Send + 'static>(
        &self,
        work: impl FnOnce(&Shared) -> Result<T, ReplicaError> + Send + 'static,
    ) -> Result<T, ReplicaError> {
        let shared = self.shared.clone();
        match tokio::task::spawn_blocking(move || work(&shared)).await {
            Ok(result) => result,
            Err(error) => match error.try_into_panic() {
                Ok(panic) => std::panic::resume_unwind(panic),
                Err(_) => Err(ReplicaError::Halted(
                    "the runtime shut down under a replica operation".into(),
                )),
            },
        }
    }
}

impl Shared {
    fn session(&self) -> MutexGuard<'_, Session> {
        self.session.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Runs `work` on the archive read under the lock, or refuses: this
    /// session does not hold it.
    fn archive<T>(
        &self,
        work: impl FnOnce(&mut ArchiveStore) -> Result<T, ReplicaError>,
    ) -> Result<T, ReplicaError> {
        match &mut *self.session() {
            Session::Locked { store, .. } => work(store),
            Session::Unlocked => Err(ReplicaError::NotLocked),
        }
    }

    fn scan(&self) -> MutexGuard<'_, ScanPhase> {
        self.scan.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The writer pool, started on the first write. A start the OS refuses
    /// is retried on the next write; of two racing starts, the loser's
    /// threads end as its pool drops.
    fn writers(&self) -> Result<&WriterPool, ReplicaError> {
        if let Some(pool) = self.writers.get() {
            return Ok(pool);
        }
        let started = WriterPool::start(
            self.tuning.writers,
            self.tuning.writer_buffer_bytes,
            self.destination.clone(),
        )
        .map_err(|error| ReplicaError::Halted(format!("starting a writer thread: {error}")))?;
        Ok(self.writers.get_or_init(|| started))
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
    async fn hello(&self) -> Result<RootFacts, ReplicaError> {
        self.blocking(|shared| {
            let log = shared.state.archive_log(&shared.entry_id, shared.side);
            Ok(RootFacts {
                archive_path: Some(log.display().to_string()),
                root: shared.root.state(),
            })
        })
        .await
    }

    async fn lock(&self) -> Result<ArchiveFacts, ReplicaError> {
        self.blocking(|shared| {
            let mut session = shared.session();
            // A second lock in one session is refused here as held, like
            // another run's.
            let lock =
                RunLocks::acquire(&shared.state, &shared.entry_id, shared.side, &shared.root)?;
            let mut store = Box::new(ArchiveStore::open_replica(
                &lock,
                shared.root.text().to_owned(),
                &shared.tuning,
            )?);
            let facts = ArchiveFacts {
                last_commit: store.last_commit()?,
                archived_files: store.archive().len() as u64,
            };
            // A crashed run's temps (SPEC §7.2): under the lock, nothing
            // else of this replica's is writing.
            shared.destination.clear_staging();
            *session = Session::Locked { store, lock };
            Ok(facts)
        })
        .await
    }

    async fn unlock(&self) -> Result<(), ReplicaError> {
        self.blocking(|shared| {
            // Batched commits are made durable before the lock that says
            // this replica is this session's is given up (SPEC §8.2).
            match std::mem::replace(&mut *shared.session(), Session::Unlocked) {
                Session::Locked { mut store, lock } => {
                    shared.destination.clear_staging();
                    let flushed = store.flush();
                    // The archive goes before the lock it was read under.
                    drop(store);
                    drop(lock);
                    Ok(flushed?)
                }
                Session::Unlocked => Ok(()),
            }
        })
        .await
    }

    async fn create_root(&self) -> Result<(), ReplicaError> {
        self.blocking(|shared| {
            shared
                .root
                .create()
                .map_err(shared.file_error(FileOp::CreateRoot, shared.root.path().to_path_buf()))?;
            // A root missing at lock had nowhere to hold its in-root lock.
            if let Session::Locked { lock, .. } = &mut *shared.session() {
                lock.claim_root(&shared.state, &shared.root)?;
            }
            Ok(())
        })
        .await
    }

    async fn open_scan(&self, rules: &RuleSet) -> Result<OpenedScan, ReplicaError> {
        let rules = rules.clone();
        let (result, naming) = self
            .blocking(move |shared| {
                shared.archive(|store| {
                    let naming = Naming {
                        folding: probe_case_folding(shared.root.base()),
                        platform: Platform::HOST,
                    };
                    let scanner = Scanner::new(
                        shared.jobs,
                        naming.folding,
                        shared.confinement.symlinks().clone(),
                    );
                    let result = shared.root.scan(&scanner, store.archive(), &rules)?;
                    store.commit(result.key_refreshes())?;
                    Ok((result, naming))
                })
            })
            .await?;
        let session = ScanSession::new(result, naming);
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
        mut peer_changed: Listing<RelPath>,
    ) -> Result<DigestedScan, ReplicaError> {
        let session = {
            let mut phase = self.shared.scan();
            match std::mem::replace(&mut *phase, ScanPhase::Closed) {
                ScanPhase::Opened(session) => session,
                other => {
                    *phase = other;
                    return Err(ReplicaError::NoScan);
                }
            }
        };
        // Kept as they arrive, only those this side holds unchanged: a
        // peer's list costs no more than this side's own scan.
        let noted = async {
            let mut noted = session.peer_changed();
            while let Some(page) = peer_changed.next_page().await? {
                for path in page {
                    noted.note(path);
                }
            }
            Ok(noted.into_paths())
        }
        .await;
        let peer_changed = match noted {
            Ok(paths) => paths,
            Err(error) => {
                *self.shared.scan() = ScanPhase::Opened(session);
                return Err(error);
            }
        };
        self.blocking(move |shared| {
            let mut phase = shared.scan();
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
                    .and_then(|()| open_regular(&source))
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
        source: FileState,
        expect: Precondition,
    ) -> Result<FileMeta, ReplicaError> {
        self.shared
            .writers()?
            .write(path.clone(), body, source, expect)
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
            holds_at(expect, &target)?;
            // The folder synced too, so the delete is durable before its
            // record commits, like a write's rename (SPEC §7.5).
            fs::remove_file(&target)
                .and_then(|()| sync_dir(parent_of(&target)?))
                .map(drop)
                .map_err(shared.file_error(FileOp::Delete, target.clone()))
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
            shared.archive(|store| Ok(store.commit(batch)?))
        })
        .await
    }

    async fn compact(&self) -> Result<(), ReplicaError> {
        self.blocking(|shared| shared.archive(|store| Ok(store.compact()?)))
            .await
    }

    async fn close(self) -> Result<(), ReplicaError> {
        Ok(())
    }

    fn write_stats(&self) -> Option<WriteStats> {
        Some(LocalReplica::write_stats(self))
    }
}

/// `source` opened for reading, or a refusal of anything but a regular
/// file. A peer can name a path the scan never listed: opened without
/// `O_NONBLOCK`, a FIFO would hold a blocking thread until a writer came.
/// Regular files ignore the flag, so the read itself still blocks.
fn open_regular(source: &Path) -> io::Result<File> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = options.open(source)?;
    if file.metadata()?.is_file() {
        Ok(file)
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not a regular file",
        ))
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
