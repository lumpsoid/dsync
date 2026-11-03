//! What the core's values look like on the wire to the head: plain data
//! carrying the display values each row needs, pre-computed here so the
//! head never round-trips per build (plan D10). Every conversion reads a
//! value; none decides anything the core had not already decided.

use std::time::{SystemTime, UNIX_EPOCH};

use dsync_core::{ActionFailure, Certificate, DeviceIdentity, PairedDevice, StoredArchive};
use dsync_domain::{
    Action, Block, CertificateExpiry, CertificateOwner, Comparison, Conflict, EntryKind,
    FilterFolderRow, FilterPreviewFolder, FilterPreviewReport, Hunk, Line, Offer, PeekLimits, Plan,
    Proposal, ReplicaInfo, ReplicaRoot, RootKind, RunSummary, ScanTally, Side, SideDeletes,
    SideOverwrites, Sided, SkippedAt, SkippedPath, SkippedReason, Span, Status, TextDiff,
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

/// What an entry's two roots are: folders, or one file each.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize, SignalPiece)]
pub enum RootKindView {
    Folder,
    File,
}

impl From<RootKind> for RootKindView {
    fn from(kind: RootKind) -> RootKindView {
        match kind {
            RootKind::Folder => RootKindView::Folder,
            RootKind::File => RootKindView::File,
        }
    }
}

impl From<RootKindView> for RootKind {
    fn from(kind: RootKindView) -> RootKind {
        match kind {
            RootKindView::Folder => RootKind::Folder,
            RootKindView::File => RootKind::File,
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
    /// The head's shape: every entry pairs a root on this device with one
    /// on the same paired device.
    Head(ProfileView),
    /// Any other profile (a CLI-written one); runnable, not editable here.
    Other {
        name: String,
        entries: Vec<OtherEntryView>,
    },
    /// The file would not load; `message` says why.
    Unreadable { name: String, message: String },
}

/// One entry of an [`ProfileEntry::Other`] profile, its sides as typed.
#[derive(Serialize, SignalPiece)]
pub struct OtherEntryView {
    pub a: String,
    pub b: String,
}

#[derive(Serialize, SignalPiece)]
pub struct ProfileView {
    pub name: String,
    pub peer_device_id: String,
    /// The paired device's name now; `None` when it is no longer paired.
    pub peer_name: Option<String>,
    pub jobs: Option<u32>,
    pub ignore: Vec<String>,
    /// SPEC §7.6's run marker is present for any of the entries.
    pub last_run_unfinished: bool,
    pub entries: Vec<EntryView>,
}

/// One entry of a [`ProfileView`]: a root on this device and one on the
/// profile's paired device.
#[derive(Serialize, SignalPiece)]
pub struct EntryView {
    pub entry_id: String,
    pub kind: RootKindView,
    pub local_root: String,
    pub local_root_expanded: String,
    /// Why the local root cannot be a replica root now, if it cannot.
    pub local_root_refusal: Option<String>,
    pub remote_root: String,
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
    pub entry_id: String,
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
            entry_id: archive.entry_id.as_str().to_owned(),
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
                // The run refuses these with its own error, which the head
                // shows; none is a folder with files to count.
                ReplicaRoot::Present
                | ReplicaRoot::ParentMissing { .. }
                | ReplicaRoot::WrongKind { .. }
                | ReplicaRoot::Unreadable { .. } => None,
                ReplicaRoot::Missing { root_path } => Some(MissingRootView {
                    root_path: root_path.clone(),
                    archived_files: info.archived_files,
                }),
            },
        }
    }
}

/// One side's SPEC §5.2 counts, with what they come to: every path the
/// scan checked, and those it found changed - every path not scanned
/// unchanged.
#[derive(Serialize, SignalPiece)]
pub struct TallyView {
    pub metadata_matched: u64,
    pub hash_matched: u64,
    pub modified: u64,
    pub created: u64,
    pub deleted: u64,
    pub total: u64,
    pub changed: u64,
}

impl From<&ScanTally> for TallyView {
    fn from(tally: &ScanTally) -> TallyView {
        let total = tally.total();
        TallyView {
            metadata_matched: count(tally.metadata_matched),
            hash_matched: count(tally.hash_matched),
            modified: count(tally.modified),
            created: count(tally.created),
            deleted: count(tally.deleted),
            total: count(total),
            changed: count(total - tally.metadata_matched - tally.hash_matched),
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
#[derive(Clone, Serialize, SignalPiece)]
pub struct ConflictView {
    pub path: String,
    pub a: Option<StatusView>,
    pub b: Option<StatusView>,
}

impl From<&Conflict> for ConflictView {
    fn from(conflict: &Conflict) -> ConflictView {
        ConflictView {
            path: conflict.path.to_string(),
            a: conflict.a.as_ref().map(StatusView::from),
            b: conflict.b.as_ref().map(StatusView::from),
        }
    }
}

#[derive(Clone, Serialize, SignalPiece)]
pub enum StatusView {
    Unchanged { file: FileView, by_hash: bool },
    Created(FileView),
    Modified(FileView),
    Deleted,
}

#[derive(Clone, Serialize, SignalPiece)]
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
        }
    }
}

#[derive(Clone, Serialize, SignalPiece)]
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
/// reversal would copy (`None`: no reverse is offered); `offer`: whether
/// its two files can be compared.
#[derive(Clone, Serialize, SignalPiece)]
pub struct ProposalView {
    pub action: ActionView,
    pub reverse_bytes: Option<u64>,
    pub offer: OfferView,
}

impl ProposalView {
    /// `proposal`, its compare judged by `limits`.
    pub fn of(proposal: &Proposal, limits: &PeekLimits) -> ProposalView {
        ProposalView {
            action: ActionView::from(&proposal.action),
            reverse_bytes: proposal.reversed().as_ref().map(Action::bytes),
            offer: OfferView::of(Comparison::of_proposal(proposal).as_ref(), limits),
        }
    }
}

/// What a review row's compare would give, known before a byte is read:
/// nothing to compare (a delete, a commit-only, a copy aside, a conflict
/// with no file on either side), the two texts, a media file left unread,
/// or `side`'s file over the read cap at `size` bytes.
#[derive(Clone, Copy, Serialize, SignalPiece)]
pub enum OfferView {
    NotComparable,
    Readable,
    Media,
    TooLarge { side: SideView, size: u64 },
}

impl OfferView {
    pub fn of(comparison: Option<&Comparison>, limits: &PeekLimits) -> OfferView {
        match comparison.map(|comparison| comparison.offer(limits)) {
            None => OfferView::NotComparable,
            Some(Offer::Readable) => OfferView::Readable,
            Some(Offer::Media) => OfferView::Media,
            Some(Offer::TooLarge { side, size }) => OfferView::TooLarge {
                side: side.into(),
                size,
            },
        }
    }
}

/// A review row's two files set against each other (the diff page), or
/// `NotComparable` when the row has none to compare - no such row in the
/// open review, or one whose offer is [`OfferView::NotComparable`].
/// `old_side`/`new_side` (and [`BlockView`]'s `old_lines`/`new_lines`),
/// not the domain's `old`/`new`: `new` is a Dart keyword.
#[derive(Serialize, SignalPiece)]
pub enum ComparisonView {
    NotComparable,
    Compared {
        path: String,
        old_side: SidedView,
        new_side: SidedView,
        verdict: ComparedView,
    },
}

impl ComparisonView {
    pub fn of(comparison: &Comparison, verdict: ComparedView) -> ComparisonView {
        ComparisonView::Compared {
            path: comparison.path.to_string(),
            old_side: comparison.old.into(),
            new_side: comparison.new.into(),
            verdict,
        }
    }
}

/// One side of a compared path; `size` is `None` when that side has no
/// file (an empty file is `Some(0)`).
#[derive(Clone, Copy, Serialize, SignalPiece)]
pub struct SidedView {
    pub side: SideView,
    pub size: Option<u64>,
}

impl From<Sided> for SidedView {
    fn from(sided: Sided) -> SidedView {
        SidedView {
            side: sided.side.into(),
            size: sided.size,
        }
    }
}

/// What the compare found: left unread (media, over the cap), unreadable
/// as text (binary, a failed read), or both texts' line diff - the same
/// text, or the hunks that differ.
#[derive(Serialize, SignalPiece)]
pub enum ComparedView {
    Media,
    TooLarge {
        side: SideView,
        size: u64,
    },
    Binary {
        side: SideView,
    },
    Unreadable {
        side: SideView,
        message: String,
    },
    /// `bytes_differ`: only line endings, a final newline or a BOM differ.
    Identical {
        bytes_differ: bool,
    },
    Hunks(Vec<HunkView>),
}

impl From<&TextDiff> for ComparedView {
    fn from(diff: &TextDiff) -> ComparedView {
        match diff {
            TextDiff::Identical { bytes_differ } => ComparedView::Identical {
                bytes_differ: *bytes_differ,
            },
            TextDiff::Hunks(hunks) => {
                ComparedView::Hunks(hunks.iter().map(HunkView::from).collect())
            }
        }
    }
}

/// A run of changes with their context; the starts are 1-based line
/// numbers, as [`Hunk`]'s.
#[derive(Serialize, SignalPiece)]
pub struct HunkView {
    pub old_start: u32,
    pub new_start: u32,
    pub blocks: Vec<BlockView>,
}

impl From<&Hunk> for HunkView {
    fn from(hunk: &Hunk) -> HunkView {
        HunkView {
            old_start: hunk.old_start,
            new_start: hunk.new_start,
            blocks: hunk.blocks.iter().map(BlockView::from).collect(),
        }
    }
}

#[derive(Serialize, SignalPiece)]
pub enum BlockView {
    Same(Vec<String>),
    Changed {
        old_lines: Vec<LineView>,
        new_lines: Vec<LineView>,
    },
}

impl From<&Block> for BlockView {
    fn from(block: &Block) -> BlockView {
        let lines = |lines: &[Line]| lines.iter().map(LineView::from).collect();
        match block {
            Block::Same(lines) => BlockView::Same(lines.clone()),
            Block::Changed { old, new } => BlockView::Changed {
                old_lines: lines(old),
                new_lines: lines(new),
            },
        }
    }
}

#[derive(Serialize, SignalPiece)]
pub struct LineView {
    pub spans: Vec<SpanView>,
}

impl From<&Line> for LineView {
    fn from(line: &Line) -> LineView {
        LineView {
            spans: line.spans.iter().map(SpanView::from).collect(),
        }
    }
}

#[derive(Serialize, SignalPiece)]
pub struct SpanView {
    pub text: String,
    pub emphasized: bool,
}

impl From<&Span> for SpanView {
    fn from(span: &Span) -> SpanView {
        SpanView {
            text: span.text.clone(),
            emphasized: span.emphasized,
        }
    }
}

/// One action's outcome; `failure` says why it did not land.
#[derive(Clone, Serialize, SignalPiece)]
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

/// One side's share of SPEC §10's overwrite-guard verdict: how many files
/// the run overwrites there, how many of those it empties to 0 bytes, out
/// of how many its archive holds.
#[derive(Serialize, SignalPiece)]
pub struct MassOverwriteView {
    pub side: SideView,
    pub overwrites: u64,
    pub truncated: u64,
    pub archived: u64,
}

impl From<&SideOverwrites> for MassOverwriteView {
    fn from(overwrites: &SideOverwrites) -> MassOverwriteView {
        MassOverwriteView {
            side: overwrites.side.into(),
            overwrites: count(overwrites.overwrites),
            truncated: count(overwrites.truncated),
            archived: count(overwrites.archived),
        }
    }
}

/// A run as the head shows it, sent after every change. Everything but
/// the plan's rows is whole in every view. The plan is sent whole once -
/// the first view after the hub takes it - and thereafter each view says
/// either the same plan with the rows changed since the view before, no
/// plan, or a new plan, whole: a session's views all reach the head, in
/// order, so it folds each into the last. Built by the run's own state in
/// `run/state.rs`.
///
/// A session runs a profile's entries one after another: `entries` lists
/// them all, `current` is the one running (or that ran last), and every
/// field from `connected_at_ms` on describes that entry alone.
#[derive(Serialize, SignalPiece)]
pub struct RunView {
    /// SPEC §11.3's `--dry-run`: the plan is shown and nothing applied.
    pub dry_run: bool,
    pub phase: RunPhaseView,
    pub standing: RunStandingView,
    /// The profile's entries, in the order they run; empty until the
    /// target resolves.
    pub entries: Vec<EntryRunView>,
    /// Which of `entries` the plan and tallies describe; `None` before the
    /// first starts.
    pub current: Option<u32>,
    /// When both sides connected; `None` before.
    pub connected_at_ms: Option<i64>,
    /// What each side's `hello` said, once both have.
    pub replicas: Option<ReplicasView>,
    /// Both scans' SPEC §5.2 counts, once both are done.
    pub tally: Option<TalliesView>,
    /// Paths either scan skipped or could not read, side A's first.
    pub skipped: Vec<SkippedView>,
    /// The entry's plan, if it has one yet.
    pub plan: PlanUpdateView,
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
    /// A peer:// link dropped and is being re-dialled: the attempt just
    /// made, and the backoff before the next dial.
    Reconnecting {
        attempt: u32,
        next_in_ms: u64,
    },
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
    /// SPEC §10's overwrite guard waits on the head: one entry per side it
    /// tripped on.
    ConfirmingOverwrites {
        sides: Vec<MassOverwriteView>,
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
    /// The head declined the overwrites the guard asked about; nothing was
    /// applied.
    OverwritesDeclined,
    /// The run ended without a summary and nobody stopped it.
    NoSummary,
    /// A profile of several entries ran to its end, and these did not
    /// sync; the rest did. A resume runs every entry again.
    FinishedWithIssues {
        entries: Vec<EntryIssueView>,
    },
}

/// One entry of a run session: its roots as typed, and how it went.
#[derive(Serialize, SignalPiece)]
pub struct EntryRunView {
    pub kind: RootKindView,
    /// Side A's path on this device: the folder, or the file itself.
    pub local_root: String,
    /// Side B's path on its host, unexpanded.
    pub remote_root: String,
    pub status: EntryStatusView,
}

#[derive(Clone, PartialEq, Eq, Debug, Serialize, SignalPiece)]
pub enum EntryStatusView {
    /// Not started yet.
    Pending,
    Running,
    Synced,
    /// Not there to sync; nothing was written.
    Skipped {
        reason: String,
    },
    Failed {
        message: String,
    },
    /// Never started: the session was stopped, or an earlier entry found
    /// the device unreachable.
    NotRun,
}

/// An entry that did not sync, by its place in the session's entries.
#[derive(Serialize, SignalPiece)]
pub struct EntryIssueView {
    pub index: u32,
    pub reason: String,
}

#[derive(Serialize, SignalPiece)]
pub struct ReplicasView {
    pub a: ReplicaInfoView,
    pub b: ReplicaInfoView,
    pub history: HistoryView,
}

impl ReplicasView {
    pub fn of(a: &ReplicaInfo, b: &ReplicaInfo) -> ReplicasView {
        ReplicasView {
            a: ReplicaInfoView::from(a),
            b: ReplicaInfoView::from(b),
            history: HistoryView::of(a, b),
        }
    }
}

/// What the pair has behind it, from each side's last commit: a side with
/// none has no archive, so this run is a first sync (SPEC §6) - a path
/// present on one side only is copied, never deleted.
#[derive(Serialize, SignalPiece)]
pub enum HistoryView {
    /// Neither side has committed.
    FirstSync,
    /// Only one side has: `empty` joins with no archive - a new replica
    /// beside an established one, or wiped app data.
    OneSided { empty: SideView },
    /// Both have, each at its own last commit.
    Synced { last_a_ms: i64, last_b_ms: i64 },
}

impl HistoryView {
    pub fn of(a: &ReplicaInfo, b: &ReplicaInfo) -> HistoryView {
        match (a.last_commit, b.last_commit) {
            (None, None) => HistoryView::FirstSync,
            (None, Some(_)) => HistoryView::OneSided { empty: SideView::A },
            (Some(_), None) => HistoryView::OneSided { empty: SideView::B },
            (Some(last_a), Some(last_b)) => HistoryView::Synced {
                last_a_ms: millis(last_a),
                last_b_ms: millis(last_b),
            },
        }
    }
}

/// Both scans' counts, and what they come to across the two sides.
#[derive(Serialize, SignalPiece)]
pub struct TalliesView {
    pub a: TallyView,
    pub b: TallyView,
    pub checked: u64,
    pub changed: u64,
}

impl TalliesView {
    pub fn of(a: &ScanTally, b: &ScanTally) -> TalliesView {
        let (a, b) = (TallyView::from(a), TallyView::from(b));
        TalliesView {
            checked: a.total + b.total,
            changed: a.changed + b.changed,
            a,
            b,
        }
    }
}

/// The bytes the plan's copies write onto each side.
#[derive(Clone, Serialize, SignalPiece)]
pub struct PlanSummaryView {
    pub bytes_to_a: u64,
    pub bytes_to_b: u64,
}

impl From<&Plan> for PlanSummaryView {
    fn from(plan: &Plan) -> PlanSummaryView {
        let mut summary = PlanSummaryView {
            bytes_to_a: 0,
            bytes_to_b: 0,
        };
        for proposal in &plan.actions {
            let action = &proposal.action;
            match action.written() {
                Some((Side::A, _)) => summary.bytes_to_a += action.bytes(),
                Some((Side::B, _)) => summary.bytes_to_b += action.bytes(),
                None => {}
            }
        }
        summary
    }
}

/// Where the run stands for what the head may do with it: `Live` from
/// connecting to applying (the screen is held, leaving asks first, a
/// stop is offered); `Resumable` when an attempt ended short and a resume
/// runs it again (paused, failed, the replica busy, the deletions
/// declined, no summary); `Over` when it finished or was stopped.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, SignalPiece)]
pub enum RunStandingView {
    Live,
    Resumable,
    Over,
}

#[derive(Serialize, SignalPiece)]
pub struct ProgressView {
    pub completed: u64,
    pub total: u64,
}

/// A run view's plan, as an update to the one the head holds.
#[derive(Serialize, SignalPiece)]
pub enum PlanUpdateView {
    /// No plan in this entry's attempt yet (or any more: a new entry or
    /// a resume began). The head drops whatever plan it held.
    Absent,
    /// A plan the head has not seen, whole: every row with its current
    /// choice and outcome.
    New(PlanView),
    /// The plan the head already holds; the rows whose choice or outcome
    /// changed since the last view it received. Empty when none did.
    Same {
        actions: Vec<ActionRowUpdateView>,
        conflicts: Vec<ConflictRowUpdateView>,
    },
}

#[cfg(test)]
impl PlanUpdateView {
    /// The plan this update carries whole; panics on any other variant.
    pub fn new_plan(&self) -> &PlanView {
        match self {
            PlanUpdateView::New(plan) => plan,
            _ => panic!("the view carries no new plan"),
        }
    }
}

/// A plan whole: its rows and the fixed facts about it.
#[derive(Serialize, SignalPiece)]
pub struct PlanView {
    /// The plan's actions, in its order.
    pub actions: Vec<PlanRowView>,
    /// The conflicts, in the plan's order.
    pub conflicts: Vec<ConflictRowView>,
    pub bytes_to_transfer: u64,
    /// The warn size (SPEC §10) `bytes_to_transfer` is over; `None` when
    /// it is not, or no size is set.
    pub exceeded_warn_size_bytes: Option<u64>,
    /// What the plan's copies write where.
    pub summary: PlanSummaryView,
    /// A re-dialled entry's plan reviewed again with the answers given
    /// before kept; `None` on a first review.
    pub recalled: Option<RecalledView>,
}

/// A re-dialled review's count of its rows: how many changed since the
/// head answered them (the review shows them first) and how many kept the
/// head's earlier choice.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, SignalPiece)]
pub struct RecalledView {
    pub changed: u64,
    pub kept: u64,
}

/// An action row's whole mutable state: its choice and its outcome, for
/// the row at `index` of the plan's actions.
#[derive(Serialize, SignalPiece)]
pub struct ActionRowUpdateView {
    pub index: u32,
    pub choice: ActionChoiceView,
    pub outcome: Option<ResultView>,
}

/// A conflict row's whole mutable state: its choice and its outcome, for
/// the row at `index` of the plan's conflicts.
#[derive(Serialize, SignalPiece)]
pub struct ConflictRowUpdateView {
    pub index: u32,
    pub choice: ConflictChoiceView,
    pub outcome: Option<ResultView>,
}

/// One planned action: the proposal, what the review chose for it, and its
/// outcome once reported.
#[derive(Clone, Serialize, SignalPiece)]
pub struct PlanRowView {
    pub proposal: ProposalView,
    pub choice: ActionChoiceView,
    pub outcome: Option<ResultView>,
    /// In a re-dialled review, how the row changed since the head answered
    /// it; `None` when it did not, or on a first review.
    pub changed: Option<ActionChangeView>,
}

/// A re-dialled review's action row that is not the one answered before:
/// `was` is the action that was, `None` for a path new to the review.
#[derive(Clone, Serialize, SignalPiece)]
pub struct ActionChangeView {
    pub was: Option<ActionView>,
}

/// One conflict: the conflict, the choices it offers (a side with no
/// record of the path cannot be kept; keeping both needs a file on both
/// sides), what the review chose, and the outcome of what that applied.
#[derive(Clone, Serialize, SignalPiece)]
pub struct ConflictRowView {
    pub conflict: ConflictView,
    pub offered: Vec<ConflictChoiceView>,
    /// Whether its two sides' files can be compared.
    pub offer: OfferView,
    pub choice: ConflictChoiceView,
    pub outcome: Option<ResultView>,
    /// [`PlanRowView::changed`], for a conflict.
    pub changed: Option<ConflictChangeView>,
}

/// A re-dialled review's conflict that is not the one answered before:
/// `was` is the conflict that was, `None` for a path new to the review.
#[derive(Clone, Serialize, SignalPiece)]
pub struct ConflictChangeView {
    pub was: Option<ConflictView>,
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

/// A pairing window as the head shows it, whole: sent after every change.
/// `Waiting` and `Confirming` are open; every other one is how it ended,
/// and the last it sends.
#[derive(Serialize, SignalPiece)]
pub enum PairingView {
    /// Open, nothing redeemed yet: the payload to show (as text and QR),
    /// this device's id for the other side to compare, where the window
    /// answers, and when the payload stops being redeemable.
    Waiting {
        payload: String,
        device_id: String,
        endpoint: String,
        expires_at_ms: i64,
    },
    /// A device redeemed the payload and waits for the operator's answer
    /// (`ConfirmPairing`): its id, to compare with the one it shows, and
    /// the name it will be recorded as.
    Confirming {
        device_id: String,
        name: String,
    },
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
    /// The token expired unredeemed; `window_seconds` is how long it was
    /// good for.
    Expired {
        window_seconds: u64,
    },
    Cancelled,
    /// The listener itself failed.
    Failed {
        message: String,
    },
}
