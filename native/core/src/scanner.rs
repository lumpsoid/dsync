//! Walks a replica's tree and gives each file its status against the
//! replica's own archive (SPEC §5).
//!
//! Three steps, only the first two touching the disk:
//!
//! 1. **Walk** (this thread): list each directory without following links,
//!    sorted by name, pruning ignored paths before they are opened,
//!    following a symlink only when a follow rule names it. The result is
//!    the walk's events in order: files to stat, and paths reported instead.
//! 2. **Stat, then hash** on the bounded pool (plan D3): every file's
//!    metadata in walk order; then the files the archive's fast path did
//!    not settle, hashed largest first so a big file starts early instead
//!    of becoming the straggler every other worker waits on.
//! 3. **Conclude** in the domain: [`Archive::fast_path`] and
//!    [`Archive::hashed_status`] per file, [`ScanResult::assemble`] for the
//!    deletions, untrusted-absent paths and case-fold collisions.
//!
//! Everything reported comes back in walk order, however the pool's work
//! fell.

use std::ffi::OsString;
use std::fs::{self, File, FileType, Metadata};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use dsync_domain::{
    Archive, CaseFolding, ContentHash, FileMeta, FileState, Jobs, OnDisk, RelPath, RelPathError,
    RuleSet, ScanEntry, ScanResult, SkippedPath, SkippedReason, Status, WalkedTree,
    is_temp_file_name,
};
use ring::digest;

use crate::scan_pool;

/// How much of a file one read takes into the hash. Large enough that most
/// files are one syscall and a big one costs few, small enough that `jobs`
/// of them are nothing beside the files being read.
pub const HASH_READ_BUFFER_BYTES: usize = 256 * 1024;

/// A replica scanner. `jobs` and `folding` belong to the host and the
/// filesystem under the root; the rules belong to the run and are passed
/// to each [`Scanner::scan`].
#[derive(Clone, Copy, Debug)]
pub struct Scanner {
    jobs: Jobs,
    folding: CaseFolding,
}

/// The replica root itself could not be resolved or listed. Fatal, not a
/// per-path skip: there is no tree left to sync, and reporting an empty
/// one would invite mirroring the whole other replica into it (SPEC §5).
#[derive(Debug, thiserror::Error)]
#[error("cannot read the replica root {}: {}", root.display(), describe(source))]
pub struct UnreadableRoot {
    pub root: PathBuf,
    #[source]
    pub source: io::Error,
}

impl Scanner {
    pub fn new(jobs: Jobs, folding: CaseFolding) -> Scanner {
        Scanner { jobs, folding }
    }

    /// One [`dsync_domain::ScanEntry`] per file present and not ignored,
    /// and per archived path now missing; everything the scan could not
    /// stand behind a status for is in `skipped`. Directories are traversed
    /// and never reported.
    pub fn scan(
        &self,
        root: &Path,
        archive: &Archive,
        rules: &RuleSet,
    ) -> Result<ScanResult, UnreadableRoot> {
        let events = walk(root, rules)?;
        let files: Vec<(&RelPath, &Path)> = events
            .iter()
            .filter_map(|event| match event {
                Event::File { path, source } => Some((path, source.as_path())),
                Event::Skipped(_) => None,
            })
            .collect();

        let metas = scan_pool::run(self.jobs, &files, || (), |(), (_, source)| stat(source));
        let mut outcomes: Vec<Outcome> = metas
            .into_iter()
            .zip(&files)
            .map(|(meta, (path, _))| match meta {
                Err(error) => Outcome::Unstatable(error),
                Ok(meta) => archive
                    .fast_path(path, meta)
                    .map_or(Outcome::ToHash(meta), Outcome::Settled),
            })
            .collect();

        let mut queue: Vec<(usize, &Path, FileMeta)> = outcomes
            .iter()
            .enumerate()
            .filter_map(|(index, outcome)| match outcome {
                Outcome::ToHash(meta) => Some((index, files[index].1, *meta)),
                _ => None,
            })
            .collect();
        largest_first(&mut queue);
        let hashes = scan_pool::run(
            self.jobs,
            &queue,
            || vec![0u8; HASH_READ_BUFFER_BYTES],
            |buffer, (_, source, _)| hash_file(source, buffer),
        );
        for ((index, _, meta), hash) in queue.into_iter().zip(hashes) {
            outcomes[index] = match hash {
                Ok(hash) => Outcome::Settled(
                    archive.hashed_status(files[index].0, FileState { meta, hash }),
                ),
                Err(error) => Outcome::Unhashable(error),
            };
        }

        let mut walked = WalkedTree::default();
        let mut outcomes = outcomes.into_iter();
        for event in events {
            let path = match event {
                Event::Skipped(skipped) => {
                    walked.skipped.push(skipped);
                    continue;
                }
                Event::File { path, .. } => path,
            };
            match outcomes.next() {
                Some(Outcome::Unstatable(error)) => walked.skipped.push(unreadable(path, &error)),
                // Stat'd, so known to be there: seen, whether or not it
                // could then be read, and never reported deleted.
                Some(Outcome::Settled(status)) => {
                    walked.seen.push(path.clone());
                    walked.present.push(ScanEntry::new(path, status));
                }
                Some(Outcome::Unhashable(error)) => {
                    walked.seen.push(path.clone());
                    walked.skipped.push(unreadable(path, &error));
                }
                Some(Outcome::ToHash(_)) | None => {
                    unreachable!("one hashed outcome per file event")
                }
            }
        }
        Ok(ScanResult::assemble(archive, rules, self.folding, walked))
    }
}

/// Where one walked file got to.
enum Outcome {
    /// Its stat failed: permission denied, or gone since the listing.
    Unstatable(io::Error),
    /// The fast path did not settle it; queued for the hash.
    ToHash(FileMeta),
    Settled(Status),
    /// Stat'd, then its read failed.
    Unhashable(io::Error),
}

/// The hash queue's order: largest first, so a big file starts early
/// rather than becoming the straggler every other worker waits on. Stable,
/// so equal sizes keep walk order.
fn largest_first<T>(queue: &mut [(T, &Path, FileMeta)]) {
    queue.sort_by_key(|(_, _, meta)| std::cmp::Reverse(meta.size));
}

/// One thing the walk met, in walk order.
enum Event {
    /// A regular file, or a followed link's target file, to be read from
    /// `source` and reported at `path`.
    File {
        path: RelPath,
        source: PathBuf,
    },
    Skipped(SkippedPath),
}

/// The walk's state: the rules, the directories it is inside (canonical,
/// so a followed link back into one of them is recognised), and what it
/// has met so far.
struct Walk<'a> {
    rules: &'a RuleSet,
    open: Vec<PathBuf>,
    events: Vec<Event>,
}

fn walk(root: &Path, rules: &RuleSet) -> Result<Vec<Event>, UnreadableRoot> {
    let unreadable_root = |source| UnreadableRoot {
        root: root.to_path_buf(),
        source,
    };
    let canonical = fs::canonicalize(root).map_err(unreadable_root)?;
    let children = list(&canonical).map_err(unreadable_root)?;
    let mut walk = Walk {
        rules,
        open: vec![canonical.clone()],
        events: Vec::new(),
    };
    walk.children(&canonical, None, children);
    Ok(walk.events)
}

/// A directory's entries and their types (as listed: a link is a link),
/// sorted by name.
fn list(dir: &Path) -> io::Result<Vec<(OsString, io::Result<FileType>)>> {
    let mut children = fs::read_dir(dir)?
        .map(|entry| entry.map(|entry| (entry.file_name(), entry.file_type())))
        .collect::<io::Result<Vec<_>>>()?;
    children.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(children)
}

impl Walk<'_> {
    /// `dir` (canonical) at `path`, which is not the root: listed, or
    /// reported unreadable.
    fn directory(&mut self, dir: PathBuf, path: RelPath) {
        match list(&dir) {
            Ok(children) => {
                self.open.push(dir.clone());
                self.children(&dir, Some(&path), children);
                self.open.pop();
            }
            Err(error) => self.skip(unreadable(path, &error)),
        }
    }

    fn children(
        &mut self,
        dir: &Path,
        parent: Option<&RelPath>,
        children: Vec<(OsString, io::Result<FileType>)>,
    ) {
        for (name, kind) in children {
            let Some(text) = name.to_str() else {
                let shown = name.to_string_lossy().into_owned();
                self.skip(SkippedPath::unrepresentable_name(
                    parent.cloned(),
                    shown,
                    "the name is not valid UTF-8",
                ));
                continue;
            };
            let path = match child_path(parent, text) {
                Ok(path) => path,
                Err(error) => {
                    self.skip(SkippedPath::unrepresentable_name(
                        parent.cloned(),
                        text,
                        error.to_string(),
                    ));
                    continue;
                }
            };
            // Pruned before it is opened: an ignored directory is never
            // listed, so nothing under it can fail.
            if self.rules.ignores(&path) {
                continue;
            }
            // A scratch file a crashed write left behind (SPEC §7.2):
            // reporting it would propagate dsync's own half-written data.
            if is_temp_file_name(text) {
                continue;
            }
            let source = dir.join(&name);
            match kind {
                Err(error) => self.skip(unreadable(path, &error)),
                Ok(kind) if kind.is_dir() => self.directory(source, path),
                Ok(kind) if kind.is_file() => self.events.push(Event::File { path, source }),
                Ok(kind) if kind.is_symlink() => {
                    if self.rules.follows(&path) {
                        self.link(&source, path);
                    } else {
                        // SPEC §5.1: skipped and reported - a link silently
                        // missing from a sync is the surprise to avoid.
                        self.skip(symlink(path, "no follow rule matched"));
                    }
                }
                // A socket, fifo or device: no run carries one.
                Ok(_) => {}
            }
        }
    }

    /// A link a follow rule names: its target's content is scanned at the
    /// link's own path.
    fn link(&mut self, link: &Path, path: RelPath) {
        let Ok(target) = fs::canonicalize(link) else {
            // The user asked to follow it; saying nothing would be the
            // worst answer.
            return self.skip(symlink(path, "broken link"));
        };
        match fs::metadata(&target) {
            Ok(meta) if meta.is_dir() => {
                if self.open.contains(&target) {
                    self.skip(symlink(
                        path,
                        "target is a directory this walk is already inside",
                    ));
                } else {
                    self.directory(target, path);
                }
            }
            Ok(meta) if meta.is_file() => self.events.push(Event::File {
                path,
                source: target,
            }),
            Ok(_) => self.skip(symlink(
                path,
                "target is neither a regular file nor a directory",
            )),
            Err(_) => self.skip(symlink(path, "broken link")),
        }
    }

    fn skip(&mut self, skipped: SkippedPath) {
        self.events.push(Event::Skipped(skipped));
    }
}

pub(crate) fn child_path(parent: Option<&RelPath>, name: &str) -> Result<RelPath, RelPathError> {
    match parent {
        Some(parent) => parent.child(name),
        None => RelPath::parse(name),
    }
}

fn symlink(path: RelPath, detail: &str) -> SkippedPath {
    SkippedPath::new(path, SkippedReason::Symlink, detail)
}

fn unreadable(path: RelPath, error: &io::Error) -> SkippedPath {
    SkippedPath::new(path, SkippedReason::Unreadable, describe(error))
}

/// The OS's own reason ("Permission denied", "No such file or
/// directory"): what tells a locked file from one that vanished mid-scan.
/// Without Rust's "(os error N)" suffix, which says nothing to a reader.
pub(crate) fn describe(error: &io::Error) -> String {
    let text = error.to_string();
    match (error.raw_os_error(), text.rsplit_once(" (os error ")) {
        (Some(_), Some((message, _))) => message.to_owned(),
        _ => text,
    }
}

/// A file's metadata as the fast path compares it. Follows a link, which
/// only a followed link's target ever is.
pub(crate) fn stat(source: &Path) -> io::Result<FileMeta> {
    let meta = fs::metadata(source)?;
    Ok(FileMeta {
        size: meta.len(),
        mtime_us: mtime_us(meta.modified()?),
        mode: mode_of(&meta),
    })
}

/// What `meta` says is at its path, as a precondition compares it (SPEC
/// §7.6): by the fast path's two facts, unless it is a folder. A fifo or a
/// device reads as a file here - no scan reports one, so no precondition
/// holds against it anyway.
pub(crate) fn on_disk(meta: &Metadata) -> OnDisk {
    match meta.modified() {
        Ok(modified) if !meta.is_dir() => OnDisk::File {
            size: meta.len(),
            mtime_us: mtime_us(modified),
        },
        _ => OnDisk::Unknown,
    }
}

/// What is at `path` now, through a followed link, as the scan would have
/// read it.
pub(crate) fn on_disk_at(path: &Path) -> OnDisk {
    match fs::metadata(path) {
        Ok(meta) => on_disk(&meta),
        Err(error) => on_disk_failing(&error),
    }
}

/// What a stat that failed with `error` says is at its path: nothing, when
/// the path or a folder on it is missing - or is a file.
pub(crate) fn on_disk_failing(error: &io::Error) -> OnDisk {
    match error.kind() {
        io::ErrorKind::NotFound | io::ErrorKind::NotADirectory => OnDisk::Absent,
        _ => OnDisk::Unknown,
    }
}

/// Microseconds since the epoch, negative before it (floored).
fn mtime_us(time: SystemTime) -> i64 {
    let micros = |d: std::time::Duration| i64::try_from(d.as_micros()).unwrap_or(i64::MAX);
    match time.duration_since(UNIX_EPOCH) {
        Ok(after) => micros(after),
        Err(before) => {
            let before = before.duration();
            let floored = micros(before) + i64::from(before.subsec_nanos() % 1_000 != 0);
            -floored
        }
    }
}

/// Permission, setuid, setgid and sticky bits; the file type bits are not
/// the file's to carry (SPEC §7.4).
#[cfg(unix)]
fn mode_of(meta: &Metadata) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    meta.permissions().mode() & 0o7777
}

/// Windows has only a read-only flag; it maps onto the unix bits a peer
/// would write.
#[cfg(not(unix))]
fn mode_of(meta: &Metadata) -> u32 {
    if meta.permissions().readonly() {
        0o444
    } else {
        0o644
    }
}

/// SHA-256 of the file's content, streamed through `buffer`: peak memory
/// is a buffer per worker, never a file.
fn hash_file(source: &Path, buffer: &mut [u8]) -> io::Result<ContentHash> {
    let mut file = File::open(source)?;
    let mut context = digest::Context::new(&digest::SHA256);
    loop {
        match file.read(buffer) {
            Ok(0) => break,
            Ok(read) => context.update(&buffer[..read]),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    let mut bytes = [0u8; 32];
    bytes.copy_from_slice(context.finish().as_ref());
    Ok(ContentHash::from_digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mtime_is_floored_to_the_microsecond_either_side_of_the_epoch() {
        let at = |nanos: i128| {
            if nanos >= 0 {
                UNIX_EPOCH + std::time::Duration::from_nanos(nanos as u64)
            } else {
                UNIX_EPOCH - std::time::Duration::from_nanos((-nanos) as u64)
            }
        };
        assert_eq!(mtime_us(at(1_500)), 1);
        assert_eq!(mtime_us(at(2_000)), 2);
        assert_eq!(mtime_us(at(-1_500)), -2);
        assert_eq!(mtime_us(at(-2_000)), -2);
    }

    #[test]
    fn the_hash_queue_is_largest_first_ties_in_walk_order() {
        let meta = |size| FileMeta {
            size,
            mtime_us: 0,
            mode: 0,
        };
        let path = Path::new("x");
        let mut queue = [
            (0, path, meta(1)),
            (1, path, meta(300)),
            (2, path, meta(20)),
            (3, path, meta(300)),
        ];
        largest_first(&mut queue);
        let order: Vec<usize> = queue.iter().map(|(index, _, _)| *index).collect();
        assert_eq!(order, [1, 3, 2, 0]);
    }

    #[test]
    fn the_os_error_suffix_is_dropped() {
        let error = io::Error::from_raw_os_error(2);
        assert!(
            !describe(&error).contains("os error"),
            "{}",
            describe(&error)
        );
        let custom = io::Error::other("plain words");
        assert_eq!(describe(&custom), "plain words");
    }
}
