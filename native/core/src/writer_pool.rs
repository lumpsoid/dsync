//! A replica's file writers (plan D3): a pool of blocking threads taking
//! files from one shared queue in arrival order, each file whole by one
//! writer, with the bytes received and not yet written bounded across every
//! file in flight.
//!
//! One queue, not one per writer, so a slow file holds up only its own
//! writer: the next file goes to whichever writer is free first. Fed in the
//! domain's folder-spread order, the creates in flight at once are in
//! different folders, which is what Android's FUSE storage needs; 16
//! writers were measured at its create floor (SPEC §7.2).
//!
//! Admission is a slot per writer, taken before a file is queued: a file's
//! bytes are only pumped while a writer is taking them, so the byte budget
//! can never be held by files no writer has reached while the files being
//! written wait for it.

use std::io;
use std::sync::{Arc, Mutex, PoisonError, mpsc as std_mpsc};
use std::thread;
use std::time::Instant;

use dsync_domain::{FileMeta, FileState, Precondition, RelPath};
use tokio::sync::{Semaphore, mpsc, oneshot};

use crate::body::Body;
use crate::file_write::{Chunk, Destination, write_file};
use crate::replica_error::ReplicaError;
use crate::write_error::WriteError;
use dsync_domain::{Stage, WriteStats};

/// One file, as a write hands it to the pool; its bytes follow on
/// `chunks`.
struct Job {
    path: RelPath,
    source: FileState,
    expect: Precondition,
    queued: Instant,
    chunks: mpsc::UnboundedReceiver<Chunk>,
    landed: oneshot::Sender<Result<FileMeta, ReplicaError>>,
}

pub(crate) struct WriterPool {
    jobs: std_mpsc::Sender<Job>,
    /// One permit per writer thread.
    slots: Arc<Semaphore>,
    /// One permit per byte received and not yet written.
    budget: Arc<Semaphore>,
    budget_bytes: usize,
    stats: Vec<Arc<Mutex<WriteStats>>>,
}

impl WriterPool {
    /// Starts `writers` threads landing files at `destination`, holding at
    /// most `budget_bytes` received and unwritten. The threads end once the
    /// pool is dropped and the queue drains - or the OS refuses a thread,
    /// and the ones already started end as the unfinished pool drops.
    pub(crate) fn start(
        writers: usize,
        budget_bytes: usize,
        destination: Arc<Destination>,
    ) -> io::Result<WriterPool> {
        let (jobs, queue) = std_mpsc::channel();
        let queue = Arc::new(Mutex::new(queue));
        let stats: Vec<_> = (0..writers)
            .map(|_| Arc::new(Mutex::new(WriteStats::one_writer())))
            .collect();
        for mine in &stats {
            let queue = queue.clone();
            let destination = destination.clone();
            let mine = mine.clone();
            thread::Builder::new()
                .name("dsync-writer".into())
                .spawn(move || run_writer(&queue, &destination, &mine))?;
        }
        Ok(WriterPool {
            jobs,
            slots: Arc::new(Semaphore::new(writers)),
            budget: Arc::new(Semaphore::new(budget_bytes)),
            budget_bytes,
            stats,
        })
    }

    /// Lands `body` at `path` on the next free writer, pacing the body by
    /// the byte budget, and returns what landed - unless `path` is no
    /// longer what `expect` says, or the bytes do not hash to `source`'s
    /// hash (see [`write_file`]).
    pub(crate) async fn write(
        &self,
        path: RelPath,
        mut body: Body,
        source: FileState,
        expect: Precondition,
    ) -> Result<FileMeta, ReplicaError> {
        let stopped = |path: RelPath| {
            ReplicaError::Write(WriteError {
                path,
                stage: Stage::Wait,
                source: std::io::Error::other("the writer pool stopped"),
            })
        };
        let Ok(_slot) = self.slots.clone().acquire_owned().await else {
            return Err(stopped(path));
        };
        let (chunks_tx, chunks) = mpsc::unbounded_channel();
        let (landed_tx, landed) = oneshot::channel();
        let job = Job {
            path: path.clone(),
            source,
            expect,
            queued: Instant::now(),
            chunks,
            landed: landed_tx,
        };
        if self.jobs.send(job).is_err() {
            return Err(stopped(path));
        }
        loop {
            let chunk = match body.next().await {
                Ok(Some(bytes)) => {
                    let Ok(budget) = self
                        .budget
                        .clone()
                        .acquire_many_owned(self.share_of(bytes.len()))
                        .await
                    else {
                        break;
                    };
                    Chunk::Bytes(bytes, budget)
                }
                Ok(None) => Chunk::End,
                Err(error) => Chunk::Failed(error),
            };
            let last = !matches!(chunk, Chunk::Bytes(..));
            // A writer that failed has dropped its end; its result says why.
            if chunks_tx.send(chunk).is_err() || last {
                break;
            }
        }
        drop(chunks_tx);
        landed.await.unwrap_or_else(|_| Err(stopped(path)))
    }

    /// The budget a chunk of `len` bytes holds: its size, capped at the
    /// whole budget so a chunk larger than it still goes through alone.
    fn share_of(&self, len: usize) -> u32 {
        u32::try_from(len.min(self.budget_bytes)).unwrap_or(u32::MAX)
    }

    /// Every writer's stats so far, added up.
    pub(crate) fn stats(&self) -> WriteStats {
        let parts: Vec<WriteStats> = self
            .stats
            .iter()
            .map(|part| part.lock().unwrap_or_else(PoisonError::into_inner).clone())
            .collect();
        WriteStats::total(&parts)
    }
}

/// One writer thread: takes files from `queue` until the pool is gone.
fn run_writer(
    queue: &Mutex<std_mpsc::Receiver<Job>>,
    destination: &Destination,
    stats: &Mutex<WriteStats>,
) {
    loop {
        // The lock is held only while waiting for the next file, so files
        // go out in arrival order to whichever writer asks first.
        let job = queue.lock().unwrap_or_else(PoisonError::into_inner).recv();
        let Ok(mut job) = job else { break };
        let taken = Instant::now();
        let mut file = WriteStats::default();
        file.queue_wait = taken - job.queued;
        let landed = write_file(
            destination,
            &job.path,
            job.source,
            job.expect,
            &mut job.chunks,
            &mut file,
        );
        file.files = u64::from(landed.is_ok());
        file.busy = taken.elapsed();
        stats
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .absorb(&file);
        // The write that queued this may have been dropped; nothing to tell.
        let _ = job.landed.send(landed);
    }
}
