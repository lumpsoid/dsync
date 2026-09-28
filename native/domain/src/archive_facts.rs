//! What a replica reports about its archive in reply to `lock` (SPEC
//! §4.2): read from the one replay the lock's holder makes, so no later
//! commit by another run can have made it stale.

use std::time::SystemTime;

#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct ArchiveFacts {
    /// When the archive last committed; `None` if it never has (SPEC
    /// §8.2). Reported by the replica because the initiator cannot stat an
    /// archive on a remote host.
    pub last_commit: Option<SystemTime>,
    /// The files the archive holds, for SPEC §4.5's refusal.
    pub archived_files: u64,
}
