//! The server's file writers: a pool of blocking threads that take files
//! from one shared queue in arrival order, each file whole by one writer.
//!
//! One queue, not one per writer, so a slow file holds up only its own
//! writer: the next file goes to whichever writer is free first. With files
//! arriving spread across folders (order.rs), the creates in flight at once
//! are in different folders, which is what Android's FUSE storage needs
//! (SPEC §7.2).
//!
//! What is buffered is bounded in bytes ([BUFFER_BYTES]) across every file
//! queued or being written; a chunk gives its share back once written. That
//! is the back-pressure on the socket.

use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime};

use anyhow::anyhow;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc};
use tokio::task::JoinHandle;

use crate::cpu::thread_cpu;
use crate::rel_path::RelPath;
use crate::slow_create::around_create;
use crate::wire::FileHeader;
use crate::write_error::WriteError;
use crate::write_stats::{Stage, WriteStats};

/// Bytes received and not yet written, across every file.
const BUFFER_BYTES: usize = 16 << 20;

/// Files received and not yet taken by a writer.
const QUEUED_FILES: usize = 1024;

/// One file, as the socket reader hands it over; its bytes follow on
/// [FileJob::chunks].
struct FileJob {
    path: RelPath,
    target: PathBuf,
    folder: PathBuf,
    size: u64,
    mtime: SystemTime,
    queued: Instant,
    chunks: mpsc::UnboundedReceiver<Chunk>,
}

/// A piece of a file's content, holding its share of [BUFFER_BYTES].
struct Chunk {
    bytes: Vec<u8>,
    _budget: OwnedSemaphorePermit,
}

/// Where the socket reader sends one file's content.
pub struct FileSender {
    chunks: mpsc::UnboundedSender<Chunk>,
    budget: Arc<Semaphore>,
}

impl FileSender {
    /// Waits for room in the buffer, then queues [bytes] for the writer.
    pub async fn send(&self, bytes: Vec<u8>) -> anyhow::Result<()> {
        let budget = self
            .budget
            .clone()
            .acquire_many_owned(bytes.len() as u32)
            .await?;
        self.chunks
            .send(Chunk {
                bytes,
                _budget: budget,
            })
            .map_err(|_| anyhow!("the writer dropped a file part-way"))
    }
}

pub struct WriterPool {
    jobs: mpsc::Sender<FileJob>,
    threads: Vec<JoinHandle<WriteStats>>,
    budget: Arc<Semaphore>,
    failure: Arc<Failure>,
}

impl WriterPool {
    /// Starts [count] writers. Each finished file's path and size goes to
    /// [done].
    pub fn start(count: usize, done: mpsc::UnboundedSender<(RelPath, u64)>) -> Self {
        let (jobs, queue) = mpsc::channel(QUEUED_FILES);
        let queue = Arc::new(Mutex::new(queue));
        let failure = Arc::new(Failure::default());
        let folders = Arc::new(Folders::default());
        let threads = (0..count)
            .map(|_| {
                let queue = queue.clone();
                let done = done.clone();
                let failure = failure.clone();
                let folders = folders.clone();
                tokio::task::spawn_blocking(move || run_writer(&queue, &done, &failure, &folders))
            })
            .collect();
        WriterPool {
            jobs,
            threads,
            budget: Arc::new(Semaphore::new(BUFFER_BYTES)),
            failure,
        }
    }

    /// True once a writer has failed; the transfer is over.
    pub fn failed(&self) -> bool {
        self.failure.is_set()
    }

    /// Queues a file to land under [root] for the next free writer; its
    /// content goes to the sender this returns.
    pub async fn submit(&self, root: &Path, header: FileHeader) -> anyhow::Result<FileSender> {
        let (chunks_tx, chunks) = mpsc::unbounded_channel();
        let job = FileJob {
            target: header.path.under(root),
            folder: header.path.folder_under(root),
            path: header.path,
            size: header.size,
            mtime: header.mtime,
            queued: Instant::now(),
            chunks,
        };
        self.jobs
            .send(job)
            .await
            .map_err(|_| anyhow!("every writer stopped"))?;
        Ok(FileSender {
            chunks: chunks_tx,
            budget: self.budget.clone(),
        })
    }

    /// Closes the queue and waits for the writers to drain it: every
    /// writer's stats added up, or the first writer's error.
    pub async fn finish(self) -> anyhow::Result<WriteStats> {
        drop(self.jobs);
        let mut parts = Vec::with_capacity(self.threads.len());
        for thread in self.threads {
            parts.push(thread.await?);
        }
        match self.failure.take() {
            Some(error) => Err(error.into()),
            None => Ok(WriteStats::total(&parts)),
        }
    }
}

/// One writer thread: takes files from [queue] until it closes or any
/// writer fails.
fn run_writer(
    queue: &Mutex<mpsc::Receiver<FileJob>>,
    done: &mpsc::UnboundedSender<(RelPath, u64)>,
    failure: &Failure,
    folders: &Folders,
) -> WriteStats {
    let cpu_start = thread_cpu();
    let mut stats = WriteStats::one_writer();
    loop {
        // The lock is held only while waiting for the next file, so files go
        // out in arrival order to whichever writer asks first.
        let job = queue
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .blocking_recv();
        let Some(job) = job else { break };
        if failure.is_set() {
            break;
        }
        let taken = Instant::now();
        stats.queue_wait += taken - job.queued;
        let path = job.path.clone();
        let size = job.size;
        match write_file(job, folders, &mut stats) {
            Ok(Written::Whole) => {
                stats.files += 1;
                let _ = done.send((path, size));
            }
            // The socket reader stopped mid-file; its own error says why.
            Ok(Written::CutShort) => {}
            Err(error) => failure.set(error),
        }
        stats.busy += taken.elapsed();
    }
    stats.writer_cpu = cpu_start
        .zip(thread_cpu())
        .map(|(from, to)| to.saturating_sub(from));
    stats
}

/// The first writer error, which ends the transfer.
#[derive(Default)]
struct Failure(Mutex<Option<WriteError>>);

impl Failure {
    fn slot(&self) -> std::sync::MutexGuard<'_, Option<WriteError>> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn is_set(&self) -> bool {
        self.slot().is_some()
    }

    /// Keeps [error] only if it is the first.
    fn set(&self, error: WriteError) {
        self.slot().get_or_insert(error);
    }

    fn take(&self) -> Option<WriteError> {
        self.slot().take()
    }
}

/// Folders known to exist, shared by every writer, so each is created at
/// most once per transfer (twice, if two writers race to it; harmless).
#[derive(Default)]
struct Folders(Mutex<HashSet<PathBuf>>);

impl Folders {
    fn set(&self) -> std::sync::MutexGuard<'_, HashSet<PathBuf>> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn known(&self, folder: &Path) -> bool {
        self.set().contains(folder)
    }

    fn mark(&self, folder: &Path) {
        if !self.known(folder) {
            self.set().insert(folder.to_path_buf());
        }
    }
}

enum Written {
    Whole,
    CutShort,
}

/// What is at a target before it is written (SPEC §7.2's WriteTarget).
enum Target {
    /// Nothing: create it.
    Fresh,
    /// A single-link file: truncate and write in place.
    InPlace,
    /// A file with other hard links: write a temp beside it and rename it
    /// over, so the other names keep their bytes.
    Replace,
}

fn probe(target: &Path) -> io::Result<Target> {
    match fs::metadata(target) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Target::Fresh),
        Err(e) => Err(e),
        Ok(meta) if has_other_links(&meta) => Ok(Target::Replace),
        Ok(_) => Ok(Target::InPlace),
    }
}

#[cfg(unix)]
fn has_other_links(meta: &fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    meta.nlink() > 1
}

#[cfg(not(unix))]
fn has_other_links(_: &fs::Metadata) -> bool {
    false
}

/// Where a Replace writes before its rename: beside the file a followed
/// link points at, so the rename replaces that file and the link survives.
fn temp_for(target: &Path) -> io::Result<(PathBuf, PathBuf)> {
    let real = fs::canonicalize(target)?;
    let name = real
        .file_name()
        .ok_or_else(|| io::Error::other("target has no file name"))?
        .to_string_lossy();
    let temp = real.with_file_name(format!(".{name}.dsync-rs-tmp"));
    Ok((temp, real))
}

/// Writes one file: probe, parent folders (for a fresh file), open,
/// content, mtime, close, and the rename when there is one. Every step is
/// timed into [stats].
fn write_file(
    mut job: FileJob,
    folders: &Folders,
    stats: &mut WriteStats,
) -> Result<Written, WriteError> {
    let path = job.path.clone();
    let fail = |stage: Stage| {
        let path = path.clone();
        move |source: io::Error| WriteError {
            path,
            stage,
            source,
        }
    };
    let mut timer = StageTimer::new(stats);
    let folder = &job.folder;

    let target = probe(&job.target).map_err(fail(Stage::Probe))?;
    timer.lap(Stage::Probe);
    match target {
        Target::Fresh if !folders.known(folder) => {
            fs::create_dir_all(folder).map_err(fail(Stage::Mkdir))?;
            timer.lap(Stage::Mkdir);
            folders.mark(folder);
        }
        Target::Fresh => {}
        // Something is there, so its folder is.
        Target::InPlace | Target::Replace => folders.mark(folder),
    }
    let create = |at: &Path| {
        around_create(folder, || {
            OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(at)
        })
    };
    let (mut file, rename) = match target {
        Target::Fresh => {
            let file = create(&job.target).map_err(fail(Stage::Create))?;
            timer.lap(Stage::Create);
            (file, None)
        }
        Target::InPlace => {
            match OpenOptions::new()
                .write(true)
                .truncate(true)
                .open(&job.target)
            {
                Ok(file) => {
                    timer.lap(Stage::Open);
                    (file, None)
                }
                // Not writable by this process: the rename needs only the
                // folder's permission (SPEC §7.2, task 3a857c).
                Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
                    timer.lap(Stage::Open);
                    replace(&job.target, create, &fail, &mut timer)?
                }
                Err(e) => return Err(fail(Stage::Open)(e)),
            }
        }
        Target::Replace => replace(&job.target, create, &fail, &mut timer)?,
    };

    let mut remaining = job.size;
    while remaining > 0 {
        let Some(chunk) = job.chunks.blocking_recv() else {
            timer.lap(Stage::Wait);
            return Ok(Written::CutShort);
        };
        timer.lap(Stage::Wait);
        file.write_all(&chunk.bytes).map_err(fail(Stage::Write))?;
        timer.lap(Stage::Write);
        remaining = remaining.saturating_sub(chunk.bytes.len() as u64);
    }
    file.set_modified(job.mtime).map_err(fail(Stage::Mtime))?;
    timer.lap(Stage::Mtime);
    drop(file);
    timer.lap(Stage::Close);
    if let Some((temp, real)) = rename {
        fs::rename(&temp, &real).map_err(fail(Stage::Rename))?;
        timer.lap(Stage::Rename);
    }
    Ok(Written::Whole)
}

/// Opens the temp a Replace writes; the file and the rename to do at the
/// end.
fn replace<F>(
    target: &Path,
    create: impl Fn(&Path) -> io::Result<File>,
    fail: &impl Fn(Stage) -> F,
    timer: &mut StageTimer,
) -> Result<(File, Option<(PathBuf, PathBuf)>), WriteError>
where
    F: FnOnce(io::Error) -> WriteError,
{
    let (temp, real) = temp_for(target).map_err(fail(Stage::Probe))?;
    timer.lap(Stage::Probe);
    let file = create(&temp).map_err(fail(Stage::Create))?;
    timer.lap(Stage::Create);
    Ok((file, Some((temp, real))))
}

/// Times consecutive stages: each [lap] records the time since the last.
struct StageTimer<'a> {
    stats: &'a mut WriteStats,
    last: Instant,
}

impl<'a> StageTimer<'a> {
    fn new(stats: &'a mut WriteStats) -> Self {
        StageTimer {
            stats,
            last: Instant::now(),
        }
    }

    fn lap(&mut self, stage: Stage) {
        let now = Instant::now();
        self.stats.record(stage, now - self.last);
        self.last = now;
    }
}
