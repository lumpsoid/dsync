//! The per-replica archive as an append-only JSON Lines log (SPEC §8.1,
//! §8.2): a header line, then one line per commit - upsert, delete, intent
//! or withdraw - replayed with last write wins ([`Archive::apply`]).
//!
//! Durability, in the order it is paid for:
//! - Commits are buffered and appended in one write + fsync per batch:
//!   [`Tuning::archive_buffer_lines`] lines or
//!   [`Tuning::archive_buffer_interval`] of age, whichever comes first. A
//!   crash loses at most that batch, which SPEC §7.3 already converges on
//!   (the stale side rehashes those paths next run). The age is checked as
//!   each commit arrives, not by a timer: a timer would only ever fire when
//!   no more commits are coming, which is what [`ArchiveStore::flush`] and
//!   dropping the store are for.
//! - A batch holding an intent is written and fsynced before
//!   [`ArchiveStore::commit`] returns: the mark has to be on disk before the
//!   bytes it guards (SPEC §7.6).
//! - A batch goes out as one write, so a crash can tear the last line but
//!   not interleave two. Opening drops a torn last line and the next write
//!   repairs the file by compaction first; appending after the fragment
//!   would splice it into the next record and turn a tolerated tear into
//!   corruption mid-log. A last line that is whole but lost its newline is
//!   repaired the same way.
//! - Compaction rewrites the log to one line per live path through
//!   [`crate::atomic_write`] (temp, fsync, rename, directory fsync).
//!
//! The store is a plain `&mut self` API over `std::fs` (plan D3); callers
//! on the async side run it on a blocking thread and serialize access
//! (a `Mutex`), which replaces the Dart store's future chain.

use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use dsync_domain::{Archive, ArchiveCommit, ProfileId, Side, Tuning};

use crate::archive_line::Line;
use crate::atomic_write::{sync_dir, write_atomically};
use crate::state_dir::StateDir;

/// The on-disk line format's version. Bumped whenever the format changes.
///
/// 3, not 1: the Dart core's logs are schema 2 (and its schema 1 had no
/// header), so starting above both keeps "is this file ours" a plain
/// comparison and never accepts a Dart-era log.
pub const ARCHIVE_SCHEMA_VERSION: u64 = 3;

/// Read buffer for replaying a log: about one line per live path in steady
/// state, which is megabytes on a tree of any size.
const READ_BUFFER_BYTES: usize = 256 * 1024;

/// Which replica a log belongs to (SPEC §8.1). Checked against the log's
/// first line on open; anything else is fatal.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ArchiveHeader {
    pub profile_id: ProfileId,
    /// The replica root the entries are relative to.
    pub root_path: String,
}

/// What a log's first line turned out to be when it is not this build's
/// header.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ForeignHeader {
    /// A header of another schema version.
    Schema(u64),
    /// No header at all (a Dart schema 1 log starts straight in on
    /// commits), or a line that is not JSON.
    Missing,
}

impl std::fmt::Display for ForeignHeader {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ForeignHeader::Schema(version) => write!(f, "schema {version}"),
            ForeignHeader::Missing => f.write_str("no readable header"),
        }
    }
}

/// Why the archive cannot be used. All fatal for a run (SPEC §11.5 exit 3):
/// an archive of another tree lists every path as absent here, and a run
/// that went ahead would propagate the whole tree as deleted.
#[derive(Debug, thiserror::Error)]
pub enum ArchiveError {
    #[error("Archive {}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error(
        "Archive at {} was written by another dsync version ({found}; this build reads \
         schema {ARCHIVE_SCHEMA_VERSION}). Delete {} to start this replica's archive afresh.",
        path.display(),
        path.display()
    )]
    ForeignSchema { path: PathBuf, found: ForeignHeader },
    #[error(
        "Archive at {} belongs to a different replica: expected profile {} root {}, \
         found profile {found_profile} root {found_root}",
        path.display(),
        expected.profile_id.as_str(),
        expected.root_path
    )]
    Mismatch {
        path: PathBuf,
        expected: ArchiveHeader,
        found_profile: String,
        found_root: String,
    },
    #[error("Archive at {} is corrupt at line {line}: {reason}", path.display())]
    Corrupt {
        path: PathBuf,
        line: usize,
        reason: String,
    },
}

/// One replica's archive log, open.
///
/// Opening replays the log, so a store is never in a "not yet loaded"
/// state; [`ArchiveStore::archive`] is the archive as of every commit made,
/// written out or not. Dropping the store writes out what is buffered,
/// ignoring errors (as `BufWriter` does); call [`ArchiveStore::flush`] to
/// see them.
#[derive(Debug)]
pub struct ArchiveStore {
    log: PathBuf,
    header: ArchiveHeader,
    archive: Archive,
    batch_lines: usize,
    batch_age: Duration,
    /// Encoded commits not yet written, oldest first. Already applied to
    /// `archive`: only their survival of a crash waits on the disk.
    pending: Vec<u8>,
    pending_lines: usize,
    /// When the oldest pending commit was recorded.
    pending_since: Option<Instant>,
    /// Commit lines in the file, not counting the header; compared with
    /// [`Archive::compacted_len`] to tell whether compacting would change
    /// anything.
    log_lines: usize,
    /// The file ends in something appending must not follow: a torn line,
    /// a missing newline, or no header.
    needs_repair: bool,
    /// The file exists, with its header. Saves a stat per batch.
    log_exists: bool,
}

impl ArchiveStore {
    /// Opens the log of `side` of `profile` in `state`.
    pub fn open_replica(
        state: &StateDir,
        profile: &ProfileId,
        side: Side,
        root_path: String,
        tuning: &Tuning,
    ) -> Result<ArchiveStore, ArchiveError> {
        let header = ArchiveHeader {
            profile_id: profile.clone(),
            root_path,
        };
        ArchiveStore::open(state.archive_log(profile, side), header, tuning)
    }

    /// Opens the log at `log` and replays it. A missing log is an empty
    /// archive; nothing is created until the first commit is written, so a
    /// run that commits nothing (a dry run) leaves no file behind.
    pub fn open(
        log: PathBuf,
        header: ArchiveHeader,
        tuning: &Tuning,
    ) -> Result<ArchiveStore, ArchiveError> {
        let replayed = replay(&log, &header)?;
        Ok(ArchiveStore {
            log,
            header,
            archive: replayed.archive,
            batch_lines: tuning.archive_buffer_lines,
            batch_age: tuning.archive_buffer_interval,
            pending: Vec::new(),
            pending_lines: 0,
            pending_since: None,
            log_lines: replayed.lines,
            needs_repair: replayed.needs_repair,
            log_exists: replayed.exists,
        })
    }

    pub fn header(&self) -> &ArchiveHeader {
        &self.header
    }

    pub fn log_path(&self) -> &Path {
        &self.log
    }

    /// The archive as of every commit made through this store. Clone it to
    /// hold it across later commits.
    pub fn archive(&self) -> &Archive {
        &self.archive
    }

    /// Records `batch` in order. Visible in [`ArchiveStore::archive`] at
    /// once; durable once the batch is written - immediately if `batch`
    /// holds an intent, else when the buffer is full or old enough, or on
    /// [`ArchiveStore::flush`].
    pub fn commit(
        &mut self,
        batch: impl IntoIterator<Item = ArchiveCommit>,
    ) -> Result<(), ArchiveError> {
        let mut holds_intent = false;
        for commit in batch {
            holds_intent |= commit.is_intent();
            Line::of_commit(&commit).write_to(&mut self.pending);
            self.pending_lines += 1;
            self.pending_since.get_or_insert_with(Instant::now);
            self.archive.apply(commit);
        }
        let due = self.pending_lines >= self.batch_lines
            || self
                .pending_since
                .is_some_and(|since| since.elapsed() >= self.batch_age);
        if holds_intent || due {
            self.flush()?;
        }
        Ok(())
    }

    /// Makes every commit recorded so far durable (SPEC §7.3, §8.2).
    pub fn flush(&mut self) -> Result<(), ArchiveError> {
        if self.pending_lines == 0 {
            return Ok(());
        }
        if self.needs_repair {
            // The rewrite is made from `archive`, which already holds the
            // pending commits.
            return self.rewrite();
        }
        if let Err(source) = self.append() {
            // `append` may have already moved `pending` into its own write
            // buffer, or written part of it, before failing - either way the
            // log can no longer be trusted to grow cleanly by appending to
            // it. Force the next flush through `rewrite`, which rebuilds the
            // whole log from `archive` (already holding every pending
            // commit) instead of risking a dropped or torn line.
            self.needs_repair = true;
            return Err(self.io(source));
        }
        Ok(())
    }

    /// Folds the log down to one line per live path and mark (SPEC §8.2).
    /// A no-op when it already is that.
    pub fn compact(&mut self) -> Result<(), ArchiveError> {
        self.flush()?;
        if !self.needs_repair && self.log_lines == self.archive.compacted_len() {
            return Ok(());
        }
        self.rewrite()
    }

    /// When a commit last reached the log, or `None` if none ever has.
    /// Writes out the buffer first, so this answers about every commit
    /// made.
    pub fn last_commit(&mut self) -> Result<Option<SystemTime>, ArchiveError> {
        self.flush()?;
        match fs::metadata(&self.log) {
            Ok(metadata) => metadata.modified().map(Some),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
        .map_err(|source| self.io(source))
    }

    fn header_line(&self) -> Line {
        Line::Header {
            schema_version: ARCHIVE_SCHEMA_VERSION,
            profile_id: self.header.profile_id.as_str().to_owned(),
            root_path: self.header.root_path.clone(),
        }
    }

    fn append(&mut self) -> io::Result<()> {
        let mut created = false;
        let mut bytes = Vec::new();
        if !self.log_exists {
            if let Some(dir) = self.log.parent() {
                fs::create_dir_all(dir)?;
            }
            created = !self.log.try_exists()?;
            // The header is written by whoever creates the log, not by
            // opening it, so a run that never commits leaves no file.
            if created {
                self.header_line().write_to(&mut bytes);
            }
        }
        bytes.append(&mut self.pending);
        let mut file = OpenOptions::new()
            .append(true)
            .create(true)
            .open(&self.log)?;
        file.write_all(&bytes)?;
        file.sync_data()?;
        if created && let Some(dir) = self.log.parent() {
            sync_dir(dir)?;
        }
        self.log_exists = true;
        self.log_lines += self.pending_lines;
        self.clear_pending();
        Ok(())
    }

    fn rewrite(&mut self) -> Result<(), ArchiveError> {
        let mut bytes = Vec::new();
        self.header_line().write_to(&mut bytes);
        for commit in self.archive.compacted() {
            Line::of_commit(&commit).write_to(&mut bytes);
        }
        write_atomically(&self.log, &bytes).map_err(|source| self.io(source))?;
        self.log_lines = self.archive.compacted_len();
        self.needs_repair = false;
        self.log_exists = true;
        self.clear_pending();
        Ok(())
    }

    fn clear_pending(&mut self) {
        self.pending.clear();
        self.pending_lines = 0;
        self.pending_since = None;
    }

    fn io(&self, source: io::Error) -> ArchiveError {
        ArchiveError::Io {
            path: self.log.clone(),
            source,
        }
    }
}

impl Drop for ArchiveStore {
    fn drop(&mut self) {
        let _ = self.flush();
    }
}

/// What replaying a log found.
struct Replayed {
    archive: Archive,
    lines: usize,
    needs_repair: bool,
    exists: bool,
}

/// Reads `log` and replays it against `expected`.
///
/// Streamed a line at a time with one line of lookahead: only the last
/// line may be torn, and under a stream "last" is known only when the
/// next line arrives or the file ends. A line that is not the last and
/// does not parse is corruption, not a tear.
fn replay(log: &Path, expected: &ArchiveHeader) -> Result<Replayed, ArchiveError> {
    let io = |source| ArchiveError::Io {
        path: log.to_owned(),
        source,
    };
    let file = match File::open(log) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(Replayed {
                archive: Archive::default(),
                lines: 0,
                needs_repair: false,
                exists: false,
            });
        }
        Err(error) => return Err(io(error)),
    };
    let mut reader = BufReader::with_capacity(READ_BUFFER_BYTES, file);
    let mut archive = Archive::default();
    let mut lines = 0;
    let mut header_seen = false;
    // The line number and bytes (without the newline) of the last line.
    let mut held: Option<(usize, Vec<u8>)> = None;
    let mut tail_terminated = true;
    let mut buffer = Vec::new();
    let mut number = 0;
    loop {
        buffer.clear();
        if reader.read_until(b'\n', &mut buffer).map_err(io)? == 0 {
            break;
        }
        number += 1;
        let terminated = buffer.last() == Some(&b'\n');
        if terminated {
            buffer.pop();
        }
        if buffer.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        tail_terminated = terminated;
        if !header_seen {
            // A first line that is torn is a log whose first write was
            // cut short: nothing in it was ever durable, so it is empty
            // and repaired rather than refused.
            if !terminated && is_torn(&buffer) {
                break;
            }
            verify_header(log, &buffer, expected)?;
            header_seen = true;
            continue;
        }
        if let Some((at, line)) = held.take() {
            archive.apply(parse_commit(log, at, &line)?);
            lines += 1;
        }
        held = Some((number, std::mem::take(&mut buffer)));
    }
    let mut needs_repair = !header_seen || !tail_terminated;
    if let Some((at, line)) = held {
        match parse_commit(log, at, &line) {
            Ok(commit) => {
                archive.apply(commit);
                lines += 1;
            }
            // A crash partway through an append: dropped here, and
            // repaired before the next write.
            Err(_) if is_torn(&line) => needs_repair = true,
            Err(error) => return Err(error),
        }
    }
    Ok(Replayed {
        archive,
        lines,
        needs_repair,
        exists: header_seen,
    })
}

/// Whether `line` is the kind of damage a cut-short append leaves: not
/// JSON at all (a cut can leave a truncated UTF-8 sequence too), as
/// opposed to well-formed JSON of the wrong shape.
fn is_torn(line: &[u8]) -> bool {
    match serde_json::from_slice::<serde_json::Value>(line) {
        Ok(_) => false,
        Err(error) => error.is_eof() || error.is_syntax(),
    }
}

fn parse_commit(log: &Path, line: usize, bytes: &[u8]) -> Result<ArchiveCommit, ArchiveError> {
    let corrupt = |reason: String| ArchiveError::Corrupt {
        path: log.to_owned(),
        line,
        reason,
    };
    serde_json::from_slice::<Line>(bytes)
        .map_err(|error| corrupt(error.to_string()))?
        .into_commit()
        .map_err(corrupt)
}

/// Checks the log's first line names the replica this store is for, in
/// this build's schema.
fn verify_header(log: &Path, line: &[u8], expected: &ArchiveHeader) -> Result<(), ArchiveError> {
    let foreign = |found| ArchiveError::ForeignSchema {
        path: log.to_owned(),
        found,
    };
    let (profile_id, root_path) = match serde_json::from_slice::<Line>(line) {
        Ok(Line::Header {
            schema_version,
            profile_id,
            root_path,
        }) => {
            if schema_version != ARCHIVE_SCHEMA_VERSION {
                return Err(foreign(ForeignHeader::Schema(schema_version)));
            }
            (profile_id, root_path)
        }
        // A header of another shape still says which schema wrote it.
        _ => {
            return Err(foreign(
                schema_version_of(line).map_or(ForeignHeader::Missing, ForeignHeader::Schema),
            ));
        }
    };
    if profile_id != expected.profile_id.as_str() || root_path != expected.root_path {
        return Err(ArchiveError::Mismatch {
            path: log.to_owned(),
            expected: expected.clone(),
            found_profile: profile_id,
            found_root: root_path,
        });
    }
    Ok(())
}

fn schema_version_of(line: &[u8]) -> Option<u64> {
    let value: serde_json::Value = serde_json::from_slice(line).ok()?;
    if value.get("op")?.as_str()? != "header" {
        return None;
    }
    value.get("schemaVersion")?.as_u64()
}
