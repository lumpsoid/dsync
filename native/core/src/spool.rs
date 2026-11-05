//! A replica's spool (SPEC §4.2's `stage`): where a run's downloads wait
//! on app-private storage when the destination's writers fall behind, so
//! the transfer is not held to the destination's pace.
//!
//! [`Spool::stage`] decides once, before it reads a chunk, where a body
//! waits:
//!
//! 1. The writers keep up (a writer's slot is free and nothing is queued):
//!    the body goes to the writer as a write's does, and the stage answers
//!    at its end. One write, no spool file.
//! 2. The writers are behind (no slot free, or anything queued, whole or
//!    still arriving) and the file's size fits the room left: the size is
//!    reserved, the body goes into a spool file, and the file is queued.
//! 3. Neither: the stage waits until one holds. A file larger than the
//!    whole room waits for case 1 only, coupled to the writers as a write
//!    is, and never fails for being large.
//!
//! A case-2 stage takes its place in the queue at the decision, not at its
//! body's end, so a later stage that finds a slot free while it is still
//! arriving spills behind it rather than landing first: landings follow
//! stage order. Stages decide one at a time, in the order they asked.
//!
//! The Lander takes the queue's head once it is whole and a writer's slot
//! is free, and hands the writer a body read from the spool file: the
//! landing is a write's, with every check and sync a write makes. Spool
//! files themselves are never synced: the next lock sweeps them anyway.
//!
//! The Lander lives as long as its [`Spool`], which the replica's session
//! holds under the lock: a spool dropped stops it, so no spooled file
//! starts landing once the lock is gone. Landings already on a writer
//! finish, as a write does.

use std::collections::VecDeque;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use dsync_domain::{FileMeta, FileState, Precondition, RelPath, Stage, Tuning};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::{AbortHandle, JoinError};

use crate::body::{Body, BodySender, body_channel};
use crate::landings::Landings;
use crate::local_replica::fill;
use crate::replica_error::ReplicaError;
use crate::write_error::WriteError;
use crate::writer_pool::{Handed, Pumped, Slot, WriterPool};

/// Chunks a spool file's reader holds ready ahead of its writer, as a
/// local read does.
const READ_AHEAD_CHUNKS: usize = 1;

/// Chunks a stage holds between its body and its spool file's writer.
const SPOOL_AHEAD_CHUNKS: usize = 1;

/// Spool sessions started in this process, so each session's files go in
/// a folder of their own: a landing a dropped session left on a writer
/// removes its own file when it ends, never a later session's.
static NEXT_SESSION: AtomicU64 = AtomicU64::new(0);

/// One locked session's spool. Dropping it stops its Lander.
pub(crate) struct Spool {
    inner: Arc<Inner>,
    pool: Arc<WriterPool>,
    room: u64,
    lander: AbortHandle,
}

/// What the stages, the Lander and its landings share. Holds nothing the
/// lock covers: a Lander holding it lands nothing once stopped.
struct Inner {
    folder: PathBuf,
    read_buffer: usize,
    state: Mutex<State>,
    /// Bumped on every change a stage, the Lander, a `settle` or a
    /// `take_landed` may wait for.
    changes: watch::Sender<u64>,
    /// The bytes staged and not yet handed to a writer.
    queued_bytes: watch::Sender<u64>,
    /// Stages decide one at a time, in the order they asked.
    turn: tokio::sync::Mutex<()>,
}

struct State {
    /// Room left to reserve.
    free: u64,
    /// The next spool file's sequence number.
    next: u64,
    /// Spooled files not yet handed to a writer, in stage order.
    queue: VecDeque<Entry>,
    /// Landings on a writer, from either case, not yet answered.
    landing: u64,
    /// Landings answered and not yet taken.
    landed: Vec<(RelPath, Result<FileMeta, ReplicaError>)>,
    /// The spool was dropped: the Lander starts nothing more.
    closed: bool,
}

/// A spooled file, as its stage queued it.
struct Entry {
    seq: u64,
    path: RelPath,
    source: FileState,
    expect: Precondition,
    /// Its reserved room: the source's size.
    size: u64,
    /// Whether its body has all arrived; the Lander takes only a whole
    /// head.
    whole: bool,
}

/// Where a stage's body waits, with what it took there.
enum Place {
    Writer(Slot, Unlanded),
    Spool(Unspooled),
}

/// A case-1 landing counted and not yet handed to the task that waits on
/// its writer: a stage dropped before then uncounts it.
struct Unlanded {
    inner: Arc<Inner>,
    armed: bool,
}

impl Drop for Unlanded {
    fn drop(&mut self) {
        if self.armed {
            self.inner.unland();
        }
    }
}

/// A spooled file's queue entry, room and file, not yet whole: a stage
/// that fails or is dropped before then gives them all back.
struct Unspooled {
    inner: Arc<Inner>,
    seq: u64,
    size: u64,
    armed: bool,
}

impl Drop for Unspooled {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        // Its file goes before its room does: what the room counts is
        // never less than what the folder holds. Best effort, and quick.
        let _ = fs::remove_file(self.inner.file(self.seq));
        let mut state = self.inner.state();
        state.queue.retain(|entry| entry.seq != self.seq);
        state.free += self.size;
        drop(state);
        let size = self.size;
        self.inner
            .queued_bytes
            .send_modify(|bytes| *bytes = bytes.saturating_sub(size));
        self.inner.changed();
    }
}

impl Spool {
    /// A spool of `room` bytes in a new session folder under the
    /// replica's spool folder `under`, landing through `pool`, its Lander
    /// running on `runtime`.
    pub(crate) fn start(
        under: &Path,
        room: u64,
        read_buffer: usize,
        pool: Arc<WriterPool>,
        runtime: &Handle,
    ) -> io::Result<Spool> {
        let folder = under.join(NEXT_SESSION.fetch_add(1, Ordering::Relaxed).to_string());
        fs::create_dir_all(&folder)?;
        let inner = Arc::new(Inner {
            folder,
            read_buffer,
            state: Mutex::new(State {
                free: room,
                next: 0,
                queue: VecDeque::new(),
                landing: 0,
                landed: Vec::new(),
                closed: false,
            }),
            changes: watch::Sender::new(0),
            queued_bytes: watch::Sender::new(0),
            turn: tokio::sync::Mutex::new(()),
        });
        let lander = runtime
            .spawn(run_lander(inner.clone(), pool.clone()))
            .abort_handle();
        Ok(Spool {
            inner,
            pool,
            room,
            lander,
        })
    }

    pub(crate) fn room(&self) -> u64 {
        self.room
    }

    /// The bytes staged and not yet handed to a writer: a spooled file's
    /// size less what the Lander has read of it so far.
    pub(crate) fn queued_bytes(&self) -> watch::Receiver<u64> {
        self.inner.queued_bytes.subscribe()
    }

    /// Takes `body` to a writer or into the spool (see the module), and
    /// answers once it has all arrived. A body that fails, or runs past
    /// `source`'s size, fails the stage, leaving nothing queued and no
    /// spool file; so does a stage dropped before it answers.
    pub(crate) async fn stage(
        &self,
        path: RelPath,
        body: Body,
        source: FileState,
        expect: Precondition,
    ) -> Result<(), ReplicaError> {
        let size = source.meta.size;
        let place = self.place(&path, source, expect, size).await?;
        match place {
            Place::Writer(slot, unlanded) => {
                self.to_writer(slot, unlanded, path, body, source, expect)
                    .await
            }
            Place::Spool(unspooled) => self.to_spool(unspooled, &path, body).await,
        }
    }

    /// Waits for a place for a body of `size` bytes, then takes it: a
    /// writer's slot, or room reserved and a queue entry.
    async fn place(
        &self,
        path: &RelPath,
        source: FileState,
        expect: Precondition,
        size: u64,
    ) -> Result<Place, ReplicaError> {
        let _turn = self.inner.turn.lock().await;
        let mut changes = self.inner.changes.subscribe();
        loop {
            changes.borrow_and_update();
            let queue_empty = {
                // One critical section: the slot taken, the queue checked,
                // the entry and the reservation made.
                let mut state = self.inner.state();
                if state.queue.is_empty()
                    && let Some(slot) = self.pool.try_slot()
                {
                    state.landing += 1;
                    return Ok(Place::Writer(slot, self.unlanded()));
                }
                if size <= state.free {
                    state.free -= size;
                    let seq = state.next;
                    state.next += 1;
                    state.queue.push_back(Entry {
                        seq,
                        path: path.clone(),
                        source,
                        expect,
                        size,
                        whole: false,
                    });
                    self.inner.queued_bytes.send_modify(|bytes| *bytes += size);
                    return Ok(Place::Spool(Unspooled {
                        inner: self.inner.clone(),
                        seq,
                        size,
                        armed: true,
                    }));
                }
                state.queue.is_empty()
            };
            // Nothing queued and no room: only a writer can take it. With
            // anything queued a slot is no use; room, or the queue
            // emptying, comes as a change.
            if !queue_empty {
                wait(&mut changes).await;
                continue;
            }
            tokio::select! {
                slot = self.pool.slot() => {
                    let Some(slot) = slot else {
                        return Err(ReplicaError::Halted("the writer pool stopped".into()));
                    };
                    let mut state = self.inner.state();
                    if state.queue.is_empty() {
                        state.landing += 1;
                        return Ok(Place::Writer(slot, self.unlanded()));
                    }
                }
                () = wait(&mut changes) => {}
            }
        }
    }

    fn unlanded(&self) -> Unlanded {
        Unlanded {
            inner: self.inner.clone(),
            armed: true,
        }
    }

    /// Case 1: hands `body` to the writer on `slot`, and answers at its
    /// end; what landed goes to the landings when the writer answers.
    async fn to_writer(
        &self,
        slot: Slot,
        mut unlanded: Unlanded,
        path: RelPath,
        body: Body,
        source: FileState,
        expect: Precondition,
    ) -> Result<(), ReplicaError> {
        let (handed, pumped) = self
            .pool
            .hand_over(slot, path.clone(), body, source, expect)
            .await;
        // From here a task waits on the writer and counts the landing out,
        // whether or not this stage is still there to hear.
        unlanded.armed = false;
        let (verdict, answer) = await_writer(self.inner.clone(), path, handed);
        let whole = match pumped {
            Pumped::Whole => true,
            Pumped::Failed => false,
            // The writer stopped first: its answer is a landing's, as long
            // as the body itself still ends whole.
            Pumped::Stopped(body) => drain(body).await.is_ok(),
        };
        let _ = verdict.send(whole);
        if whole {
            return Ok(());
        }
        answer.await.unwrap_or_else(|_| {
            Err(ReplicaError::Halted(
                "the runtime shut down under a stage".into(),
            ))
        })
    }

    /// Case 2: writes `body` into its spool file and marks its entry
    /// whole; on any failure, `unspooled` gives the entry, its room and
    /// its file back.
    async fn to_spool(
        &self,
        mut unspooled: Unspooled,
        path: &RelPath,
        body: Body,
    ) -> Result<(), ReplicaError> {
        let file = self.inner.file(unspooled.seq);
        spool_body(file, unspooled.size, path, body).await?;
        unspooled.armed = false;
        let mut state = self.inner.state();
        if let Some(entry) = state
            .queue
            .iter_mut()
            .find(|entry| entry.seq == unspooled.seq)
        {
            entry.whole = true;
        }
        drop(state);
        self.inner.changed();
        Ok(())
    }

    /// A long poll: every landing answered since the last call, once there
    /// is one, or at once when nothing is queued or landing.
    pub(crate) async fn take_landed(&self) -> Landings {
        let mut changes = self.inner.changes.subscribe();
        loop {
            changes.borrow_and_update();
            {
                let mut state = self.inner.state();
                if !state.landed.is_empty() || state.idle() {
                    return Landings {
                        landed: std::mem::take(&mut state.landed),
                        queued: state.queue.len() as u64 + state.landing,
                    };
                }
            }
            wait(&mut changes).await;
        }
    }

    /// Waits until nothing is queued or landing.
    pub(crate) async fn settle(&self) {
        let mut changes = self.inner.changes.subscribe();
        loop {
            changes.borrow_and_update();
            if self.inner.state().idle() {
                return;
            }
            wait(&mut changes).await;
        }
    }
}

impl Drop for Spool {
    fn drop(&mut self) {
        // Under the state's lock, so the Lander, wherever it is, starts no
        // landing after this returns; the abort stops it waiting.
        self.inner.state().closed = true;
        self.lander.abort();
    }
}

impl Inner {
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn file(&self, seq: u64) -> PathBuf {
        self.folder.join(seq.to_string())
    }

    fn changed(&self) {
        self.changes
            .send_modify(|count| *count = count.wrapping_add(1));
    }

    /// A landing answered: its result buffered, its `room` freed.
    fn finish(&self, path: RelPath, landed: Result<FileMeta, ReplicaError>, room: u64) {
        let mut state = self.state();
        state.landing -= 1;
        state.free += room;
        state.landed.push((path, landed));
        drop(state);
        self.changed();
    }

    /// A case-1 landing whose stage failed, and reports it.
    fn unland(&self) {
        let mut state = self.state();
        state.landing -= 1;
        drop(state);
        self.changed();
    }

    /// Counts `bytes` of a spooled file as handed to a writer.
    fn handed(&self, bytes: u64) {
        self.queued_bytes
            .send_modify(|queued| *queued = queued.saturating_sub(bytes));
    }
}

impl State {
    fn idle(&self) -> bool {
        self.queue.is_empty() && self.landing == 0
    }
}

/// Waits for the next change; a spool whose sender is gone changes no more.
async fn wait(changes: &mut watch::Receiver<u64>) {
    if changes.changed().await.is_err() {
        std::future::pending::<()>().await;
    }
}

/// Waits on a case-1 landing's writer in a task of its own, so a stage
/// dropped meanwhile still counts it out. The stage sends whether its body
/// ended whole: then what landed is a landing, reported later. Otherwise,
/// or with no word from the stage, a failed landing is the stage's to
/// report, and comes back on the answer.
fn await_writer(
    inner: Arc<Inner>,
    path: RelPath,
    handed: Handed,
) -> (
    oneshot::Sender<bool>,
    oneshot::Receiver<Result<(), ReplicaError>>,
) {
    let (verdict, heard) = oneshot::channel();
    let (answer, answered) = oneshot::channel();
    tokio::spawn(async move {
        let landed = handed.landed().await;
        let whole = heard.await.unwrap_or(false);
        let answered = match landed {
            Err(error) if !whole => {
                inner.unland();
                Err(error)
            }
            // A writer whose body failed fails too; were it not to, what
            // landed is reported as any landing is.
            landed => {
                inner.finish(path, landed, 0);
                Ok(())
            }
        };
        let _ = answer.send(answered);
    });
    (verdict, answered)
}

/// The Lander: hands the queue's head to a writer once it is whole and a
/// slot is free, as many at once as there are writers.
async fn run_lander(inner: Arc<Inner>, pool: Arc<WriterPool>) {
    let mut changes = inner.changes.subscribe();
    loop {
        changes.borrow_and_update();
        let ready = inner.state().queue.front().is_some_and(|head| head.whole);
        if !ready {
            wait(&mut changes).await;
            continue;
        }
        // Only the Lander takes from the queue, and a whole entry's stage
        // is done with it: the head is still this one once a slot is free.
        let Some(slot) = pool.slot().await else {
            return;
        };
        let entry = {
            let mut state = inner.state();
            if state.closed {
                return;
            }
            let Some(entry) = state.queue.pop_front() else {
                continue;
            };
            state.landing += 1;
            entry
        };
        // A stage that waits behind a non-empty queue may now take a free
        // writer.
        inner.changed();
        tokio::spawn(land(inner.clone(), pool.clone(), slot, entry));
    }
}

/// Lands one spooled file on `slot`, from its spool file, then removes the
/// file and frees its room.
async fn land(inner: Arc<Inner>, pool: Arc<WriterPool>, slot: Slot, entry: Entry) {
    let Entry {
        seq,
        path,
        source,
        expect,
        size,
        ..
    } = entry;
    let file = inner.file(seq);
    let (sender, body) = body_channel(READ_AHEAD_CHUNKS);
    let reader = inner.clone();
    let from = file.clone();
    tokio::task::spawn_blocking(move || send_spooled(&from, size, &reader, sender));
    let (handed, _) = pool
        .hand_over(slot, path.clone(), body, source, expect)
        .await;
    let landed = handed.landed().await;
    let _ = tokio::task::spawn_blocking(move || fs::remove_file(file)).await;
    inner.finish(path, landed, size);
}

/// Streams spool file `file` into `sender`, counting each chunk sent as
/// handed to a writer, and whatever of its `size` is left once it stops.
/// `send_file`'s shape, without the source check: the bytes were checked
/// as they arrived.
fn send_spooled(file: &Path, size: u64, inner: &Inner, sender: BodySender) {
    let mut left = size;
    let mut count = |bytes: u64| {
        let counted = bytes.min(left);
        left -= counted;
        inner.handed(counted);
    };
    match File::open(file) {
        Err(error) => {
            let _ = sender.blocking_fail(error);
        }
        Ok(mut file) => loop {
            let mut chunk = vec![0; inner.read_buffer];
            match fill(&mut file, &mut chunk) {
                Ok(read) => {
                    chunk.truncate(read);
                    if read > 0 {
                        if sender.blocking_send(chunk).is_err() {
                            break;
                        }
                        count(read as u64);
                    }
                    if read < inner.read_buffer {
                        let _ = sender.blocking_finish();
                        break;
                    }
                }
                Err(error) => {
                    let _ = sender.blocking_fail(error);
                    break;
                }
            }
        },
    }
    count(u64::MAX);
}

/// Writes `body` into a new spool file at `file`, unsynced. Takes the body
/// whole even when the file fails, as a refused stage does; a failed body
/// fails it as it fails a write. A body past `size` bytes fails at once,
/// untaken.
async fn spool_body(
    file: PathBuf,
    size: u64,
    path: &RelPath,
    mut body: Body,
) -> Result<(), ReplicaError> {
    // `None` ends the file whole; a channel closed without it - a body
    // that failed, or a stage dropped - has the writer remove its file
    // once it is done with it, so none is left behind it.
    let (chunks, mut taken) = mpsc::channel::<Option<Vec<u8>>>(SPOOL_AHEAD_CHUNKS);
    let writer = tokio::task::spawn_blocking(move || {
        let mut out = File::create(&file)?;
        loop {
            match taken.blocking_recv() {
                Some(Some(bytes)) => out.write_all(&bytes)?,
                Some(None) => return io::Result::Ok(()),
                None => break,
            }
        }
        drop(out);
        let _ = fs::remove_file(&file);
        Ok(())
    });
    let mut failed = None;
    let mut writing = true;
    let mut received = 0u64;
    loop {
        match body.next().await {
            Ok(Some(bytes)) => {
                received += bytes.len() as u64;
                // Never past the room reserved for it: a source replaced
                // by a larger file after its scan would otherwise fill the
                // state volume before its check fails it. Failed at once,
                // the rest untaken.
                if received > size {
                    failed = Some(ReplicaError::Write(WriteError {
                        path: path.clone(),
                        stage: Stage::Wait,
                        source: io::Error::new(
                            io::ErrorKind::InvalidData,
                            "the body runs past its source's size",
                        ),
                    }));
                    break;
                }
                writing = writing && chunks.send(Some(bytes)).await.is_ok();
            }
            Ok(None) => {
                let _ = chunks.send(None).await;
                break;
            }
            Err(error) => {
                failed = Some(body_failed(path, error));
                break;
            }
        }
    }
    drop(chunks);
    let written = joined(writer.await)?;
    if let Some(error) = failed {
        return Err(error);
    }
    written.map_err(|source| {
        ReplicaError::Write(WriteError {
            path: path.clone(),
            stage: Stage::Write,
            source,
        })
    })
}

/// Reads what is left of `body` to its end.
async fn drain(mut body: Body) -> Result<(), crate::body::BodyError> {
    while body.next().await?.is_some() {}
    Ok(())
}

/// A body that failed, as a write fed it would fail.
fn body_failed(path: &RelPath, error: crate::body::BodyError) -> ReplicaError {
    ReplicaError::Write(WriteError {
        path: path.clone(),
        stage: Stage::Wait,
        source: error.into(),
    })
}

/// A blocking task's result; its panic goes on unwinding here.
fn joined<T>(result: Result<T, JoinError>) -> Result<T, ReplicaError> {
    result.or_else(|error| match error.try_into_panic() {
        Ok(panic) => std::panic::resume_unwind(panic),
        Err(_) => Err(ReplicaError::Halted(
            "the runtime shut down under a spool write".into(),
        )),
    })
}

/// Removes a spool folder and everything in it: what a crashed or stopped
/// run left, or this session's, once settled. Best effort, like the
/// staging folder's sweep: a leftover only costs space.
pub(crate) fn sweep(folder: &Path) {
    let _ = fs::remove_dir_all(folder);
}

/// The room a spool may take at a lock: `tuning`'s cap, or the space free
/// on `state`'s volume less the reserve, whichever is less.
pub(crate) fn room_at(state: &Path, tuning: &Tuning) -> u64 {
    room(
        tuning.spool_bytes,
        tuning.spool_reserve_bytes,
        available(state),
    )
}

/// The lesser of `cap` and `available` less `reserve`, saturating at zero;
/// zero when the free space is unknown.
fn room(cap: u64, reserve: u64, available: Option<u64>) -> u64 {
    available.map_or(0, |free| cap.min(free.saturating_sub(reserve)))
}

/// The bytes an unprivileged writer may still take on `dir`'s volume.
#[cfg(unix)]
fn available(dir: &Path) -> Option<u64> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let path = CString::new(dir.as_os_str().as_bytes()).ok()?;
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    // SAFETY: `path` is NUL-terminated and outlives the call; `stat` is
    // only read once the call says it filled it.
    if unsafe { libc::statvfs(path.as_ptr(), stat.as_mut_ptr()) } != 0 {
        return None;
    }
    let stat = unsafe { stat.assume_init() };
    // Widened, not cast: both are narrower on some targets.
    let free = u128::from(stat.f_bavail) * u128::from(stat.f_frsize);
    Some(u64::try_from(free).unwrap_or(u64::MAX))
}

/// No free-space probe off unix: no spool, rather than one that could fill
/// the volume.
#[cfg(not(unix))]
fn available(_: &Path) -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const GIB: u64 = 1 << 30;

    #[test]
    fn room_is_the_cap_or_the_free_space_less_the_reserve_whichever_is_less() {
        assert_eq!(room(GIB, GIB / 2, Some(10 * GIB)), GIB, "the cap");
        assert_eq!(room(GIB, GIB / 2, Some(GIB)), GIB / 2, "the free space");
    }

    #[test]
    fn room_saturates_at_zero_when_the_reserve_takes_every_free_byte() {
        assert_eq!(room(GIB, GIB / 2, Some(GIB / 2)), 0);
        assert_eq!(room(GIB, GIB / 2, Some(1)), 0);
        assert_eq!(room(GIB, 0, Some(0)), 0);
    }

    #[test]
    fn room_is_zero_when_the_free_space_is_unknown() {
        assert_eq!(room(GIB, 0, None), 0);
    }

    #[cfg(unix)]
    #[test]
    fn a_real_volume_reports_its_free_space() {
        let dir = tempfile::tempdir().unwrap();
        assert!(available(dir.path()).is_some_and(|free| free > 0));
        assert_eq!(available(&dir.path().join("missing")), None);
    }
}
