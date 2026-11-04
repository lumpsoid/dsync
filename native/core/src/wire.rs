//! The replica protocol's control messages (plan D5): what a request asks,
//! what a reply answers, and how a failure on the far side crosses the
//! wire. All postcard. A scan phase's listing is not in its message but
//! follows it as a body of items ([`crate::listing`]): [`ScanItem`],
//! [`DigestItem`], [`ScanEntry`], [`RelPath`] or a bucket index.
//!
//! Every path in a request is a [`RelPath`], decoded through
//! [`RelPath::parse`]: a request naming `../x` does not decode, so it is
//! refused before any replica sees it. Bucket counts and indices travel as
//! integers and are checked by whoever receives them
//! ([`dsync_domain::BucketCount::new`], [`dsync_domain::BucketCount::bucket`]).

use std::io;
use std::path::{Path, PathBuf};

use dsync_domain::{
    ArchiveCommit, ArchiveFacts, ChangedDuringSync, FileMeta, FileState, Naming, Precondition,
    RelPath, ReplicaSpec, RootFacts, RootKind, RuleSet, ScanEntry, ScanTally, SkippedPath, Stage,
    WriteStats,
};
use serde::{Deserialize, Serialize};

use crate::archive_store::ArchiveError;
use crate::replica_error::{FileOp, ReplicaError};
use crate::replica_lock::LockError;
use crate::scanner::UnreadableRoot;
use crate::write_error::WriteError;

/// One operation of the `Replica` contract, as asked of the far side.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub(crate) enum Request {
    /// The prologue: which replica to serve, and its state.
    Hello(ReplicaSpec),
    Lock,
    Unlock,
    CreateRoot,
    /// Answered with [`Reply::Scan`], then its listing.
    OpenScan(RuleSet),
    /// Followed by the listing of the other side's changed paths;
    /// answered with [`Reply::Digests`], then its listing.
    ScanDigests {
        count: u32,
    },
    /// Followed by the listing of the bucket indices; answered with
    /// [`Reply::Buckets`], then its listing.
    ScanBuckets,
    /// Answered with [`Reply::Opened`], then the body's frames; its `End`
    /// carries what the file was once read ([`dsync_domain::OnDisk`]).
    Read(RelPath),
    /// Followed by the body's frames under the same id. `source` carries
    /// the hash the far writer checks the landed bytes against.
    Write {
        path: RelPath,
        source: FileState,
        expect: Precondition,
    },
    Delete {
        path: RelPath,
        expect: Precondition,
    },
    RemoveEmptyDirs(RelPath),
    Commit(Vec<ArchiveCommit>),
    Compact,
}

/// A successful answer; which one follows from the request.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub(crate) enum Reply {
    Hello(RootFacts),
    /// The lock is taken; with the archive as its one replay read it.
    Locked(ArchiveFacts),
    Done,
    /// Phase 1's whole-scan facts; its [`ScanItem`]s follow.
    Scan {
        tally: ScanTally,
        naming: Naming,
    },
    /// Phase 2's [`DigestItem`]s follow.
    Digests,
    /// Phase 3's entries follow.
    Buckets,
    /// The file opened; its body follows under the same id.
    Opened,
    Written(FileMeta),
    /// The lock is released; with the served replica's writer stats, for
    /// the initiator's report (SPEC §17).
    Unlocked(Option<Box<WriteStats>>),
}

impl Request {
    /// Whether a body follows this request under its id.
    pub(crate) fn has_body(&self) -> bool {
        matches!(
            self,
            Request::Write { .. } | Request::ScanDigests { .. } | Request::ScanBuckets
        )
    }
}

/// One item of phase 1's listing: an entry that is not unchanged, or a
/// skipped path.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub(crate) enum ScanItem {
    Entry(ScanEntry),
    Skipped(SkippedPath),
}

/// One item of phase 2's listing: a bucket's digest, in bucket order, or
/// an entry owed for a path the other side changed.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub(crate) enum DigestItem {
    Digest([u8; 32]),
    Owed(ScanEntry),
}

/// A reply frame's payload.
pub(crate) type Answer = Result<Reply, WireError>;

/// A far-side [`ReplicaError`] as it crosses the wire: enough to rebuild
/// the local shape wherever there is one, so a run treats a remote failure
/// exactly like the same local one - a held lock is still
/// [`LockError::Held`], a failed write still a [`WriteError`] with its
/// stage. Its paths are as [`Shown`] shows them, never this host's own.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub(crate) enum WireError {
    LockHeld {
        path: String,
    },
    FolderInUse {
        folder: String,
        lock: String,
    },
    Lock {
        path: String,
        io: WireIo,
    },
    Archive(String),
    Scan {
        root: String,
        io: WireIo,
    },
    Write {
        path: RelPath,
        stage: Stage,
        io: WireIo,
    },
    File {
        op: FileOp,
        path: String,
        io: WireIo,
    },
    NoScan,
    NotLocked,
    Refused(String),
    Changed,
    /// The far side could not make sense of a request (a path that is not
    /// a [`RelPath`], a bucket out of range), or its own link failed.
    Protocol(String),
    Halted(String),
    RootInUse {
        lock: String,
        owner: String,
    },
}

/// An `io::Error` as it crosses the wire: its kind, where it has a name,
/// and its message.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub(crate) struct WireIo {
    kind: IoKind,
    message: String,
}

pub(crate) fn encode<T: Serialize>(message: &T) -> Vec<u8> {
    postcard::to_stdvec(message).expect("protocol messages always serialize")
}

pub(crate) fn decode<'a, T: Deserialize<'a>>(payload: &'a [u8]) -> Result<T, postcard::Error> {
    postcard::from_bytes(payload)
}

impl WireError {
    /// `error` as it is sent to the far side, its paths as `shown` shows
    /// them.
    pub(crate) fn sent(error: ReplicaError, shown: &Shown) -> WireError {
        match error {
            ReplicaError::Lock(LockError::Held { path }) => WireError::LockHeld {
                path: shown.path(&path),
            },
            ReplicaError::Lock(LockError::FolderInUse { lock, .. }) => WireError::FolderInUse {
                folder: shown.named.clone(),
                lock: shown.path(&lock),
            },
            ReplicaError::Lock(LockError::RootInUse { lock, owner }) => WireError::RootInUse {
                lock: shown.path(&lock),
                owner,
            },
            ReplicaError::Lock(LockError::Io { path, source }) => WireError::Lock {
                path: shown.path(&path),
                io: WireIo::from(&source),
            },
            ReplicaError::Archive(error) => WireError::Archive(shown.archive(&error)),
            ReplicaError::Scan(UnreadableRoot { source, .. }) => WireError::Scan {
                root: shown.named.clone(),
                io: WireIo::from(&source),
            },
            ReplicaError::Write(WriteError {
                path,
                stage,
                source,
            }) => WireError::Write {
                path,
                stage,
                io: WireIo::from(&source),
            },
            ReplicaError::File { op, path, source } => WireError::File {
                op,
                path: shown.path(&path),
                io: WireIo::from(&source),
            },
            ReplicaError::NoScan => WireError::NoScan,
            ReplicaError::NotLocked => WireError::NotLocked,
            ReplicaError::Refused(message) => WireError::Refused(message),
            ReplicaError::Changed(ChangedDuringSync) => WireError::Changed,
            ReplicaError::RemoteArchive(message) => WireError::Archive(message),
            ReplicaError::Link(error) => WireError::Protocol(error.to_string()),
            ReplicaError::Halted(message) => WireError::Halted(message),
        }
    }
}

/// How a served replica's paths are shown to the far side, which is not
/// told this host's filesystem (SPEC §4.4): one under the replica's base
/// in the words the far side named its root with, any other - a lock or
/// an archive in the state directory - by its file name alone.
pub(crate) struct Shown {
    /// `None` until the replica is open.
    base: Option<PathBuf>,
    /// The base as the far side named it.
    named: String,
}

impl Shown {
    /// Before `spec`'s replica is open, when no path is known to be
    /// under it.
    pub(crate) fn unopened(spec: &ReplicaSpec) -> Shown {
        let root = Path::new(&spec.root);
        let named = match spec.kind {
            RootKind::Folder => root,
            RootKind::File => root.parent().unwrap_or(root),
        };
        Shown {
            base: None,
            named: shown(named),
        }
    }

    /// `spec`'s replica, open with its paths under `base`.
    pub(crate) fn open(spec: &ReplicaSpec, base: &Path) -> Shown {
        Shown {
            base: Some(base.to_path_buf()),
            ..Shown::unopened(spec)
        }
    }

    fn path(&self, path: &Path) -> String {
        if path.is_relative() {
            return shown(&Path::new(&self.named).join(path));
        }
        match self.base.as_deref().map(|base| path.strip_prefix(base)) {
            Some(Ok(under)) if under.as_os_str().is_empty() => self.named.clone(),
            Some(Ok(under)) => shown(&Path::new(&self.named).join(under)),
            _ => path
                .file_name()
                .map_or_else(String::new, |name| name.to_string_lossy().into_owned()),
        }
    }

    /// An archive failure's words, its file by name and the root as the
    /// far side named it.
    fn archive(&self, error: &ArchiveError) -> String {
        let message = error
            .to_string()
            .replace(&shown(error.path()), &self.path(error.path()));
        match &self.base {
            Some(base) => message.replace(&shown(base), &self.named),
            None => message,
        }
    }
}

impl From<WireError> for ReplicaError {
    fn from(error: WireError) -> ReplicaError {
        match error {
            WireError::LockHeld { path } => ReplicaError::Lock(LockError::Held {
                path: PathBuf::from(path),
            }),
            WireError::FolderInUse { folder, lock } => ReplicaError::Lock(LockError::FolderInUse {
                folder: PathBuf::from(folder),
                lock: PathBuf::from(lock),
            }),
            WireError::RootInUse { lock, owner } => ReplicaError::Lock(LockError::RootInUse {
                lock: PathBuf::from(lock),
                owner,
            }),
            WireError::Lock { path, io } => ReplicaError::Lock(LockError::Io {
                path: PathBuf::from(path),
                source: io.into(),
            }),
            WireError::Archive(message) => ReplicaError::RemoteArchive(message),
            WireError::Scan { root, io } => ReplicaError::Scan(UnreadableRoot {
                root: PathBuf::from(root),
                source: io.into(),
            }),
            WireError::Write { path, stage, io } => ReplicaError::Write(WriteError {
                path,
                stage,
                source: io.into(),
            }),
            WireError::File { op, path, io } => ReplicaError::File {
                op,
                path: PathBuf::from(path),
                source: io.into(),
            },
            WireError::NoScan => ReplicaError::NoScan,
            WireError::NotLocked => ReplicaError::NotLocked,
            WireError::Refused(message) => ReplicaError::Refused(message),
            WireError::Changed => ReplicaError::Changed(ChangedDuringSync),
            WireError::Protocol(message) => ReplicaError::Link(
                crate::link_error::LinkError::Protocol(format!("the far side: {message}")),
            ),
            WireError::Halted(message) => ReplicaError::Halted(message),
        }
    }
}

fn shown(path: &std::path::Path) -> String {
    path.display().to_string()
}

impl From<&io::Error> for WireIo {
    fn from(error: &io::Error) -> WireIo {
        WireIo {
            kind: IoKind::of(error.kind()),
            message: error.to_string(),
        }
    }
}

impl From<WireIo> for io::Error {
    fn from(error: WireIo) -> io::Error {
        io::Error::new(error.kind.kind(), error.message)
    }
}

/// The `io::ErrorKind`s a run or a reader can act on, by name. Any other
/// crosses as [`IoKind::Other`], its message intact.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
enum IoKind {
    NotFound,
    PermissionDenied,
    AlreadyExists,
    InvalidInput,
    InvalidData,
    TimedOut,
    Interrupted,
    Unsupported,
    UnexpectedEof,
    OutOfMemory,
    StorageFull,
    QuotaExceeded,
    ReadOnlyFilesystem,
    IsADirectory,
    NotADirectory,
    DirectoryNotEmpty,
    FileTooLarge,
    InvalidFilename,
    CrossesDevices,
    ResourceBusy,
    StaleNetworkFileHandle,
    Other,
}

impl IoKind {
    const NAMED: [(IoKind, io::ErrorKind); 21] = [
        (IoKind::NotFound, io::ErrorKind::NotFound),
        (IoKind::PermissionDenied, io::ErrorKind::PermissionDenied),
        (IoKind::AlreadyExists, io::ErrorKind::AlreadyExists),
        (IoKind::InvalidInput, io::ErrorKind::InvalidInput),
        (IoKind::InvalidData, io::ErrorKind::InvalidData),
        (IoKind::TimedOut, io::ErrorKind::TimedOut),
        (IoKind::Interrupted, io::ErrorKind::Interrupted),
        (IoKind::Unsupported, io::ErrorKind::Unsupported),
        (IoKind::UnexpectedEof, io::ErrorKind::UnexpectedEof),
        (IoKind::OutOfMemory, io::ErrorKind::OutOfMemory),
        (IoKind::StorageFull, io::ErrorKind::StorageFull),
        (IoKind::QuotaExceeded, io::ErrorKind::QuotaExceeded),
        (
            IoKind::ReadOnlyFilesystem,
            io::ErrorKind::ReadOnlyFilesystem,
        ),
        (IoKind::IsADirectory, io::ErrorKind::IsADirectory),
        (IoKind::NotADirectory, io::ErrorKind::NotADirectory),
        (IoKind::DirectoryNotEmpty, io::ErrorKind::DirectoryNotEmpty),
        (IoKind::FileTooLarge, io::ErrorKind::FileTooLarge),
        (IoKind::InvalidFilename, io::ErrorKind::InvalidFilename),
        (IoKind::CrossesDevices, io::ErrorKind::CrossesDevices),
        (IoKind::ResourceBusy, io::ErrorKind::ResourceBusy),
        (
            IoKind::StaleNetworkFileHandle,
            io::ErrorKind::StaleNetworkFileHandle,
        ),
    ];

    fn of(kind: io::ErrorKind) -> IoKind {
        IoKind::NAMED
            .iter()
            .find(|(_, named)| *named == kind)
            .map_or(IoKind::Other, |(wire, _)| *wire)
    }

    fn kind(self) -> io::ErrorKind {
        IoKind::NAMED
            .iter()
            .find(|(wire, _)| *wire == self)
            .map_or(io::ErrorKind::Other, |(_, kind)| *kind)
    }
}

impl WireIo {
    /// A body failure to send in a `Fail` frame.
    pub(crate) fn encode_failure(error: &io::Error) -> Vec<u8> {
        encode(&WireIo::from(error))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dsync_domain::{
        CaseFolding, ContentHash, EntryId, FileState, Glob, Jobs, Platform, ReplicaRoot, Side,
        SkippedReason, Status, Unchanged,
    };
    use std::time::{Duration, UNIX_EPOCH};

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap()
    }

    fn round_trip<T: Serialize + for<'a> Deserialize<'a> + PartialEq + std::fmt::Debug>(value: T) {
        let bytes = encode(&value);
        assert_eq!(decode::<T>(&bytes).unwrap(), value);
    }

    fn file(n: u8) -> FileState {
        FileState {
            meta: FileMeta {
                size: 3,
                mtime_us: -5,
                mode: 0o644,
                read_us: 9,
            },
            hash: ContentHash::from_digest([n; 32]),
        }
    }

    #[test]
    fn every_request_round_trips() {
        let rules = RuleSet::new(
            vec![Glob::new("**/.git").unwrap()],
            vec![Glob::new("link*").unwrap()],
        );
        for request in [
            Request::Hello(ReplicaSpec {
                root: "~/sync".into(),
                kind: dsync_domain::RootKind::Folder,
                as_path: None,
                entry: EntryId::parse("0123456789abcdef0123456789abcdef").unwrap(),
                side: Side::B,
                jobs: Jobs::new(8).unwrap(),
            }),
            Request::Lock,
            Request::Unlock,
            Request::CreateRoot,
            Request::OpenScan(rules),
            Request::ScanDigests { count: 3 },
            Request::ScanBuckets,
            Request::Read(path("r")),
            Request::Write {
                path: path("w"),
                source: file(1),
                expect: Precondition::Absent,
            },
            Request::Delete {
                path: path("d"),
                expect: Precondition::File {
                    size: 3,
                    mtime_us: -5,
                },
            },
            Request::RemoveEmptyDirs(path("e/f")),
            Request::Commit(vec![
                ArchiveCommit::Upsert {
                    path: path("u"),
                    file: file(2),
                },
                ArchiveCommit::Delete(path("x")),
            ]),
            Request::Compact,
        ] {
            round_trip(request);
        }
    }

    #[test]
    fn every_listing_item_round_trips_with_both_kinds_of_skipped_entry() {
        for item in [
            ScanItem::Entry(ScanEntry::new(path("c"), Status::Created(file(1)))),
            ScanItem::Entry(ScanEntry::new(path("m"), Status::Modified(file(2)))),
            ScanItem::Entry(ScanEntry::new(path("d"), Status::Deleted)),
            ScanItem::Skipped(SkippedPath::new(
                path("l"),
                SkippedReason::Symlink,
                "broken link",
            )),
            ScanItem::Skipped(SkippedPath::unrepresentable_name(
                Some(path("dir")),
                "a\\b",
                "backslash",
            )),
            ScanItem::Skipped(SkippedPath::unrepresentable_name(None, "C:", "drive")),
        ] {
            round_trip(item);
        }
        for item in [
            DigestItem::Digest([9; 32]),
            DigestItem::Owed(ScanEntry::new(
                path("o"),
                Status::Unchanged {
                    file: file(4),
                    by: Unchanged::HashMatched,
                },
            )),
        ] {
            round_trip(item);
        }
    }

    #[test]
    fn every_reply_round_trips() {
        for reply in [
            Reply::Hello(RootFacts {
                archive_path: Some("/state/x-a.jsonl".into()),
                root: ReplicaRoot::Missing {
                    root_path: "/gone".into(),
                },
            }),
            Reply::Hello(RootFacts {
                archive_path: None,
                root: ReplicaRoot::Present,
            }),
            Reply::Locked(ArchiveFacts {
                last_commit: Some(UNIX_EPOCH + Duration::from_micros(1_700_000_000_123_456)),
                archived_files: 4,
            }),
            Reply::Locked(ArchiveFacts {
                last_commit: None,
                archived_files: 0,
            }),
            Reply::Done,
            Reply::Scan {
                tally: ScanTally {
                    metadata_matched: 7,
                    hash_matched: 1,
                    modified: 1,
                    created: 1,
                    deleted: 1,
                },
                naming: Naming {
                    folding: CaseFolding::Folds,
                    platform: Platform::Windows,
                },
            },
            Reply::Digests,
            Reply::Buckets,
            Reply::Opened,
            Reply::Written(file(6).meta),
            Reply::Unlocked(None),
            Reply::Unlocked(Some(Box::new(WriteStats::one_writer()))),
        ] {
            round_trip::<Answer>(Ok(reply));
        }
    }

    #[test]
    fn a_path_that_is_not_a_rel_path_does_not_decode() {
        // Same length as "../x", so only the path's bytes differ.
        let delete = Request::Delete {
            path: path("ab/x"),
            expect: Precondition::Absent,
        };
        let bytes = encode(&delete);
        let tampered = replace(&bytes, b"ab/x", b"../x");
        assert!(decode::<Request>(&tampered).is_err());
        // The positive control: the untampered bytes decode.
        assert_eq!(decode::<Request>(&bytes).unwrap(), delete);
    }

    #[test]
    fn a_rule_that_is_not_a_glob_does_not_decode() {
        let bytes = encode(&Request::OpenScan(RuleSet::new(
            vec![Glob::new("[ab]").unwrap()],
            vec![],
        )));
        let tampered = replace(&bytes, b"[ab]", b"[ab ");
        assert!(Glob::new("[ab ").is_err());
        assert!(decode::<Request>(&tampered).is_err());
    }

    fn replace(bytes: &[u8], from: &[u8], to: &[u8]) -> Vec<u8> {
        let at = bytes
            .windows(from.len())
            .position(|window| window == from)
            .unwrap();
        let mut out = bytes.to_vec();
        out[at..at + to.len()].copy_from_slice(to);
        out
    }

    fn spec(root: &str, kind: RootKind) -> ReplicaSpec {
        ReplicaSpec {
            root: root.into(),
            kind,
            as_path: None,
            entry: EntryId::parse("0123456789abcdef0123456789abcdef").unwrap(),
            side: Side::B,
            jobs: Jobs::new(8).unwrap(),
        }
    }

    /// `error` as a replica at `/home/me/Docs`, asked for as `~/Docs`,
    /// sends it.
    fn sent(error: ReplicaError) -> WireError {
        let spec = spec("~/Docs", RootKind::Folder);
        WireError::sent(error, &Shown::open(&spec, Path::new("/home/me/Docs")))
    }

    #[test]
    fn a_path_changed_during_sync_comes_back_as_changed() {
        let wire = sent(ReplicaError::Changed(ChangedDuringSync));
        let back = ReplicaError::from(decode::<WireError>(&encode(&wire)).unwrap());
        assert!(matches!(back, ReplicaError::Changed(_)), "{back:?}");
    }

    #[test]
    fn a_folder_in_use_comes_back_naming_the_folder_as_it_was_asked_for() {
        let wire = sent(ReplicaError::Lock(LockError::FolderInUse {
            folder: PathBuf::from("/home/me/Docs"),
            lock: PathBuf::from("/state/folder-0123.lock"),
        }));
        let back = ReplicaError::from(decode::<WireError>(&encode(&wire)).unwrap());
        assert!(
            matches!(&back, ReplicaError::Lock(LockError::FolderInUse { folder, lock })
                if folder == &PathBuf::from("~/Docs")
                    && lock == &PathBuf::from("folder-0123.lock")),
            "{back:?}"
        );
    }

    #[test]
    fn a_root_in_use_comes_back_naming_its_owner() {
        let wire = sent(ReplicaError::Lock(LockError::RootInUse {
            lock: PathBuf::from("/home/me/Docs/.dsync-lock"),
            owner: "pid 7 on host phone".to_owned(),
        }));
        let back = ReplicaError::from(decode::<WireError>(&encode(&wire)).unwrap());
        assert!(
            matches!(&back, ReplicaError::Lock(LockError::RootInUse { lock, owner })
                if lock == &PathBuf::from("~/Docs/.dsync-lock")
                    && owner == "pid 7 on host phone"),
            "{back:?}"
        );
    }

    #[test]
    fn an_unlocked_archive_comes_back_as_not_locked() {
        let wire = sent(ReplicaError::NotLocked);
        let back = ReplicaError::from(decode::<WireError>(&encode(&wire)).unwrap());
        assert!(matches!(back, ReplicaError::NotLocked), "{back:?}");
    }

    #[test]
    fn a_halted_replica_comes_back_halted_and_ends_the_run() {
        let wire = sent(ReplicaError::Halted("no writer thread".into()));
        let back = ReplicaError::from(decode::<WireError>(&encode(&wire)).unwrap());
        assert!(
            matches!(&back, ReplicaError::Halted(why) if why == "no writer thread"),
            "{back:?}"
        );
        assert!(back.ends_run());
    }

    #[test]
    fn a_held_lock_comes_back_as_held_naming_only_its_file() {
        let wire = sent(ReplicaError::Lock(LockError::Held {
            path: PathBuf::from("/state/p-a.lock"),
        }));
        let back = ReplicaError::from(decode::<WireError>(&encode(&wire)).unwrap());
        assert!(
            matches!(&back, ReplicaError::Lock(LockError::Held { path }) if path == &PathBuf::from("p-a.lock")),
            "{back:?}"
        );
    }

    #[test]
    fn a_failed_write_keeps_its_path_stage_kind_and_message() {
        let wire = sent(ReplicaError::Write(WriteError {
            path: path("a/b"),
            stage: Stage::Create,
            source: io::Error::from(io::ErrorKind::PermissionDenied),
        }));
        let ReplicaError::Write(back) =
            ReplicaError::from(decode::<WireError>(&encode(&wire)).unwrap())
        else {
            panic!("not a write error");
        };
        assert_eq!(back.path, path("a/b"));
        assert_eq!(back.stage, Stage::Create);
        assert_eq!(back.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(back.source.to_string(), "permission denied");
    }

    #[test]
    fn a_file_error_keeps_its_op_kind_and_path_under_the_root_as_asked_for() {
        let wire = sent(ReplicaError::File {
            op: FileOp::Read,
            path: PathBuf::from("/home/me/Docs/a/missing"),
            source: io::Error::from(io::ErrorKind::NotFound),
        });
        let back = ReplicaError::from(wire);
        assert!(matches!(
            &back,
            ReplicaError::File { op: FileOp::Read, path, source }
                if path == &PathBuf::from("~/Docs/a/missing")
                    && source.kind() == io::ErrorKind::NotFound
        ));
        assert_eq!(
            back.to_string(),
            "reading ~/Docs/a/missing: entity not found"
        );
    }

    #[test]
    fn a_file_error_on_a_relative_path_or_the_root_itself_names_the_root_as_asked_for() {
        let failed = |path: &str| {
            let error = ReplicaError::File {
                op: FileOp::CreateRoot,
                path: PathBuf::from(path),
                source: io::Error::from(io::ErrorKind::PermissionDenied),
            };
            match sent(error) {
                WireError::File { path, .. } => path,
                other => panic!("{other:?}"),
            }
        };
        assert_eq!(failed("/home/me/Docs"), "~/Docs");
        assert_eq!(failed("a/b"), "~/Docs/a/b");
        // Outside the root, only the file's name crosses.
        assert_eq!(failed("/home/me/Other/c"), "c");
    }

    #[test]
    fn a_file_root_is_shown_under_the_folder_it_was_asked_for_in() {
        let spec = spec("~/notes/todo.md", RootKind::File);
        let shown = Shown::open(&spec, Path::new("/home/me/notes"));
        let error = ReplicaError::Lock(LockError::RootInUse {
            lock: PathBuf::from("/home/me/notes/.dsync-lock"),
            owner: "pid 7".to_owned(),
        });
        assert!(
            matches!(WireError::sent(error, &shown), WireError::RootInUse { lock, .. }
                if lock == "~/notes/.dsync-lock")
        );
    }

    #[test]
    fn before_the_replica_opens_an_absolute_path_crosses_by_name_alone() {
        let shown = Shown::unopened(&spec("~/Docs", RootKind::Folder));
        let error = ReplicaError::Lock(LockError::Io {
            path: PathBuf::from("/home/me/Docs/.dsync-lock"),
            source: io::Error::from(io::ErrorKind::PermissionDenied),
        });
        assert!(
            matches!(WireError::sent(error, &shown), WireError::Lock { path, .. }
                if path == ".dsync-lock")
        );
    }

    #[test]
    fn an_unreadable_root_comes_back_naming_the_root_as_asked_for() {
        let wire = sent(ReplicaError::Scan(UnreadableRoot {
            root: PathBuf::from("/home/me/Docs"),
            source: io::Error::from(io::ErrorKind::PermissionDenied),
        }));
        assert!(
            matches!(&wire, WireError::Scan { root, .. } if root == "~/Docs"),
            "{wire:?}"
        );
    }

    #[test]
    fn an_archive_failure_names_its_file_and_the_root_as_asked_for() {
        let wire = sent(ReplicaError::Archive(ArchiveError::Corrupt {
            path: PathBuf::from("/home/me/.local/state/dsync/p-b.jsonl"),
            line: 3,
            reason: "under /home/me/Docs/x".into(),
        }));
        let WireError::Archive(message) = wire else {
            panic!("{wire:?}");
        };
        assert_eq!(
            message,
            "Archive at p-b.jsonl is corrupt at line 3: under ~/Docs/x"
        );
    }

    #[test]
    fn an_unnamed_io_kind_crosses_as_other_with_its_message() {
        let error = io::Error::new(io::ErrorKind::WouldBlock, "try again");
        let back = io::Error::from(WireIo::from(&error));
        assert_eq!(back.kind(), io::ErrorKind::Other);
        assert_eq!(back.to_string(), "try again");
    }
}
