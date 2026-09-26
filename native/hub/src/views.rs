//! What the core's values look like on the wire to the head: plain data
//! carrying the display values each row needs, pre-computed here so the
//! head never round-trips per build (plan D10). Every conversion reads a
//! value; none decides anything the core had not already decided.

use std::time::{SystemTime, UNIX_EPOCH};

use dsync_core::{ActionFailure, Certificate, DeviceIdentity, PairedDevice, StoredArchive};
use dsync_domain::{
    Action, CertificateExpiry, CertificateOwner, Conflict, EntryKind, FilterFolderRow,
    FilterPreviewFolder, FilterPreviewReport, Proposal, ReplicaInfo, ReplicaRoot, RunSummary,
    ScanProbeReport, ScanTally, Side, SideDeletes, SkippedAt, SkippedPath, SkippedReason, Status,
    Unchanged,
};
use rinf::SignalPiece;
use serde::{Deserialize, Serialize};

/// Milliseconds since the Unix epoch: what Dart's `DateTime` is built
/// from. Before the epoch is negative.
pub fn millis(at: SystemTime) -> i64 {
    match at.duration_since(UNIX_EPOCH) {
        Ok(after) => i64::try_from(after.as_millis()).unwrap_or(i64::MAX),
        Err(before) => i64::try_from(before.duration().as_millis()).map_or(i64::MIN, |ms| -ms),
    }
}

fn count(n: usize) -> u64 {
    u64::try_from(n).unwrap_or(u64::MAX)
}

#[derive(Clone, Copy, Serialize, Deserialize, SignalPiece)]
pub enum SideView {
    A,
    B,
}

impl From<Side> for SideView {
    fn from(side: Side) -> SideView {
        match side {
            Side::A => SideView::A,
            Side::B => SideView::B,
        }
    }
}

impl From<SideView> for Side {
    fn from(side: SideView) -> Side {
        match side {
            SideView::A => Side::A,
            SideView::B => Side::B,
        }
    }
}

/// Where the core keeps its state (identity, pairings, archives, and the
/// head's own `settings.json` beside them) and its saved profiles.
#[derive(Serialize, SignalPiece)]
pub struct DirsView {
    pub state_dir: String,
    pub profiles_dir: String,
}

/// This device: its id, the name its certificate carries, the window and
/// SPEC §4.4's expiry warning when due.
#[derive(Serialize, SignalPiece)]
pub struct IdentityView {
    pub device_id: String,
    pub common_name: Option<String>,
    pub not_before_ms: i64,
    pub not_after_ms: i64,
    pub expiry_note: Option<String>,
}

impl IdentityView {
    pub fn of(identity: &DeviceIdentity, now: SystemTime) -> IdentityView {
        let certificate = identity.certificate();
        let validity = certificate.validity();
        IdentityView {
            device_id: identity.device_id().to_string(),
            common_name: certificate.common_name().map(str::to_owned),
            not_before_ms: millis(validity.not_before()),
            not_after_ms: millis(validity.not_after()),
            expiry_note: expiry_note(certificate, CertificateOwner::ThisHost, now),
        }
    }
}

fn expiry_note(
    certificate: &Certificate,
    owner: CertificateOwner,
    now: SystemTime,
) -> Option<String> {
    certificate
        .validity()
        .expiry_within(owner, now, CertificateExpiry::DEFAULT_WINDOW)
        .map(|expiry| expiry.to_string())
}

/// A paired device as its row shows it.
#[derive(Serialize, SignalPiece)]
pub struct DeviceView {
    pub device_id: String,
    pub name: String,
    pub common_name: Option<String>,
    /// Sorted, expanded, as grants are stored.
    pub granted_roots: Vec<String>,
    /// Where it was last reached, as the user reads and types it.
    pub address: String,
    pub paired_at_ms: i64,
    pub verified_at_ms: Option<i64>,
    pub not_before_ms: i64,
    pub not_after_ms: i64,
    pub expiry_note: Option<String>,
}

impl DeviceView {
    pub fn of(device: &PairedDevice, now: SystemTime) -> DeviceView {
        let certificate = device.certificate();
        let validity = certificate.validity();
        DeviceView {
            device_id: device.device_id().to_string(),
            name: device.name().to_string(),
            common_name: certificate.common_name().map(str::to_owned),
            granted_roots: device.granted_roots().iter().cloned().collect(),
            address: device.last_known_address().to_string(),
            paired_at_ms: millis(device.paired_at()),
            verified_at_ms: device.verified_at().map(millis),
            not_before_ms: millis(validity.not_before()),
            not_after_ms: millis(validity.not_after()),
            expiry_note: expiry_note(
                certificate,
                CertificateOwner::Peer(device.name().clone()),
                now,
            ),
        }
    }
}

/// An open pairing window: the payload to show (as text and QR), this
/// device's id to compare, and where the window answers.
#[derive(Serialize, SignalPiece)]
pub struct PairingShownView {
    pub payload: String,
    pub device_id: String,
    pub endpoint: String,
    pub expires_in_seconds: u64,
}

/// A scanned or pasted pairing code, before it is redeemed.
#[derive(Serialize, SignalPiece)]
pub enum PairCodeView {
    Unreadable {
        message: String,
    },
    Read {
        /// The name field's default for the showing device.
        desktop_name: String,
        /// Where it will answer from now on (its peer:// address).
        address: String,
        device_id: Option<String>,
    },
}

/// A peer probe's answer. `Unreachable`: only the address is in doubt.
/// `Refused`: something answered and the pairing or a certificate is the
/// problem.
#[derive(Serialize, SignalPiece)]
pub enum ProbeOutcome {
    Reachable { address: String },
    Unreachable { message: String },
    Refused { message: String },
}

/// One saved profile.
#[derive(Serialize, SignalPiece)]
pub enum ProfileEntry {
    /// The head's shape: this device's folder with one on a paired device.
    Head(ProfileView),
    /// Any other pair (a CLI-written profile); runnable, not editable here.
    Other {
        name: String,
        profile_id: Option<String>,
        a: String,
        b: String,
    },
    /// The file would not load; `message` says why.
    Unreadable { name: String, message: String },
}

#[derive(Serialize, SignalPiece)]
pub struct ProfileView {
    pub name: String,
    pub profile_id: String,
    pub local_root: String,
    pub local_root_expanded: String,
    /// Why the local root cannot be a replica root now, if it cannot.
    pub local_root_refusal: Option<String>,
    pub peer_device_id: String,
    /// The paired device's name now; `None` when it is no longer paired.
    pub peer_name: Option<String>,
    pub remote_root: String,
    pub jobs: Option<u32>,
    pub ignore: Vec<String>,
    /// SPEC §7.6's run marker is present.
    pub last_run_unfinished: bool,
}

/// Serving: the port bound and what to type on the other device.
#[derive(Serialize, SignalPiece)]
pub struct ServeStartedView {
    pub port: u16,
    pub advertised: String,
    pub device_id: String,
}

#[derive(Serialize, SignalPiece)]
pub struct AddressesView {
    pub interfaces: Vec<String>,
    pub preferred: Option<String>,
}

#[derive(Serialize, SignalPiece)]
pub struct ArchiveView {
    pub log_path: String,
    pub profile_id: String,
    pub side: SideView,
    /// `None`: the first line is not a readable header.
    pub root_path: Option<String>,
    pub size_bytes: u64,
    pub last_modified_ms: i64,
}

impl From<&StoredArchive> for ArchiveView {
    fn from(archive: &StoredArchive) -> ArchiveView {
        ArchiveView {
            log_path: archive.log_path.to_string_lossy().into_owned(),
            profile_id: archive.profile_id.as_str().to_owned(),
            side: archive.side.into(),
            root_path: archive.root_path.clone(),
            size_bytes: archive.size_bytes,
            last_modified_ms: millis(archive.last_modified),
        }
    }
}

/// The filter preview: every folder in pre-order (a folder's subfolders
/// follow it, one `depth` deeper), what each rule excluded, and the
/// folders that could not be listed.
#[derive(Serialize, SignalPiece)]
pub struct FilterPreviewView {
    pub folders: Vec<FilterFolderView>,
    pub excluded_by_rule: Vec<RuleCountView>,
    pub unreadable_folders: Vec<String>,
}

#[derive(Serialize, SignalPiece)]
pub struct FilterFolderView {
    /// `None`: the root.
    pub path: Option<String>,
    pub depth: u32,
    pub excluded_by: Option<String>,
    pub included_files: u64,
    pub included_bytes: u64,
    pub excluded_files: u64,
    pub excluded_bytes: u64,
}

#[derive(Serialize, SignalPiece)]
pub struct RuleCountView {
    pub pattern: String,
    pub files: u64,
}

impl From<&FilterPreviewReport> for FilterPreviewView {
    fn from(report: &FilterPreviewReport) -> FilterPreviewView {
        let mut folders = Vec::new();
        flatten(&report.root, 0, &mut folders);
        FilterPreviewView {
            folders,
            excluded_by_rule: report
                .excluded_by_rule
                .iter()
                .map(|(glob, files)| RuleCountView {
                    pattern: glob.as_str().to_owned(),
                    files: *files,
                })
                .collect(),
            unreadable_folders: report
                .unreadable_folders
                .iter()
                .map(ToString::to_string)
                .collect(),
        }
    }
}

fn flatten(folder: &FilterPreviewFolder, depth: u32, into: &mut Vec<FilterFolderView>) {
    into.push(FilterFolderView {
        path: folder.path.as_ref().map(ToString::to_string),
        depth,
        excluded_by: folder
            .excluded_by
            .as_ref()
            .map(|glob| glob.as_str().to_owned()),
        included_files: folder.included_files,
        included_bytes: folder.included_bytes,
        excluded_files: folder.excluded_files,
        excluded_bytes: folder.excluded_bytes,
    });
    for child in &folder.folders {
        flatten(child, depth.saturating_add(1), into);
    }
}

/// One entry of a browsed folder.
#[derive(Serialize, SignalPiece)]
pub struct FilterRowView {
    pub path: String,
    pub name: String,
    pub kind: EntryKindView,
    pub excluded_by: Option<String>,
    /// Whether a run would carry it.
    pub syncs: bool,
}

#[derive(Serialize, SignalPiece)]
pub enum EntryKindView {
    File { size: u64 },
    Folder,
    Other,
}

impl From<&FilterFolderRow> for FilterRowView {
    fn from(row: &FilterFolderRow) -> FilterRowView {
        FilterRowView {
            path: row.path.to_string(),
            name: row.name().to_owned(),
            kind: match row.kind {
                EntryKind::File { size } => EntryKindView::File { size },
                EntryKind::Folder => EntryKindView::Folder,
                EntryKind::Other => EntryKindView::Other,
            },
            excluded_by: row
                .excluded_by
                .as_ref()
                .map(|glob| glob.as_str().to_owned()),
            syncs: row.syncs(),
        }
    }
}

/// The scan probe: the text report, and its figures.
#[derive(Serialize, SignalPiece)]
pub struct ScanProbeView {
    pub root: String,
    pub report: String,
    pub passes: Vec<ScanPassView>,
}

#[derive(Serialize, SignalPiece)]
pub struct ScanPassView {
    pub index: u32,
    pub layers: Vec<ScanLayerView>,
}

#[derive(Serialize, SignalPiece)]
pub struct ScanLayerView {
    pub label: String,
    pub elapsed_micros: u64,
    pub files: u64,
    pub directories: Option<u64>,
    pub bytes: u64,
    pub micros_per_file: f64,
}

impl From<&ScanProbeReport> for ScanProbeView {
    fn from(report: &ScanProbeReport) -> ScanProbeView {
        ScanProbeView {
            root: report.root.to_string_lossy().into_owned(),
            report: report.to_string(),
            passes: report
                .passes
                .iter()
                .map(|pass| ScanPassView {
                    index: u32::try_from(pass.index).unwrap_or(u32::MAX),
                    layers: pass
                        .layers
                        .iter()
                        .map(|layer| ScanLayerView {
                            label: layer.layer.label().to_owned(),
                            elapsed_micros: u64::try_from(layer.elapsed.as_micros())
                                .unwrap_or(u64::MAX),
                            files: layer.files,
                            directories: layer.directories,
                            bytes: layer.bytes,
                            micros_per_file: layer.micros_per_file(),
                        })
                        .collect(),
                })
                .collect(),
        }
    }
}

#[derive(Serialize, SignalPiece)]
pub struct ReplicaInfoView {
    /// `None`: this side has never committed (a first sync).
    pub last_commit_ms: Option<i64>,
    pub archive_path: Option<String>,
    pub missing_root: Option<MissingRootView>,
}

#[derive(Serialize, SignalPiece)]
pub struct MissingRootView {
    pub root_path: String,
    pub archived_files: u64,
}

impl From<&ReplicaInfo> for ReplicaInfoView {
    fn from(info: &ReplicaInfo) -> ReplicaInfoView {
        ReplicaInfoView {
            last_commit_ms: info.last_commit.map(millis),
            archive_path: info.archive_path.clone(),
            missing_root: match &info.root {
                ReplicaRoot::Present => None,
                ReplicaRoot::Missing {
                    root_path,
                    archived_files,
                } => Some(MissingRootView {
                    root_path: root_path.clone(),
                    archived_files: *archived_files,
                }),
            },
        }
    }
}

#[derive(Serialize, SignalPiece)]
pub struct TallyView {
    pub metadata_matched: u64,
    pub hash_matched: u64,
    pub modified: u64,
    pub created: u64,
    pub deleted: u64,
    pub untrusted: u64,
}

impl From<&ScanTally> for TallyView {
    fn from(tally: &ScanTally) -> TallyView {
        TallyView {
            metadata_matched: count(tally.metadata_matched),
            hash_matched: count(tally.hash_matched),
            modified: count(tally.modified),
            created: count(tally.created),
            deleted: count(tally.deleted),
            untrusted: count(tally.untrusted),
        }
    }
}

/// A path a scan skipped. `is_failure` is the reason's own verdict
/// (SPEC §5.1): a symlink is the rules obeyed, the rest a side unable to
/// stand behind a status.
#[derive(Serialize, SignalPiece)]
pub struct SkippedView {
    pub side: SideView,
    /// The path, or for a name no path can carry, its folder and the name.
    pub path: String,
    pub reason: SkippedReasonView,
    pub detail: String,
    pub is_failure: bool,
}

#[derive(Serialize, SignalPiece)]
pub enum SkippedReasonView {
    Symlink,
    Unreadable,
    CaseFoldCollision,
    UnrepresentableName,
    SpecialFile,
}

impl SkippedView {
    pub fn of(side: Side, skipped: &SkippedPath) -> SkippedView {
        SkippedView {
            side: side.into(),
            path: match &skipped.at {
                SkippedAt::Path(path) => path.to_string(),
                SkippedAt::UnrepresentableName { parent, name } => match parent {
                    Some(parent) => format!("{parent}/{name}"),
                    None => name.clone(),
                },
            },
            reason: match skipped.reason {
                SkippedReason::Symlink => SkippedReasonView::Symlink,
                SkippedReason::Unreadable => SkippedReasonView::Unreadable,
                SkippedReason::CaseFoldCollision => SkippedReasonView::CaseFoldCollision,
                SkippedReason::UnrepresentableName => SkippedReasonView::UnrepresentableName,
                SkippedReason::SpecialFile => SkippedReasonView::SpecialFile,
            },
            detail: skipped.detail.clone(),
            is_failure: skipped.reason.is_failure(),
        }
    }
}

/// A conflict (SPEC §6), each side's status as the scan found it.
/// `interrupted`: a side holds a write that never committed.
#[derive(Serialize, SignalPiece)]
pub struct ConflictView {
    pub path: String,
    pub a: Option<StatusView>,
    pub b: Option<StatusView>,
    pub interrupted: bool,
}

impl From<&Conflict> for ConflictView {
    fn from(conflict: &Conflict) -> ConflictView {
        ConflictView {
            path: conflict.path.to_string(),
            a: conflict.a.as_ref().map(StatusView::from),
            b: conflict.b.as_ref().map(StatusView::from),
            interrupted: conflict.interrupted(),
        }
    }
}

#[derive(Serialize, SignalPiece)]
pub enum StatusView {
    Unchanged { file: FileView, by_hash: bool },
    Created(FileView),
    Modified(FileView),
    Deleted,
    Untrusted(FileView),
    UntrustedAbsent,
}

#[derive(Serialize, SignalPiece)]
pub struct FileView {
    pub size: u64,
    pub mtime_us: i64,
}

impl From<&Status> for StatusView {
    fn from(status: &Status) -> StatusView {
        let file = |state: &dsync_domain::FileState| FileView {
            size: state.meta.size,
            mtime_us: state.meta.mtime_us,
        };
        match status {
            Status::Unchanged { file: state, by } => StatusView::Unchanged {
                file: file(state),
                by_hash: *by == Unchanged::HashMatched,
            },
            Status::Created(state) => StatusView::Created(file(state)),
            Status::Modified(state) => StatusView::Modified(file(state)),
            Status::Deleted => StatusView::Deleted,
            Status::Untrusted(state) => StatusView::Untrusted(file(state)),
            Status::UntrustedAbsent => StatusView::UntrustedAbsent,
        }
    }
}

#[derive(Serialize, SignalPiece)]
pub enum ActionView {
    Copy {
        path: String,
        from: SideView,
        bytes: u64,
    },
    /// A conflict's "keep both": `path` on `from` saved at `to` on the
    /// other side. Its result is keyed by `path`, the conflict's own.
    CopyAside {
        path: String,
        from: SideView,
        to: String,
        bytes: u64,
    },
    Delete {
        path: String,
        on: SideView,
    },
    CommitOnly {
        path: String,
    },
}

impl From<&Action> for ActionView {
    fn from(action: &Action) -> ActionView {
        match action {
            Action::Copy { path, from, bytes } => ActionView::Copy {
                path: path.to_string(),
                from: (*from).into(),
                bytes: *bytes,
            },
            Action::CopyAside {
                path,
                from,
                to,
                bytes,
            } => ActionView::CopyAside {
                path: path.to_string(),
                from: (*from).into(),
                to: to.to_string(),
                bytes: *bytes,
            },
            Action::Delete { path, on } => ActionView::Delete {
                path: path.to_string(),
                on: (*on).into(),
            },
            Action::CommitOnly { path } => ActionView::CommitOnly {
                path: path.to_string(),
            },
        }
    }
}

/// A planned action and, when it can be put the other way, the bytes that
/// reversal would copy (`None`: no reverse is offered).
#[derive(Serialize, SignalPiece)]
pub struct ProposalView {
    pub action: ActionView,
    pub reverse_bytes: Option<u64>,
}

impl From<&Proposal> for ProposalView {
    fn from(proposal: &Proposal) -> ProposalView {
        ProposalView {
            action: ActionView::from(&proposal.action),
            reverse_bytes: proposal.reversed().as_ref().map(Action::bytes),
        }
    }
}

/// One action's outcome; `failure` says why it did not land.
#[derive(Serialize, SignalPiece)]
pub struct ResultView {
    pub action: ActionView,
    pub failure: Option<String>,
}

impl ResultView {
    pub fn of(action: &Action, outcome: &Result<(), ActionFailure>) -> ResultView {
        ResultView {
            action: action.into(),
            failure: outcome.as_ref().err().map(ToString::to_string),
        }
    }
}

#[derive(Serialize, SignalPiece)]
pub struct SummaryView {
    pub applied: u64,
    pub skipped: u64,
    pub conflicts: u64,
    pub failed: u64,
    pub unreadable: u64,
}

impl From<&RunSummary> for SummaryView {
    fn from(summary: &RunSummary) -> SummaryView {
        SummaryView {
            applied: count(summary.applied),
            skipped: count(summary.skipped),
            conflicts: count(summary.conflicts),
            failed: count(summary.failed),
            unreadable: count(summary.unreadable),
        }
    }
}

/// One side's share of SPEC §10's delete-guard verdict: how many files
/// the run deletes there, out of how many its archive holds.
#[derive(Serialize, SignalPiece)]
pub struct MassDeleteView {
    pub side: SideView,
    pub deletes: u64,
    pub archived: u64,
}

impl From<&SideDeletes> for MassDeleteView {
    fn from(deletes: &SideDeletes) -> MassDeleteView {
        MassDeleteView {
            side: deletes.side.into(),
            deletes: count(deletes.deletes),
            archived: count(deletes.archived),
        }
    }
}

/// A run as the head shows it, whole: sent after every change, so each
/// one stands alone and the head renders the latest without folding
/// anything. Built by the run's own state in `run/state.rs`.
#[derive(Serialize, SignalPiece)]
pub struct RunView {
    /// SPEC §11.3's `--dry-run`: the plan is shown and nothing applied.
    pub dry_run: bool,
    pub phase: RunPhaseView,
    /// When both sides connected; `None` before.
    pub connected_at_ms: Option<i64>,
    /// What each side's `hello` said, once both have.
    pub replicas: Option<ReplicasView>,
    /// Both scans' SPEC §5.2 counts, once both are done.
    pub tally: Option<TalliesView>,
    /// Paths either scan skipped or could not read, side A's first.
    pub skipped: Vec<SkippedView>,
    /// The conflicts, in the plan's order.
    pub conflicts: Vec<ConflictRowView>,
    /// The plan's actions, in its order; empty before it is made.
    pub plan: Vec<PlanRowView>,
    pub bytes_to_transfer: u64,
    /// The apply's latest progress: completed of total.
    pub progress: Option<ProgressView>,
    /// How many of the reported outcomes landed, and how many failed.
    pub applied: u64,
    pub failed: u64,
    /// The `--timings` report, once the attempt has ended.
    pub timings: Option<String>,
}

/// Where a run stands. The live ones are `Connecting` to `Applying`;
/// `Finished` and `Stopped` end the session; the rest wait on a resume.
#[derive(Serialize, SignalPiece)]
pub enum RunPhaseView {
    Connecting,
    /// Scanning and reconciling; a dry run stays here until its summary.
    Scanning,
    /// The plan waits on the head's review; the running total of its
    /// choices so far.
    Reviewing(DecisionSummaryView),
    /// SPEC §10's delete guard waits on the head: one entry per side it
    /// tripped on.
    ConfirmingDeletes {
        sides: Vec<MassDeleteView>,
    },
    Applying,
    Finished(SummaryView),
    /// Stopped by the head after `completed` actions.
    Stopped {
        completed: u64,
    },
    /// Suspended because the app went to the background, after
    /// `completed` actions; a resume runs it again.
    Paused {
        completed: u64,
    },
    Failed {
        message: String,
    },
    /// SPEC §4.3's held lock: its own outcome, with its own remedy.
    ReplicaBusy {
        message: String,
    },
    /// The head declined the deletions the guard asked about; nothing was
    /// applied.
    DeletesDeclined,
    /// The run ended without a summary and nobody stopped it.
    NoSummary,
}

#[derive(Serialize, SignalPiece)]
pub struct ReplicasView {
    pub a: ReplicaInfoView,
    pub b: ReplicaInfoView,
}

#[derive(Serialize, SignalPiece)]
pub struct TalliesView {
    pub a: TallyView,
    pub b: TallyView,
}

#[derive(Serialize, SignalPiece)]
pub struct ProgressView {
    pub completed: u64,
    pub total: u64,
}

/// One planned action: the proposal, what the review chose for it, and its
/// outcome once reported.
#[derive(Serialize, SignalPiece)]
pub struct PlanRowView {
    pub proposal: ProposalView,
    pub choice: ActionChoiceView,
    pub outcome: Option<ResultView>,
}

/// One conflict: the conflict, the choices it offers (a side with no
/// record of the path cannot be kept; keeping both needs a file on both
/// sides), what the review chose, and the outcome of what that applied.
#[derive(Serialize, SignalPiece)]
pub struct ConflictRowView {
    pub conflict: ConflictView,
    pub offered: Vec<ConflictChoiceView>,
    pub choice: ConflictChoiceView,
    pub outcome: Option<ResultView>,
}

/// A planned action under review: as planned, reversed (the loser's
/// version put back, only where the proposal offers it), or left out.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize, SignalPiece)]
pub enum ActionChoiceView {
    Proposed,
    Reversed,
    Skipped,
}

/// A conflict under review: left open, settled toward one side, or both
/// versions kept - side B's saved beside side A's.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize, SignalPiece)]
pub enum ConflictChoiceView {
    Unresolved,
    KeepA,
    KeepB,
    KeepBoth,
}

/// The review's running total: the plan's actions that will be applied
/// (reversed ones included) and how many are reversed or skipped; the
/// conflicts settled toward a side, kept both, or left open.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, SignalPiece)]
pub struct DecisionSummaryView {
    pub apply: u64,
    pub reversed: u64,
    pub skipped: u64,
    pub resolved: u64,
    pub kept_both: u64,
    pub left_open: u64,
}

/// Serving, as the head shows it, whole: sent after every change.
#[derive(Serialize, SignalPiece)]
pub struct ServeView {
    pub phase: ServePhaseView,
    /// What connections reported, newest first, a bounded few.
    pub lines: Vec<ServeLineView>,
}

#[derive(Serialize, SignalPiece)]
pub enum ServePhaseView {
    /// Answering: `advertised` is what to type on the other device.
    Listening { advertised: String },
    /// Stopped by the head.
    Stopped,
    /// The listener failed on its own.
    Failed { message: String },
}

/// One connection event, when it happened.
#[derive(Clone, Serialize, SignalPiece)]
pub struct ServeLineView {
    pub at_ms: i64,
    pub event: ServeEventView,
}

#[derive(Clone, Serialize, SignalPiece)]
pub enum ServeEventView {
    /// Turned away before a session began.
    Refused { from: String, message: String },
    Started {
        from: String,
        device_id: String,
        name: String,
    },
    /// A session opened the replica at `root` (expanded).
    Serving { root: String },
    Ended {
        from: String,
        device_id: String,
        name: String,
        failure: Option<String>,
    },
}

/// How a pairing window ended.
#[derive(Serialize, SignalPiece)]
pub enum EnrolmentEndView {
    /// Confirmed and recorded; grant it a root before it can reach one.
    Enrolled(DeviceView),
    Declined {
        device_id: String,
    },
    /// Nobody answered before the token expired.
    Unconfirmed {
        device_id: String,
    },
    /// Confirmed, but the store refused it.
    NotStored {
        device_id: String,
        message: String,
    },
    /// The token expired unredeemed.
    Expired,
    Cancelled,
    /// The listener itself failed.
    Failed {
        message: String,
    },
}
