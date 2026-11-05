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
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot};

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

/// One writer's place, held from before its file is queued until the
/// writer answers what landed: given back when dropped.
pub(crate) struct Slot {
    _permit: OwnedSemaphorePermit,
}

/// A file handed to a writer, waiting on what landed. It holds the
/// writer's slot until then.
pub(crate) struct Handed {
    path: RelPath,
    landed: oneshot::Receiver<Result<FileMeta, ReplicaError>>,
    slot: Slot,
}

/// How a body's hand-over to its writer ended.
pub(crate) enum Pumped {
    /// Every byte and the end went to the writer.
    Whole,
    /// The body failed, and the writer was told so.
    Failed,
    /// The writer stopped taking it before its end - it failed, or the
    /// pool stopped - with what is left of the body.
    Stopped(Body),
}

impl Handed {
    /// What landed, once the writer answers; the slot is free after.
    pub(crate) async fn landed(self) -> Result<FileMeta, ReplicaError> {
        let Handed { path, landed, slot } = self;
        let result = landed.await.unwrap_or_else(|_| Err(stopped(path)));
        drop(slot);
        result
    }
}

fn stopped(path: RelPath) -> ReplicaError {
    ReplicaError::Write(WriteError {
        path,
        stage: Stage::Wait,
        source: std::io::Error::other("the writer pool stopped"),
    })
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
        body: Body,
        source: FileState,
        expect: Precondition,
    ) -> Result<FileMeta, ReplicaError> {
        let Some(slot) = self.slot().await else {
            return Err(stopped(path));
        };
        let (handed, _) = self.hand_over(slot, path, body, source, expect).await;
        handed.landed().await
    }

    /// A writer's slot, if one is free now.
    pub(crate) fn try_slot(&self) -> Option<Slot> {
        self.slots
            .clone()
            .try_acquire_owned()
            .ok()
            .map(|permit| Slot { _permit: permit })
    }

    /// The next writer's slot to come free; `None` once the pool stopped.
    pub(crate) async fn slot(&self) -> Option<Slot> {
        self.slots
            .clone()
            .acquire_owned()
            .await
            .ok()
            .map(|permit| Slot { _permit: permit })
    }

    /// Hands `body` to a writer on `slot`, pacing it by the byte budget,
    /// and answers once the body is handed over whole, or failed, or the
    /// writer stopped taking it, saying which. What landed comes from
    /// [`Handed::landed`], which holds the slot until then: the writer is
    /// busy until it answers, whoever waits on it.
    pub(crate) async fn hand_over(
        &self,
        slot: Slot,
        path: RelPath,
        body: Body,
        source: FileState,
        expect: Precondition,
    ) -> (Handed, Pumped) {
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
        // A pool whose threads are gone drops the job, and with it the
        // sender `landed` waits on: it answers that the pool stopped.
        let pumped = if self.jobs.send(job).is_err() {
            Pumped::Stopped(body)
        } else {
            self.pump(body, chunks_tx).await
        };
        (Handed { path, landed, slot }, pumped)
    }

    /// Feeds `body` to the writer taking `chunks`, a chunk at a time as the
    /// budget allows, until its end, its failure, or the writer gone.
    async fn pump(&self, mut body: Body, chunks: mpsc::UnboundedSender<Chunk>) -> Pumped {
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
            let pumped = match chunk {
                Chunk::Bytes(..) => None,
                Chunk::End => Some(Pumped::Whole),
                Chunk::Failed(_) => Some(Pumped::Failed),
            };
            // A writer that failed has dropped its end; its result says why.
            if chunks.send(chunk).is_err() {
                break;
            }
            if let Some(pumped) = pumped {
                return pumped;
            }
        }
        Pumped::Stopped(body)
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
        #[cfg(feature = "test-support")]
        crate::landing_hold::pass(destination.base());
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

#[cfg(test)]
mod tests {
    use std::path::Path;

    use dsync_domain::{ContentHash, MTIME_WINDOW_US};

    use super::*;
    use crate::confinement::Confinement;
    use crate::local_root::Root;

    fn pool(writers: usize, root: &Path) -> WriterPool {
        let confinement = Confinement::new(root.to_path_buf(), crate::Symlinks::AsRuled);
        let root = Root::folder(root.to_str().unwrap().to_owned());
        let destination = Destination::new(Arc::new(root), Arc::new(confinement));
        WriterPool::start(writers, 1024, Arc::new(destination)).unwrap()
    }

    fn source_of(content: &[u8]) -> FileState {
        let digest = ring::digest::digest(&ring::digest::SHA256, content);
        FileState {
            meta: FileMeta {
                size: content.len() as u64,
                mtime_us: 1_704_067_200_000_000,
                mode: 0o644,
                read_us: 1_704_067_200_000_000 + MTIME_WINDOW_US,
            },
            hash: ContentHash::from_digest(digest.as_ref().try_into().unwrap()),
        }
    }

    #[test]
    fn try_slot_fails_while_every_writer_is_busy() {
        let root = tempfile::tempdir().unwrap();
        let pool = pool(2, root.path());

        let first = pool.try_slot();
        let second = pool.try_slot();

        assert!(first.is_some() && second.is_some());
        assert!(pool.try_slot().is_none(), "both writers are taken");
        drop(first);
        assert!(pool.try_slot().is_some(), "a slot given back is free again");
    }

    #[tokio::test]
    async fn a_slot_handed_over_is_not_free_again_until_its_landing_answers() {
        let root = tempfile::tempdir().unwrap();
        let pool = pool(1, root.path());
        let content = b"handed over".to_vec();
        let slot = pool.try_slot().unwrap();

        let (handed, pumped) = pool
            .hand_over(
                slot,
                RelPath::parse("f.txt").unwrap(),
                Body::from_bytes(content.clone()),
                source_of(&content),
                Precondition::Absent,
            )
            .await;

        assert!(matches!(pumped, Pumped::Whole));
        // The body is all handed over, and the writer may even be done:
        // the slot is the landing's until someone hears it answer.
        assert!(
            pool.try_slot().is_none(),
            "the slot moved into the hand-over"
        );
        handed.landed().await.unwrap();
        assert!(pool.try_slot().is_some(), "free once the landing answered");
        assert_eq!(std::fs::read(root.path().join("f.txt")).unwrap(), content);
    }
}
