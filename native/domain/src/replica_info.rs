//! What a replica reports about itself in reply to `hello` (SPEC §4.2).

use std::time::SystemTime;

use crate::missing_parent_folder::MissingParentFolder;
use crate::root_kind::RootKind;
use crate::side::Side;
use crate::unusable_root::UnusableRoot;
use crate::wrong_root_kind::WrongRootKind;

/// Whether a replica's root is there to sync (SPEC §4.5). A single-file
/// root whose folder is there is `Present` with or without its file: an
/// absent file is a scan with nothing in it, which the archive reads as a
/// deletion or a first sync like any other path.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub enum ReplicaRoot {
    Present,
    /// A folder root that is missing, with the file count its archive
    /// holds, for the message.
    Missing {
        root_path: String,
        archived_files: u64,
    },
    /// A single-file root whose folder is missing.
    ParentMissing {
        root_path: String,
        folder: String,
    },
    /// Something other than the entry's kind is at the root: a folder at
    /// a single-file root, or anything but a folder at a folder root.
    WrongKind {
        root_path: String,
        expected: RootKind,
    },
}

/// A replica's `hello` reply.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct ReplicaInfo {
    /// When its archive last committed; `None` if it never has (SPEC §8.2).
    /// Reported by the replica because the initiator cannot stat an
    /// archive on a remote host.
    pub last_commit: Option<SystemTime>,
    /// Its resolved archive path, for the run header, when the replica
    /// knows it; only the far end knows where a remote archive lives.
    pub archive_path: Option<String>,
    pub root: ReplicaRoot,
}

/// A missing root on a replica with commit history: more likely an
/// unmounted drive or a deleted folder than a new one, and scanning it
/// would report every archived file deleted (SPEC §4.5).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{}", self.describe(None))]
pub struct MissingReplicaRoot {
    pub side: Side,
    pub root_path: String,
    pub archived_files: u64,
}

impl MissingReplicaRoot {
    /// The message, naming the device the folder is on when there is one.
    pub fn describe(&self, device: Option<&str>) -> String {
        let place = match device {
            Some(device) => format!("{} on {device}", self.root_path),
            None => self.root_path.clone(),
        };
        let files = if self.archived_files == 1 {
            "file"
        } else {
            "files"
        };
        format!(
            "The folder {place} is missing. If it is on a drive that is not mounted, \
             reconnect it; the last sync saw {} {files} there.",
            self.archived_files
        )
    }
}

impl ReplicaInfo {
    /// Refuses a root that is not the entry's kind, naming `side`. Judged
    /// before either replica is locked: nothing is taken or written for a
    /// root the run will not touch.
    pub fn wrong_kind(&self, side: Side) -> Option<WrongRootKind> {
        match &self.root {
            ReplicaRoot::WrongKind {
                root_path,
                expected,
            } => Some(WrongRootKind {
                side,
                root_path: root_path.clone(),
                expected: *expected,
            }),
            ReplicaRoot::Present
            | ReplicaRoot::Missing { .. }
            | ReplicaRoot::ParentMissing { .. } => None,
        }
    }

    /// Whether a run has to create this replica's root before scanning it:
    /// only a folder root, on its first sync, when no archive expects
    /// anything there. Once it has committed, a missing root is refused,
    /// naming `side`. A single-file root's missing folder is always
    /// refused: dsync never creates the folders above a file.
    pub fn must_create_root(&self, side: Side) -> Result<bool, UnusableRoot> {
        match (&self.root, self.last_commit) {
            (ReplicaRoot::Present, _) => Ok(false),
            (ReplicaRoot::Missing { .. }, None) => Ok(true),
            (
                ReplicaRoot::Missing {
                    root_path,
                    archived_files,
                },
                Some(_),
            ) => Err(UnusableRoot::Missing(MissingReplicaRoot {
                side,
                root_path: root_path.clone(),
                archived_files: *archived_files,
            })),
            (ReplicaRoot::ParentMissing { root_path, folder }, _) => {
                Err(UnusableRoot::ParentMissing(MissingParentFolder {
                    side,
                    root_path: root_path.clone(),
                    folder: folder.clone(),
                }))
            }
            (
                ReplicaRoot::WrongKind {
                    root_path,
                    expected,
                },
                _,
            ) => Err(UnusableRoot::WrongKind(WrongRootKind {
                side,
                root_path: root_path.clone(),
                expected: *expected,
            })),
        }
    }
}

#[cfg(test)]
mod tests {
    //! Every case of `test/dsync_core/models/replica_info_test.dart`.

    use std::time::Duration;

    use super::*;

    fn committed() -> Option<SystemTime> {
        Some(SystemTime::UNIX_EPOCH + Duration::from_secs(1_788_220_800))
    }

    fn info(last_commit: Option<SystemTime>, root: ReplicaRoot) -> ReplicaInfo {
        ReplicaInfo {
            last_commit,
            archive_path: None,
            root,
        }
    }

    #[test]
    fn a_present_root_needs_nothing_archive_or_not() {
        assert_eq!(
            info(None, ReplicaRoot::Present).must_create_root(Side::A),
            Ok(false)
        );
        assert_eq!(
            info(committed(), ReplicaRoot::Present).must_create_root(Side::A),
            Ok(false)
        );
    }

    #[test]
    fn a_missing_root_with_no_archive_is_created_on_its_first_sync() {
        let missing = ReplicaRoot::Missing {
            root_path: "/phone/synth".into(),
            archived_files: 0,
        };
        assert_eq!(info(None, missing).must_create_root(Side::B), Ok(true));
    }

    #[test]
    fn a_missing_root_with_an_archive_is_refused_naming_side_path_and_count() {
        let missing = ReplicaRoot::Missing {
            root_path: "/media/sd/notes".into(),
            archived_files: 42,
        };
        assert_eq!(
            info(committed(), missing).must_create_root(Side::B),
            Err(UnusableRoot::Missing(MissingReplicaRoot {
                side: Side::B,
                root_path: "/media/sd/notes".into(),
                archived_files: 42,
            }))
        );
    }

    #[test]
    fn a_missing_parent_folder_is_refused_first_sync_or_not() {
        let parent_missing = ReplicaRoot::ParentMissing {
            root_path: "/media/sd/notes.md".into(),
            folder: "/media/sd".into(),
        };
        let refused = Err(UnusableRoot::ParentMissing(MissingParentFolder {
            side: Side::A,
            root_path: "/media/sd/notes.md".into(),
            folder: "/media/sd".into(),
        }));
        assert_eq!(
            info(None, parent_missing.clone()).must_create_root(Side::A),
            refused
        );
        assert_eq!(
            info(committed(), parent_missing.clone()).must_create_root(Side::A),
            refused
        );
        assert_eq!(info(None, parent_missing).wrong_kind(Side::A), None);
    }

    #[test]
    fn a_root_of_the_wrong_kind_is_refused_and_never_created() {
        let wrong = ReplicaRoot::WrongKind {
            root_path: "/x/notes.md".into(),
            expected: RootKind::File,
        };
        let expected = WrongRootKind {
            side: Side::B,
            root_path: "/x/notes.md".into(),
            expected: RootKind::File,
        };
        assert_eq!(
            info(None, wrong.clone()).wrong_kind(Side::B),
            Some(expected.clone())
        );
        assert_eq!(
            info(None, wrong).must_create_root(Side::B),
            Err(UnusableRoot::WrongKind(expected))
        );
        // Positive control: a present root is of its kind.
        assert_eq!(info(None, ReplicaRoot::Present).wrong_kind(Side::B), None);
    }

    fn missing(archived_files: u64) -> MissingReplicaRoot {
        MissingReplicaRoot {
            side: Side::B,
            root_path: "/media/sd/notes".into(),
            archived_files,
        }
    }

    #[test]
    fn the_message_names_the_device_it_is_on() {
        assert_eq!(
            missing(42).describe(Some("phone")),
            "The folder /media/sd/notes on phone is missing. If it is on a drive that is \
             not mounted, reconnect it; the last sync saw 42 files there."
        );
    }

    #[test]
    fn the_message_is_plain_text() {
        assert_eq!(
            missing(42).to_string(),
            "The folder /media/sd/notes is missing. If it is on a drive that is not \
             mounted, reconnect it; the last sync saw 42 files there."
        );
        assert!(missing(1).to_string().ends_with("saw 1 file there."));
    }
}
