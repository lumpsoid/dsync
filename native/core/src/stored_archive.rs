//! One archive log as it sits in the state directory.

use std::path::PathBuf;
use std::time::SystemTime;

use dsync_domain::{EntryId, Side};

/// What someone deciding whether to delete an archive needs, and nothing
/// that takes replaying it: the replica from the file name, the root from
/// the header line alone, the cost from one stat.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct StoredArchive {
    pub log_path: PathBuf,
    /// Read off the file name, which is readable even when the header is
    /// not.
    pub entry_id: EntryId,
    pub side: Side,
    /// The replica root the header names, or `None` when the first line is
    /// not a header. Such a log is still listed: a run over it aborts, so
    /// it is the one most worth deleting.
    pub root_path: Option<String>,
    pub size_bytes: u64,
    /// When the last commit reached it.
    pub last_modified: SystemTime,
}
