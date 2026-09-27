//! What a run tells whoever watches it (SPEC §11.4): the header, the scan's
//! findings, the plan, each action's outcome as it lands, the summary, and
//! every failure. The CLI renders these (human or `--json`); the head gets
//! them through the hub.

use std::io;
use std::path::PathBuf;
use std::sync::Arc;

use dsync_domain::{
    Action, BucketCountMismatch, Conflict, IncompleteTransfer, MassDelete, MissingParentFolder,
    MissingReplicaRoot, Plan, ReplicaInfo, ReplicaOp, RunSummary, ScanTally, Side, SkippedPath,
    UnevenCommitOnly, UnusableRoot, WrongRootKind,
};

use crate::replica_error::ReplicaError;
use crate::replica_lock::LockError;

/// One step of a run, in the order the run takes them.
#[derive(Clone, Debug)]
pub enum RunEvent {
    /// Both `hello` replies, before anything else: the run header's facts.
    /// `last_run_unfinished` is SPEC §7.6's run marker, as found before
    /// this run touched it.
    Replicas {
        a: ReplicaInfo,
        b: ReplicaInfo,
        last_run_unfinished: bool,
    },
    /// Both scans' SPEC §5.2 branch counts, once both are done.
    ScanTally { a: ScanTally, b: ScanTally },
    /// A path a scan skipped or could not read (SPEC §5.1), side A's first.
    Skipped { side: Side, skipped: SkippedPath },
    /// A path the reconciler would not resolve, before the plan.
    Conflict(Conflict),
    /// The plan, before the decider sees it. `exceeds_warn_size` is SPEC
    /// §10's warning, under the run's `warn_size_bytes`.
    Plan { plan: Plan, exceeds_warn_size: bool },
    /// SPEC §10's delete guard tripped on the approved actions, before any
    /// of them is reported. `allowed`: the run's `--allow-mass-delete`
    /// applies them without asking; otherwise the decider is asked next.
    MassDelete { verdict: MassDelete, allowed: bool },
    /// One action the decider approved, conflict resolutions included,
    /// before the apply starts.
    Action(Action),
    /// One action's outcome, in completion order (SPEC §7.1). An action
    /// reported applied is durable on both sides.
    Result {
        action: Action,
        outcome: Result<(), ActionFailure>,
    },
    /// Outcomes so far against the approved total, after each result.
    Progress { completed: usize, total: usize },
    /// The run completed (SPEC §11.4); absent from a run that failed.
    Summary(RunSummary),
    /// A failure. One event per failure; after one that ends the run, only
    /// the unlocks' own failures can follow.
    Error(RunError),
}

/// Why a run could not go on.
#[derive(Clone, Debug, thiserror::Error)]
pub enum RunError {
    #[error("replica {side}: {} failed: {source}", op.name())]
    Replica {
        side: Side,
        op: ReplicaOp,
        #[source]
        source: Arc<ReplicaError>,
    },
    /// SPEC §4.5's refusal: a root missing once its replica has synced.
    /// Rendered with the device it is on by whoever knows it
    /// ([`MissingReplicaRoot::describe`]).
    #[error(transparent)]
    MissingRoot(MissingReplicaRoot),
    /// A single-file root whose folder is missing: never created.
    #[error(transparent)]
    ParentMissing(MissingParentFolder),
    /// A root that is not its entry's kind, refused before either replica
    /// is locked.
    #[error(transparent)]
    WrongKind(WrongRootKind),
    /// The two sides digested under different bucket counts: a far side
    /// that did not follow the exchange.
    #[error(transparent)]
    Exchange(BucketCountMismatch),
    /// SPEC §10's refusal: the delete guard tripped and the decider did not
    /// confirm. Nothing was applied.
    #[error("{}", .0.describe())]
    DeletesNotConfirmed(MassDelete),
    #[error("the run marker {}: {source}", path.display())]
    Marker {
        path: PathBuf,
        #[source]
        source: Arc<io::Error>,
    },
}

impl From<UnusableRoot> for RunError {
    fn from(unusable: UnusableRoot) -> RunError {
        match unusable {
            UnusableRoot::Missing(missing) => RunError::MissingRoot(missing),
            UnusableRoot::ParentMissing(missing) => RunError::ParentMissing(missing),
            UnusableRoot::WrongKind(wrong) => RunError::WrongKind(wrong),
        }
    }
}

impl RunError {
    pub(crate) fn replica(side: Side, op: ReplicaOp) -> impl FnOnce(ReplicaError) -> RunError {
        move |source| RunError::Replica {
            side,
            op,
            source: Arc::new(source),
        }
    }

    /// SPEC §4.3: another run holds a replica's lock, or its folder's. Its
    /// own outcome, not a failure of this run: the remedy is to wait for
    /// that one.
    pub fn replica_busy(&self) -> bool {
        matches!(
            self,
            RunError::Replica { source, .. }
                if matches!(
                    **source,
                    ReplicaError::Lock(LockError::Held { .. } | LockError::FolderInUse { .. })
                )
        )
    }

    /// The side the failure is on, where it is on one.
    pub fn side(&self) -> Option<Side> {
        match self {
            RunError::Replica { side, .. } => Some(*side),
            RunError::MissingRoot(missing) => Some(missing.side),
            RunError::ParentMissing(missing) => Some(missing.side),
            RunError::WrongKind(wrong) => Some(wrong.side),
            RunError::Exchange(_) | RunError::DeletesNotConfirmed(_) | RunError::Marker { .. } => {
                None
            }
        }
    }
}

/// Why one action failed (SPEC §7.6). The path is left as it landed, its
/// mark (if any) stays, and the next run resolves it.
#[derive(Clone, Debug, thiserror::Error)]
pub enum ActionFailure {
    /// A replica operation failed: the action's own, its window's mark, or
    /// the commit batch it was in (a failed batch fails every action in
    /// it, since some of its commits may have landed and some not).
    #[error("replica {side}: {} failed: {source}", op.name())]
    Replica {
        side: Side,
        op: ReplicaOp,
        #[source]
        source: Arc<ReplicaError>,
    },
    #[error(transparent)]
    IncompleteTransfer(#[from] IncompleteTransfer),
    #[error(transparent)]
    UnevenCommitOnly(#[from] UnevenCommitOnly),
    /// A copy whose source the scan did not see as a file.
    #[error("replica {side} has no file to copy at this path")]
    NoSource { side: Side },
    /// The path on `side` is no longer what the scan saw there: a write or
    /// delete found it changed and left it untouched, or a copy's source
    /// changed under its read. Nothing is recorded for it, and the next
    /// run reconciles it (SPEC §7.6).
    #[error("replica {side}: changed during sync, left for the next run")]
    ChangedDuringSync { side: Side },
}

impl ActionFailure {
    pub(crate) fn replica(side: Side, op: ReplicaOp) -> impl FnOnce(ReplicaError) -> ActionFailure {
        move |source| match source {
            ReplicaError::Changed(_) => ActionFailure::ChangedDuringSync { side },
            source => ActionFailure::Replica {
                side,
                op,
                source: Arc::new(source),
            },
        }
    }

    /// Whether this is `side`'s path found changed during sync.
    pub(crate) fn changed_on(&self, side: Side) -> bool {
        matches!(self, ActionFailure::ChangedDuringSync { side: on } if *on == side)
    }

    /// The failure that ends the whole run, when this is one (see
    /// [`ReplicaError::ends_run`]).
    pub(crate) fn ends_run(&self) -> Option<RunError> {
        match self {
            ActionFailure::Replica { side, op, source } if source.ends_run() => {
                Some(RunError::Replica {
                    side: *side,
                    op: *op,
                    source: source.clone(),
                })
            }
            _ => None,
        }
    }
}
