//! What a profile run tells whoever watches it: its entries, then for
//! each in turn its connect, every event of its [`crate::Run`], and how
//! it ended.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use dsync_domain::{
    EntryId, MissingParentFolder, MissingReplicaRoot, RootKind, RunOutcome, RunSummary, Side,
    UnreadableReplicaRoot, WrongRootKind,
};

use super::redial::ReconnectCause;
use crate::connector::{ConnectError, PeerContact};
use crate::run::{RunError, RunEvent};

/// One step of a profile run. `entry` is the entry's position in
/// [`ProfileEvent::Entries`].
#[derive(Clone, Debug)]
pub enum ProfileEvent {
    /// The profile's entries, in the order they run, before the first.
    Entries { list: Vec<ListedEntry> },
    /// The entry's two sides are being connected.
    EntryConnecting { entry: usize },
    /// Both sides are up; what dialling learned about each `peer://` one.
    EntryConnected {
        entry: usize,
        peers: Vec<PeerContact>,
    },
    /// A side could not be connected; the entry did not run.
    EntryNotConnected {
        entry: usize,
        failure: Arc<ConnectError>,
    },
    /// The entry's link to a `peer://` side dropped, or a re-dial of it
    /// failed in a way that may pass (SPEC §11.3): re-dial `attempt`,
    /// counted from one, starts `after` from now. Supersedes the failure the attempt's run
    /// already emitted, when `cause` is a run's: the entry has not ended.
    /// A successful re-dial is told by [`ProfileEvent::EntryConnected`]
    /// again, never by another `EntryConnecting`.
    EntryReconnecting {
        entry: usize,
        attempt: u32,
        after: Duration,
        cause: ReconnectCause,
    },
    /// A `peer://` side's dial waits while the session it claims - its
    /// dropped link's - finishes its writes: `queued_bytes` are still to
    /// be handed to its writers. 0 is not done: its last landings may
    /// still be on them. Comes between the entry's `EntryConnecting` or
    /// `EntryReconnecting` and what ends that connect.
    EntryDraining { entry: usize, queued_bytes: u64 },
    /// One event of the entry's run, as the run emitted it.
    Entry { entry: usize, event: RunEvent },
    /// How the entry ended; one for every entry, those never started
    /// included.
    EntryFinished { entry: usize, outcome: EntryOutcome },
}

/// One entry as a profile run lists it before starting.
#[derive(Clone, Debug)]
pub struct ListedEntry {
    pub entry_id: EntryId,
    pub kind: RootKind,
    /// Side A's location as typed.
    pub a: String,
    /// Side B's location as typed.
    pub b: String,
}

/// How one entry of a profile run ended.
#[derive(Clone, Debug)]
pub enum EntryOutcome {
    /// Its run completed, failed actions and all (the summary counts them).
    Synced(RunSummary),
    /// Not synced, and nothing written: the entry is not there to sync.
    Skipped(SkipReason),
    /// Its connect or its run failed.
    Failed(EntryFailure),
    /// Never started: the profile was stopped, or an earlier entry found
    /// the device or transport unreachable.
    NotRun,
}

/// Why an entry was skipped.
#[derive(Clone, Debug, thiserror::Error)]
pub enum SkipReason {
    /// SPEC §4.5: a root missing once its replica has synced. Never taken
    /// for an empty one, which would delete every archived file on the
    /// other side.
    #[error(transparent)]
    Missing(MissingReplicaRoot),
    /// A single-file entry whose file's folder is missing: never created,
    /// and never taken for an empty folder either.
    #[error(transparent)]
    ParentMissing(MissingParentFolder),
    /// A root that is not the entry's kind: a folder where it syncs one
    /// file, or the reverse. Nothing was locked or written.
    #[error(transparent)]
    WrongKind(WrongRootKind),
    /// A root that could not be looked at: whether it is there is unknown,
    /// so it is neither created nor synced. Nothing was locked or written.
    #[error(transparent)]
    Unreadable(UnreadableReplicaRoot),
}

/// Why an entry failed.
#[derive(Clone, Debug, thiserror::Error)]
pub enum EntryFailure {
    /// A side could not be connected.
    #[error(transparent)]
    Connect(Arc<ConnectError>),
    /// The run failed (a refused hello, a held lock, declined deletions,
    /// ...): the first error it emitted.
    #[error(transparent)]
    Run(RunError),
    /// A second stop dropped the run mid-way.
    #[error("dropped mid-way by a second stop")]
    Dropped,
}

impl EntryOutcome {
    /// The outcome of a run that ended with `summary` and `error` (its
    /// first).
    pub(crate) fn of_run(summary: Option<RunSummary>, error: Option<RunError>) -> EntryOutcome {
        match (summary, error) {
            (_, Some(RunError::MissingRoot(missing))) => {
                EntryOutcome::Skipped(SkipReason::Missing(missing))
            }
            (_, Some(RunError::ParentMissing(missing))) => {
                EntryOutcome::Skipped(SkipReason::ParentMissing(missing))
            }
            (_, Some(RunError::WrongKind(wrong))) => {
                EntryOutcome::Skipped(SkipReason::WrongKind(wrong))
            }
            (_, Some(RunError::RootUnreadable(unreadable))) => {
                EntryOutcome::Skipped(SkipReason::Unreadable(unreadable))
            }
            (_, Some(error)) => EntryOutcome::Failed(EntryFailure::Run(error)),
            (Some(summary), None) => EntryOutcome::Synced(summary),
            (None, None) => EntryOutcome::Failed(EntryFailure::Dropped),
        }
    }

    /// Whether the entries after this one should not start: its device or
    /// transport is unreachable, and each of them would only wait out the
    /// same failure. Every other failure is the entry's own.
    pub(crate) fn ends_profile(&self) -> bool {
        matches!(
            self,
            EntryOutcome::Failed(EntryFailure::Connect(error)) if error.failure.ends_profile()
        )
    }

    /// SPEC §11.5's code for this entry alone, no signal: a synced entry's
    /// as its run's; anything else is 3, as a run with no summary is.
    pub fn exit_code(&self) -> u8 {
        let summary = match self {
            EntryOutcome::Synced(summary) => Some(*summary),
            EntryOutcome::Skipped(_) | EntryOutcome::Failed(_) | EntryOutcome::NotRun => None,
        };
        RunOutcome {
            summary,
            errored: false,
            interrupted_by: None,
        }
        .exit_code()
    }
}

/// Two of a profile's in-process sides are one tree, or one lies inside
/// the other, once symlinks are resolved: moved since the profile was
/// checked, or nested through a symlink its text does not show.
#[derive(Clone, Debug, thiserror::Error)]
#[error(
    "entries[{}].{} ({}) and entries[{}].{} ({}) are the same, or one lies inside the \
     other, once symlinks are resolved; no path of a profile may be, contain or lie inside \
     another",
    first.0, first.1, first_path.display(), second.0, second.1, second_path.display()
)]
pub struct ResolvedOverlap {
    /// The entry's position and side.
    pub first: (usize, Side),
    pub first_path: PathBuf,
    pub second: (usize, Side),
    pub second_path: PathBuf,
}
