//! The replica protocol's control messages (plan D5): what a request asks,
//! what a reply answers, and how a failure on the far side crosses the
//! wire. All postcard.
//!
//! Every path in a request is a [`RelPath`], decoded through
//! [`RelPath::parse`]: a request naming `../x` does not decode, so it is
//! refused before any replica sees it. Bucket counts and indices travel as
//! integers and are checked by whoever receives them
//! ([`dsync_domain::BucketCount::new`], [`dsync_domain::BucketCount::bucket`]).

use std::io;
use std::path::PathBuf;

use dsync_domain::{
    ArchiveCommit, ArchiveFacts, ChangedDuringSync, ChangedScan, FileMeta, Precondition, RelPath,
    ReplicaSpec, RootFacts, RuleSet, ScanEntry, Stage, WriteStats,
};
use serde::{Deserialize, Serialize};

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
    OpenScan(RuleSet),
    ScanDigests {
        count: u32,
        peer_changed: Vec<RelPath>,
    },
    ScanBuckets(Vec<u32>),
    /// Answered with [`Reply::Opened`], then the body's frames; its `End`
    /// carries what the file was once read ([`dsync_domain::OnDisk`]).
    Read(RelPath),
    /// Followed by the body's frames under the same id.
    Write {
        path: RelPath,
        meta: FileMeta,
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
    Scan(ChangedScan),
    Digests {
        digests: Vec<[u8; 32]>,
        owed: Vec<ScanEntry>,
    },
    Buckets(Vec<ScanEntry>),
    /// The file opened; its body follows under the same id.
    Opened,
    Written(FileMeta),
    /// The lock is released; with the served replica's writer stats, for
    /// the initiator's report (SPEC §17).
    Unlocked(Option<Box<WriteStats>>),
}

/// A reply frame's payload.
pub(crate) type Answer = Result<Reply, WireError>;

/// A far-side [`ReplicaError`] as it crosses the wire: enough to rebuild
/// the local shape wherever there is one, so a run treats a remote failure
/// exactly like the same local one - a held lock is still
/// [`LockError::Held`], a failed write still a [`WriteError`] with its
/// stage.
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

impl From<ReplicaError> for WireError {
    fn from(error: ReplicaError) -> WireError {
        match error {
            ReplicaError::Lock(LockError::Held { path }) => {
                WireError::LockHeld { path: shown(&path) }
            }
            ReplicaError::Lock(LockError::FolderInUse { folder, lock }) => WireError::FolderInUse {
                folder: shown(&folder),
                lock: shown(&lock),
            },
            ReplicaError::Lock(LockError::Io { path, source }) => WireError::Lock {
                path: shown(&path),
                io: WireIo::from(&source),
            },
            ReplicaError::Archive(error) => WireError::Archive(error.to_string()),
            ReplicaError::Scan(UnreadableRoot { root, source }) => WireError::Scan {
                root: shown(&root),
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
                path: shown(&path),
                io: WireIo::from(&source),
            },
            ReplicaError::NoScan => WireError::NoScan,
            ReplicaError::NotLocked => WireError::NotLocked,
            ReplicaError::Refused(message) => WireError::Refused(message),
            ReplicaError::Changed(ChangedDuringSync) => WireError::Changed,
            ReplicaError::RemoteArchive(message) => WireError::Archive(message),
            ReplicaError::Link(error) => WireError::Protocol(error.to_string()),
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
        ContentHash, EntryId, FileState, Glob, Jobs, ReplicaRoot, ScanTally, Side, SkippedPath,
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
            Request::ScanDigests {
                count: 3,
                peer_changed: vec![path("a/b")],
            },
            Request::ScanBuckets(vec![0, 2]),
            Request::Read(path("r")),
            Request::Write {
                path: path("w"),
                meta: file(1).meta,
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
    fn every_reply_round_trips_with_both_kinds_of_skipped_entry() {
        let changed = ChangedScan {
            entries: vec![
                ScanEntry::new(path("c"), Status::Created(file(1))),
                ScanEntry::new(path("m"), Status::Modified(file(2))),
                ScanEntry::new(path("d"), Status::Deleted),
            ],
            skipped: vec![
                SkippedPath::new(path("l"), SkippedReason::Symlink, "broken link"),
                SkippedPath::unrepresentable_name(Some(path("dir")), "a\\b", "backslash"),
                SkippedPath::unrepresentable_name(None, "C:", "drive"),
            ],
            tally: ScanTally {
                metadata_matched: 7,
                hash_matched: 1,
                modified: 1,
                created: 1,
                deleted: 1,
            },
        };
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
            Reply::Scan(changed),
            Reply::Digests {
                digests: vec![[9; 32], [0; 32]],
                owed: vec![ScanEntry::new(
                    path("o"),
                    Status::Unchanged {
                        file: file(4),
                        by: Unchanged::HashMatched,
                    },
                )],
            },
            Reply::Buckets(vec![ScanEntry::new(
                path("b"),
                Status::Unchanged {
                    file: file(5),
                    by: Unchanged::MetadataMatched,
                },
            )]),
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

    #[test]
    fn a_path_changed_during_sync_comes_back_as_changed() {
        let wire = WireError::from(ReplicaError::Changed(ChangedDuringSync));
        let back = ReplicaError::from(decode::<WireError>(&encode(&wire)).unwrap());
        assert!(matches!(back, ReplicaError::Changed(_)), "{back:?}");
    }

    #[test]
    fn a_folder_in_use_comes_back_naming_the_folder() {
        let wire = WireError::from(ReplicaError::Lock(LockError::FolderInUse {
            folder: PathBuf::from("/home/me/Docs"),
            lock: PathBuf::from("/state/folder-0123.lock"),
        }));
        let back = ReplicaError::from(decode::<WireError>(&encode(&wire)).unwrap());
        assert!(
            matches!(&back, ReplicaError::Lock(LockError::FolderInUse { folder, lock })
                if folder == &PathBuf::from("/home/me/Docs")
                    && lock == &PathBuf::from("/state/folder-0123.lock")),
            "{back:?}"
        );
    }

    #[test]
    fn an_unlocked_archive_comes_back_as_not_locked() {
        let wire = WireError::from(ReplicaError::NotLocked);
        let back = ReplicaError::from(decode::<WireError>(&encode(&wire)).unwrap());
        assert!(matches!(back, ReplicaError::NotLocked), "{back:?}");
    }

    #[test]
    fn a_held_lock_comes_back_as_held() {
        let wire = WireError::from(ReplicaError::Lock(LockError::Held {
            path: PathBuf::from("/state/p-a.lock"),
        }));
        let back = ReplicaError::from(decode::<WireError>(&encode(&wire)).unwrap());
        assert!(
            matches!(&back, ReplicaError::Lock(LockError::Held { path }) if path == &PathBuf::from("/state/p-a.lock")),
            "{back:?}"
        );
    }

    #[test]
    fn a_failed_write_keeps_its_path_stage_kind_and_message() {
        let wire = WireError::from(ReplicaError::Write(WriteError {
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
    fn a_file_error_keeps_its_op_path_and_kind() {
        let wire = WireError::from(ReplicaError::File {
            op: FileOp::Read,
            path: PathBuf::from("/r/missing"),
            source: io::Error::from(io::ErrorKind::NotFound),
        });
        let back = ReplicaError::from(wire);
        assert!(matches!(
            &back,
            ReplicaError::File { op: FileOp::Read, path, source }
                if path == &PathBuf::from("/r/missing") && source.kind() == io::ErrorKind::NotFound
        ));
        assert_eq!(back.to_string(), "reading /r/missing: entity not found");
    }

    #[test]
    fn an_unnamed_io_kind_crosses_as_other_with_its_message() {
        let error = io::Error::new(io::ErrorKind::WouldBlock, "try again");
        let back = io::Error::from(WireIo::from(&error));
        assert_eq!(back.kind(), io::ErrorKind::Other);
        assert_eq!(back.to_string(), "try again");
    }
}
