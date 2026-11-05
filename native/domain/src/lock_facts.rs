//! What a replica reports in reply to `lock` (SPEC §4.2): its archive, and
//! the room its spool has for a run's downloads.

use crate::archive_facts::ArchiveFacts;

#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct LockFacts {
    pub archive: ArchiveFacts,
    /// Bytes the replica's spool may take; `0` when it has none, and every
    /// download to it must be a `write`.
    pub spool_room: u64,
}
