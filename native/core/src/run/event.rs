//! What a run tells whoever watches it (SPEC §11.4): the header, the scan's
//! findings, the plan, each action's outcome as it lands, the summary, and
//! every failure. The CLI renders these (human or `--json`); the head gets
//! them through the hub.

use std::io;
use std::path::PathBuf;
use std::sync::Arc;

use dsync_domain::{
    Action, BucketCountMismatch, Conflict, IncompleteTransfer, MassDelete, MassOverwrite,
    MissingParentFolder, MissingReplicaRoot, OutOfSpace, Plan, ReplicaInfo, ReplicaOp, RunSummary,
    ScanTally, Side, SkippedPath, UnevenCommitOnly, UnreadableReplicaRoot, UnusableRoot,
    WrongRootKind,
};

use crate::replica_error::ReplicaError;
use crate::replica_lock::LockError;

/// One step of a run, in the order the run takes them.
#[derive(Clone, Debug)]
pub enum RunEvent {
    /// The run header's facts, once both replicas are locked: each root as
    /// its `hello` found it, each archive as its `lock` read it. Not sent
    /// for a run refused before then (a failed `hello`, a root of the wrong
    /// kind, a lock refused); its error is. `last_run_unfinished` is SPEC
    /// §7.6's run marker, as found before this run touched it.
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
    /// SPEC §10's overwrite guard tripped on the approved actions, after
    /// the delete guard let them through and before any is reported.
    /// `allowed`: the run's `--allow-mass-overwrite` applies them without
    /// asking; otherwise the decider is asked next.
    MassOverwrite {
        verdict: MassOverwrite,
        allowed: bool,
    },
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
    /// A root that could not be looked at, refused before either replica
    /// is locked: whether it is there is unknown.
    #[error(transparent)]
    RootUnreadable(UnreadableReplicaRoot),
    /// The two sides digested under different bucket counts: a far side
    /// that did not follow the exchange.
    #[error(transparent)]
    Exchange(BucketCountMismatch),
    /// SPEC §10's refusal: the delete guard tripped and the decider did not
    /// confirm. Nothing was applied.
    #[error("{}", .0.describe())]
    DeletesNotConfirmed(MassDelete),
    /// SPEC §10's overwrite guard tripped and the decider did not confirm.
    /// Nothing was applied.
    #[error("{}", .0.describe())]
    OverwritesNotConfirmed(MassOverwrite),
    /// A write found a side out of space: the apply stopped, and what it
    /// had not attempted is left for the next run.
    #[error(transparent)]
    OutOfSpace(OutOfSpace),
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
            UnusableRoot::Unreadable(unreadable) => RunError::RootUnreadable(unreadable),
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
                    ReplicaError::Lock(
                        LockError::Held { .. }
                            | LockError::FolderInUse { .. }
                            | LockError::RootInUse { .. }
                    )
                )
        )
    }

    /// Whether this is the link to a `peer://` side dropping (one of
    /// `peers`): the one run failure a profile run dials again for (SPEC
    /// §11.3).
    pub fn is_link_drop(&self, peers: &[Side]) -> bool {
        matches!(
            self,
            RunError::Replica { side, source, .. }
                if peers.contains(side)
                    && matches!(&**source, ReplicaError::Link(link) if link.is_drop())
        )
    }

    /// A [`LockError::Held`] on one of `peers`: on a re-dial, most likely
    /// the dropped session's own lock, not yet let go.
    pub(crate) fn is_held_on(&self, peers: &[Side]) -> bool {
        matches!(
            self,
            RunError::Replica { side, source, .. }
                if peers.contains(side)
                    && matches!(**source, ReplicaError::Lock(LockError::Held { .. }))
        )
    }

    /// The side the failure is on, where it is on one.
    pub fn side(&self) -> Option<Side> {
        match self {
            RunError::Replica { side, .. } => Some(*side),
            RunError::MissingRoot(missing) => Some(missing.side),
            RunError::ParentMissing(missing) => Some(missing.side),
            RunError::WrongKind(wrong) => Some(wrong.side),
            RunError::RootUnreadable(unreadable) => Some(unreadable.side),
            RunError::OutOfSpace(full) => Some(full.side),
            RunError::Exchange(_)
            | RunError::DeletesNotConfirmed(_)
            | RunError::OverwritesNotConfirmed(_)
            | RunError::Marker { .. } => None,
        }
    }
}

/// Why one action failed (SPEC §7.6). The path is left as it was, and the
/// next run resolves it.
#[derive(Clone, Debug, thiserror::Error)]
pub enum ActionFailure {
    /// A replica operation failed: the action's own, or the commit batch it was in (a failed batch fails every action in
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

    /// The side this failure found out of space, when it is one (see
    /// [`ReplicaError::out_of_space`]): the apply writes nothing more.
    pub(crate) fn out_of_space(&self) -> Option<Side> {
        match self {
            ActionFailure::Replica { side, source, .. } if source.out_of_space() => Some(*side),
            _ => None,
        }
    }
}
