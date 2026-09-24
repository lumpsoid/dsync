//! What a replica reports about itself in reply to `hello` (SPEC §4.2).

use std::time::SystemTime;

use crate::side::Side;

/// Whether a replica's root folder exists (SPEC §4.5).
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ReplicaRoot {
    Present,
    /// Missing, with the file count its archive holds, for the message.
    Missing {
        root_path: String,
        archived_files: u64,
    },
}

/// A replica's `hello` reply.
#[derive(Clone, PartialEq, Eq, Debug)]
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
    /// Whether a run has to create this replica's root before scanning it:
    /// only on its first sync, when no archive expects anything there.
    /// Once it has committed, a missing root is refused, naming `side`.
    pub fn must_create_root(&self, side: Side) -> Result<bool, MissingReplicaRoot> {
        match (&self.root, self.last_commit) {
            (ReplicaRoot::Present, _) => Ok(false),
            (ReplicaRoot::Missing { .. }, None) => Ok(true),
            (
                ReplicaRoot::Missing {
                    root_path,
                    archived_files,
                },
                Some(_),
            ) => Err(MissingReplicaRoot {
                side,
                root_path: root_path.clone(),
                archived_files: *archived_files,
            }),
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
            Err(MissingReplicaRoot {
                side: Side::B,
                root_path: "/media/sd/notes".into(),
                archived_files: 42,
            })
        );
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
