//! What one profile run did, as its history keeps it: when it ran, what
//! it ran, and per entry how it ended, what it applied, and every path it
//! deleted, overwrote or failed on - so a file that changed can be traced
//! to the run that changed it after that run's output is gone.

use crate::rel_path::RelPath;
use crate::run_flags::Mode;
use crate::side::Side;

/// One run of a profile (or an ad-hoc pair), from its first entry to its
/// last.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunRecord {
    /// Milliseconds since the Unix epoch.
    pub started_ms: u64,
    pub ended_ms: u64,
    /// `None` for an ad-hoc `dsync sync <locA> <locB>`.
    pub profile: Option<String>,
    pub mode: Mode,
    /// A stop was asked for before the run ended.
    pub stopped: bool,
    /// One per entry, in the order they ran.
    pub entries: Vec<EntryRecord>,
}

/// How one entry of a run went.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryRecord {
    pub entry_id: String,
    /// Each side's location, as the profile spells it.
    pub a: String,
    pub b: String,
    pub outcome: RecordedOutcome,
    /// Why it was skipped or failed; `None` when it synced or never ran.
    pub reason: Option<String>,
    pub counts: ActionCounts,
    /// Every file the run deleted, on the side it was deleted on.
    pub deleted: Vec<SidePath>,
    /// Every file the run replaced with the other side's version, on the
    /// side that was overwritten.
    pub overwritten: Vec<SidePath>,
    /// Every action that failed, and why.
    pub failures: Vec<RecordedFailure>,
    /// Times a dropped `peer://` side was dialled again.
    pub reconnects: u32,
}

/// How an entry ended.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RecordedOutcome {
    Synced,
    Skipped,
    Failed,
    NotRun,
}

/// What an entry's apply did, action by action, and what its summary left
/// undone.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionCounts {
    pub copied: usize,
    pub copied_aside: usize,
    pub deleted: usize,
    pub committed: usize,
    pub failed: usize,
    /// Planned actions the decider did not keep.
    pub skipped: usize,
    /// Conflicts left unresolved.
    pub conflicts: usize,
    /// Paths a scan could not read.
    pub unreadable: usize,
}

/// A path on one side.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct SidePath {
    pub side: Side,
    pub path: RelPath,
}

/// One failed action: its path, and the failure as the run reported it
/// (which names the side it was on).
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct RecordedFailure {
    pub path: RelPath,
    pub message: String,
}
