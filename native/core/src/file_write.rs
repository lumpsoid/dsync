//! Landing one file on a writer thread (SPEC §7.2-§7.6): parent folders,
//! what is at the target, a temp in the staging folder renamed onto it, the
//! bytes, mtime, mode, and the state that actually landed. Blocking
//! `std::fs` throughout; the pool (`writer_pool`) runs it on its own
//! threads.

use std::collections::HashSet;
use std::fs::{self, File, OpenOptions, Permissions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use dsync_domain::{
    ChangedDuringSync, FileMeta, Precondition, RelPath, STAGING_DIR, temp_name_for,
};
use tokio::sync::{OwnedSemaphorePermit, mpsc};

use crate::body::BodyError;
use crate::confinement::Confinement;
use crate::local_root::{Located, Root};
use crate::replica_error::ReplicaError;
use crate::scanner::{on_disk_at, stat};
use crate::write_error::WriteError;
use dsync_domain::{Stage, WriteStats};

/// One piece of a file's body as the pool hands it to a writer. A chunk
/// holds its share of the pool's byte budget until it is written.
pub(crate) enum Chunk {
    Bytes(Vec<u8>, OwnedSemaphorePermit),
    End,
    Failed(BodyError),
}

/// Where a replica's writes land, shared by its writer threads for the
/// session.
pub(crate) struct Destination {
    root: Arc<Root>,
    /// Parent folders this session has created or found, relative to the
    /// root's base. See
    /// [`Destination::ensure_parent`].
    parents: Mutex<HashSet<RelPath>>,
    /// Whether this session has created the staging folder. See
    /// [`Destination::ensure_staging`].
    staged: Mutex<bool>,
    modes: ModeStep,
    /// Refuses a write through a link the replica may not go through.
    confinement: Arc<Confinement>,
}

impl Destination {
    pub(crate) fn new(root: Arc<Root>, confinement: Arc<Confinement>) -> Destination {
        Destination {
            root,
            parents: Mutex::new(HashSet::new()),
            staged: Mutex::new(false),
            modes: ModeStep::for_host(),
            confinement,
        }
    }

    /// Forgets `folder`: it was removed ([`crate::Replica::remove_empty_dirs`]),
    /// so a later write under it creates it again rather than trusting it.
    pub(crate) fn forget(&self, folder: &RelPath) {
        self.parents().remove(folder);
        self.confinement.forget(folder);
    }

    fn parents(&self) -> MutexGuard<'_, HashSet<RelPath>> {
        self.parents.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn staged(&self) -> MutexGuard<'_, bool> {
        self.staged.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The folder this replica's writes create their temps in (SPEC §7.2):
    /// on emulated storage a create costs more the fuller its folder, and a
    /// rename into a folder costs less than a create in it.
    fn staging(&self) -> PathBuf {
        self.root.base().join(STAGING_DIR)
    }

    /// Creates the staging folder unless this session already has, and
    /// answers whether it did. Remembered only after the create succeeds.
    fn ensure_staging(&self) -> io::Result<bool> {
        let mut staged = self.staged();
        if *staged {
            return Ok(false);
        }
        fs::create_dir_all(self.staging())?;
        *staged = true;
        Ok(true)
    }

    /// Removes the staging folder and whatever is in it: temps a crashed
    /// or stopped write left. Called under the replica's lock, at lock and
    /// at unlock, so no write of this replica is still using one (one that
    /// is, after a hard stop, fails its rename and is retried next run).
    /// Best effort: a leftover only costs space, and the scan skips it.
    pub(crate) fn clear_staging(&self) {
        let mut staged = self.staged();
        let _ = fs::remove_dir_all(self.staging());
        *staged = false;
    }

    /// Creates `folder` unless this session already has. A set lookup
    /// instead of a `create_dir_all` per file: one per folder a run writes
    /// into, not one per file (618 µs of a phone's 8.6 ms per file, Dart
    /// task 9d2158).
    ///
    /// The answer can go stale in two ways: this replica prunes the folder
    /// (it forgets it then), or something outside the run removes it, which
    /// the replica lock does not prevent. The second surfaces as a failed
    /// write, and a failed write forgets its parent, so the next path under
    /// it creates it again: one path fails, not every one under it.
    ///
    /// `folder` is a located path's parent ([`Located::rel`]): a single-file
    /// root's file has none, so its folder is never created here.
    fn ensure_parent(&self, folder: &RelPath) -> io::Result<bool> {
        if self.parents().contains(folder) {
            return Ok(false);
        }
        // Remembered only after the create succeeds.
        fs::create_dir_all(folder.join_under(self.root.base()))?;
        self.parents().insert(folder.clone());
        Ok(true)
    }
}

/// Whether writes on a replica set permission bits (SPEC §7.4), settled
/// once per session by the first write rather than per file.
///
/// Skipped outright on Windows, which has no mode bits. Elsewhere the first
/// write asks the filesystem once ([`modes_stick`]): the phone's shared
/// storage accepts a `chmod` and changes nothing, and at ~0.5 ms a FUSE
/// round trip that is ~3% of a 3,000-file pull for nothing. Skipping
/// records nothing different: the closing stat archives what landed.
///
/// A `chmod` that runs and fails for one path does not settle anything:
/// that is a per-path outcome, and the stat already records it.
pub(crate) struct ModeStep {
    applies: OnceLock<bool>,
}

impl ModeStep {
    fn for_host() -> ModeStep {
        let applies = OnceLock::new();
        if cfg!(not(unix)) {
            let _ = applies.set(false);
        }
        ModeStep { applies }
    }

    /// Sets `file`'s bits to `mode`, best effort, unless modes do not
    /// stick under `root`.
    fn apply(&self, root: &Path, file: &File, mode: u32) {
        if *self.applies.get_or_init(|| modes_stick(root)) {
            // A refusal is not fatal (SPEC §7.4); the stat records it.
            let _ = file.set_permissions(permissions(mode));
        }
    }
}

#[cfg(unix)]
fn permissions(mode: u32) -> Permissions {
    use std::os::unix::fs::PermissionsExt;
    Permissions::from_mode(mode)
}

#[cfg(not(unix))]
fn permissions(_: u32) -> Permissions {
    unreachable!("the mode step is settled as skipped where there are no mode bits")
}

/// The owner-execute bit, flipped by [`modes_stick`]: harmless on a
/// scratch file, and a bit no umask default sets.
const PROBE_BIT: u32 = 0o100;

/// Whether a `chmod` under `root` changes anything: flip one bit on a
/// scratch file and read it back. The scratch file has a temp name, so one
/// a crash leaves behind is skipped by every scan.
///
/// Conservative when it cannot tell: a root it cannot create a file in
/// answers yes, keeping the per-file `chmod`.
fn modes_stick(root: &Path) -> bool {
    let scratch = root.join(temp_name_for(
        ".dsync-mode-probe",
        std::process::id(),
        next_temp(),
    ));
    let Ok(file) = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&scratch)
    else {
        return true;
    };
    let sticks = (|| {
        let asked = mode_bits(&file.metadata()?) ^ PROBE_BIT;
        file.set_permissions(permissions(asked))?;
        io::Result::Ok(mode_bits(&file.metadata()?) == asked)
    })()
    .unwrap_or(true);
    drop(file);
    // Best effort: the answer is in hand, and a leftover is skipped.
    let _ = fs::remove_file(&scratch);
    sticks
}

#[cfg(unix)]
fn mode_bits(meta: &fs::Metadata) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    meta.permissions().mode() & 0o7777
}

#[cfg(not(unix))]
fn mode_bits(_: &fs::Metadata) -> u32 {
    0
}

/// Temp-name sequence numbers, unique within the process (the name also
/// carries the pid), so two writes never stream into one scratch file.
static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

fn next_temp() -> u64 {
    NEXT_TEMP.fetch_add(1, Ordering::Relaxed)
}

/// Lands `path` with the bytes arriving on `chunks`, and returns the
/// metadata that actually landed (SPEC §7.4: the post-write state, not the
/// one asked for). Every stage is timed into `stats`.
///
/// Unless `path` is no longer what `expect` says the scan saw there: then
/// nothing is touched, and the write fails [`ReplicaError::Changed`] (SPEC
/// §7.6). Checked by the stat the write makes anyway, just before acting.
///
/// On failure the target is untouched: the bytes only ever reach it by
/// the rename, whole (SPEC §7.6). The temp is this write's own and is
/// removed. The parent folder and the staging folder are forgotten, on any
/// failure: a wrongly forgotten folder costs one redundant create on a
/// path that was failing anyway.
pub(crate) fn write_file(
    destination: &Destination,
    path: &RelPath,
    meta: FileMeta,
    expect: Precondition,
    chunks: &mut mpsc::UnboundedReceiver<Chunk>,
    stats: &mut WriteStats,
) -> Result<FileMeta, ReplicaError> {
    let mut timer = StageTimer::new(stats);
    let mut scratch: Option<Scratch> = None;
    // Refused before anything is looked at: a path outside the root.
    let located = destination.root.locate(path).map_err(|source| {
        ReplicaError::Write(WriteError {
            path: path.clone(),
            stage: Stage::Probe,
            source,
        })
    })?;
    let landed = land(
        destination,
        &located,
        meta,
        expect,
        chunks,
        &mut timer,
        &mut scratch,
    );
    if landed.is_err() {
        if let Some(parent) = located.rel.parent() {
            destination.forget(&parent);
        }
        // Like the parent: a staging folder removed under the session is
        // created again by the next write.
        *destination.staged() = false;
        if let Some(scratch) = scratch {
            let _ = fs::remove_file(scratch.path);
        }
    }
    landed.map_err(|failed| match failed {
        Failed::At(stage, source) => ReplicaError::Write(WriteError {
            path: path.clone(),
            stage,
            source,
        }),
        Failed::Changed(changed) => ReplicaError::Changed(changed),
    })
}

enum Failed {
    At(Stage, io::Error),
    Changed(ChangedDuringSync),
}

impl From<ChangedDuringSync> for Failed {
    fn from(changed: ChangedDuringSync) -> Failed {
        Failed::Changed(changed)
    }
}

fn at(stage: Stage) -> impl FnOnce(io::Error) -> Failed {
    move |source| Failed::At(stage, source)
}

fn land(
    destination: &Destination,
    located: &Located,
    meta: FileMeta,
    expect: Precondition,
    chunks: &mut mpsc::UnboundedReceiver<Chunk>,
    timer: &mut StageTimer,
    scratch: &mut Option<Scratch>,
) -> Result<FileMeta, Failed> {
    let Located { path: target, rel } = located;
    // Before anything is looked at through a link it may not go through.
    destination
        .confinement
        .check(rel)
        .map_err(at(Stage::Probe))?;
    // Before the folders too: a path whose parent is not there reads as
    // absent, and one that changed leaves nothing behind.
    let now = on_disk_at(target);
    timer.lap(Stage::Probe);
    expect.check(now)?;
    if let Some(parent) = rel.parent()
        && destination
            .ensure_parent(&parent)
            .map_err(at(Stage::Mkdir))?
    {
        timer.lap(Stage::Mkdir);
    }
    if destination.ensure_staging().map_err(at(Stage::Mkdir))? {
        timer.lap(Stage::Mkdir);
    }

    let mut file = create_scratch(&destination.staging(), target, scratch, timer)?;
    loop {
        let chunk = chunks.blocking_recv();
        timer.lap(Stage::Wait);
        match chunk {
            Some(Chunk::Bytes(bytes, budget)) => {
                file.write_all(&bytes).map_err(at(Stage::Write))?;
                drop(budget);
                timer.lap(Stage::Write);
            }
            Some(Chunk::End) => break,
            Some(Chunk::Failed(error)) => return Err(Failed::At(Stage::Wait, error.into())),
            None => return Err(Failed::At(Stage::Wait, BodyError::CutShort.into())),
        }
    }

    // Best effort (SPEC §7.4): the stat below records whatever landed.
    let _ = file.set_modified(system_time(meta.mtime_us));
    timer.lap(Stage::Mtime);
    destination
        .modes
        .apply(destination.root.base(), &file, meta.mode);
    timer.lap(Stage::Mode);
    drop(file);
    timer.lap(Stage::Close);
    if let Some(staged) = scratch.as_mut() {
        rename_onto(staged, meta).map_err(at(Stage::Rename))?;
        *scratch = None;
        timer.lap(Stage::Rename);
    }
    let landed = stat(target).map_err(at(Stage::Stat))?;
    timer.lap(Stage::Stat);
    Ok(landed)
}

/// The file a write to `target` lands on: its symlink's target when it is
/// one, so the rename replaces that file and the link survives (SPEC §5.1);
/// the path itself when it cannot be resolved.
fn landing(target: &Path) -> PathBuf {
    fs::canonicalize(target).unwrap_or_else(|_| target.to_path_buf())
}

/// A write's temp, and the file it is renamed onto.
struct Scratch {
    path: PathBuf,
    onto: PathBuf,
}

/// Creates the temp a write streams into, in `staging`, and records it in
/// `scratch` for the rename or the cleanup.
fn create_scratch(
    staging: &Path,
    target: &Path,
    scratch: &mut Option<Scratch>,
    timer: &mut StageTimer,
) -> Result<File, Failed> {
    let onto = landing(target);
    let path = staging.join(temp_name(&onto).map_err(at(Stage::Create))?);
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(at(Stage::Create))?;
    *scratch = Some(Scratch { path, onto });
    timer.lap(Stage::Create);
    Ok(file)
}

/// A temp name for a write onto `onto`, unique within the host.
fn temp_name(onto: &Path) -> io::Result<String> {
    let name = onto
        .file_name()
        .ok_or_else(|| io::Error::other("the target has no file name"))?
        .to_string_lossy();
    Ok(temp_name_for(&name, std::process::id(), next_temp()))
}

/// Renames `scratch` onto its target. A target on another filesystem than
/// the staging folder - behind a followed link onto another mount - cannot
/// take a rename from it, so the temp is copied beside the target first,
/// its mtime set again, and renamed from there. On success `scratch` no
/// longer exists; on failure it names whichever temp is left to remove.
fn rename_onto(scratch: &mut Scratch, meta: FileMeta) -> io::Result<()> {
    match fs::rename(&scratch.path, &scratch.onto) {
        Err(error) if error.kind() == io::ErrorKind::CrossesDevices => {
            let beside = scratch.onto.with_file_name(temp_name(&scratch.onto)?);
            let copied = fs::copy(&scratch.path, &beside).and_then(|_| {
                let file = OpenOptions::new().write(true).open(&beside)?;
                // Best effort, as for the temp (SPEC §7.4).
                let _ = file.set_modified(system_time(meta.mtime_us));
                Ok(())
            });
            if let Err(error) = copied {
                let _ = fs::remove_file(&beside);
                return Err(error);
            }
            let _ = fs::remove_file(&scratch.path);
            scratch.path = beside;
            fs::rename(&scratch.path, &scratch.onto)
        }
        renamed => renamed,
    }
}

/// Microseconds since the epoch, negative before it, as a time to set.
fn system_time(mtime_us: i64) -> SystemTime {
    let offset = Duration::from_micros(mtime_us.unsigned_abs());
    if mtime_us >= 0 {
        UNIX_EPOCH + offset
    } else {
        UNIX_EPOCH - offset
    }
}

/// Times consecutive stages: each [`StageTimer::lap`] records the time
/// since the last.
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn destination(root: &Path, modes_apply: bool) -> Destination {
        let confinement = Confinement::new(root.to_path_buf(), crate::Symlinks::AsRuled);
        let folder = Root::folder(root.to_str().unwrap().to_owned());
        let destination = Destination::new(Arc::new(folder), Arc::new(confinement));
        destination.modes.applies.set(modes_apply).unwrap();
        destination
    }

    /// Lands `content` at `name` with `mode` asked.
    fn land_file(destination: &Destination, name: &str, mode: u32) -> FileMeta {
        let (chunks_tx, mut chunks) = mpsc::unbounded_channel();
        let budget = std::sync::Arc::new(tokio::sync::Semaphore::new(1));
        let permit = budget.try_acquire_owned().unwrap();
        chunks_tx.send(Chunk::Bytes(b"hello".to_vec(), permit)).ok();
        chunks_tx.send(Chunk::End).ok();
        let meta = FileMeta {
            size: 5,
            mtime_us: 0,
            mode,
        };
        write_file(
            destination,
            &RelPath::parse(name).unwrap(),
            meta,
            Precondition::Absent,
            &mut chunks,
            &mut WriteStats::one_writer(),
        )
        .unwrap()
    }

    #[test]
    fn modes_stick_on_an_ordinary_filesystem_and_leave_no_probe_behind() {
        let root = tempfile::tempdir().unwrap();

        assert!(modes_stick(root.path()));
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
    }

    #[test]
    fn once_modes_are_found_not_to_stick_no_write_sets_them_and_what_landed_is_recorded() {
        let root = tempfile::tempdir().unwrap();
        let skipping = destination(root.path(), false);
        let applying = destination(root.path(), true);

        let skipped = land_file(&skipping, "skipped", 0o700);
        // Positive control: the same write where modes stick sets them.
        let applied = land_file(&applying, "applied", 0o700);

        assert_ne!(skipped.mode, 0o700);
        assert_eq!(
            skipped.mode,
            mode_bits(&fs::metadata(root.path().join("skipped")).unwrap())
        );
        assert_eq!(applied.mode, 0o700);
    }
}
