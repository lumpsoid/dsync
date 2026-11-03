//! `dsync-domain`: the pure core of dsync-in-Rust - values, rules,
//! reconcile, planning and exchange math. No I/O, no tokio: every rule here
//! is testable with plain values, and "fetching never decides; deciding
//! never fetches" (CLAUDE.md). `dsync-core` (native/core) is the I/O shell
//! that calls down into this crate for verdicts.
//!
//! Values are parsed at the border (plan D2): each type below has private
//! fields and a fallible constructor, so an invalid one cannot exist
//! downstream. Facts only the host can supply (this machine's addresses,
//! home, environment, working directory, platform) are passed in.

mod action;
mod advertisable_address;
mod app_dirs;
mod archive;
mod archive_facts;
mod case_folding;
mod certificate_validity;
mod changed_scan;
mod comparison;
mod conflict;
mod conflict_cause;
mod content_hash;
mod device_id;
mod effective_options;
mod entry;
mod entry_id;
mod exit_code;
mod file_text;
mod filter_preview;
mod folder_spread;
mod format_version;
mod glob;
mod hex;
mod host_facts;
pub mod host_port;
mod jobs;
mod location;
mod mass_delete;
mod mass_overwrite;
mod metric_format;
mod missing_parent_folder;
mod naming;
mod on_disk;
mod options_error;
mod out_of_space;
mod owed_commits;
mod pair_code;
mod pairing_payload;
mod path_nesting;
mod peek_limits;
mod peer_name;
mod plan;
mod platform;
mod precondition;
mod profile;
mod proposal;
mod reconcile;
mod rel_path;
mod replica_info;
mod replica_location;
mod replica_spec;
mod resolution;
mod root_facts;
mod root_kind;
mod rule_set;
mod run_flags;
mod run_metrics;
mod run_record;
mod run_summary;
mod scan_entry;
mod scan_exchange;
mod scan_probe_report;
mod scan_result;
mod scan_tally;
mod scan_verdict;
mod side;
mod skipped_path;
mod ssh_access;
mod sync_target;
mod temp_name;
mod text_diff;
mod tuning;
mod unfinished_apply;
mod unreadable_paths;
mod unreadable_replica_root;
mod unusable_root;
mod write_stats;
mod wrong_root_kind;

pub use action::Action;
pub use advertisable_address::{
    advertised_host, chosen_advertisable_host, preferred_advertisable_address,
};
pub use app_dirs::{
    DIR_LEAF, DirError, DirPath, DirRule, EmptyDirPath, StateDirChoice, config_dir, state_dir,
};
pub use archive::{Archive, ArchiveCommit};
pub use archive_facts::ArchiveFacts;
pub use case_folding::CaseFolding;
pub use certificate_validity::{
    CertificateExpiry, CertificateOwner, CertificateValidity, OutOfValidity,
};
pub use changed_scan::ChangedScan;
pub use comparison::{Comparison, Offer, Sided};
pub use conflict::Conflict;
pub use conflict_cause::ConflictCause;
pub use content_hash::{ContentHash, ContentHashError};
pub use device_id::{DeviceId, DeviceIdError};
pub use effective_options::EffectiveOptions;
pub use entry::{Entry, EntryError};
pub use entry_id::{CanonicalSide, EntryId, EntryIdError};
pub use exit_code::{RunOutcome, StopSignal};
pub use file_text::{Binary, FileText};
pub use filter_preview::{
    EntryKind, FilterFolderRow, FilterPreviewFolder, FilterPreviewReport, ListedEntry,
    filter_folder_rows, preview_filters,
};
pub use folder_spread::spread_across_folders;
pub use format_version::{FormatVersion, FormatVersionError, MajorMismatch};
pub use glob::{Glob, GlobError};
pub use host_facts::HostFacts;
pub use jobs::{Jobs, JobsError};
pub use location::{
    ExpandError, LocalLocation, Locality, Location, LocationError, PeerLocation, SshForm,
    SshLocation, UnixLocation,
};
pub use mass_delete::{MassDelete, MassDeletePolicy, MassDeletePolicyError, SideDeletes};
pub use mass_overwrite::{MassOverwrite, MassOverwritePolicy, SideOverwrites};
pub use metric_format::{format_bytes, format_count, format_duration};
pub use missing_parent_folder::MissingParentFolder;
pub use naming::Naming;
pub use on_disk::OnDisk;
pub use options_error::OptionsError;
pub use out_of_space::OutOfSpace;
pub use owed_commits::{IncompleteTransfer, OwedCommits, UnevenCommitOnly};
pub use pair_code::{PairCode, ReadPairCode, default_peer_name};
pub use pairing_payload::{EnrolmentToken, PairingPayload, PairingPayloadError};
pub use path_nesting::{PathStyle, first_nesting, nests};
pub use peek_limits::PeekLimits;
pub use peer_name::{PeerName, PeerNameError};
pub use plan::Plan;
pub use platform::Platform;
pub use precondition::{ChangedDuringSync, Holds, Precondition};
pub use profile::{PROFILE_FORMAT_VERSION, Profile, ProfileError, ProfileName, ProfileNameError};
pub use proposal::Proposal;
pub use reconcile::reconcile;
pub use rel_path::{RelPath, RelPathError};
pub use replica_info::{MissingReplicaRoot, ReplicaInfo, ReplicaRoot};
pub use replica_location::{ReplicaLocation, ReplicaLocationError};
pub use replica_spec::ReplicaSpec;
pub use resolution::Resolution;
pub use root_facts::RootFacts;
pub use root_kind::RootKind;
pub use rule_set::RuleSet;
pub use run_flags::{Command, Flags, Mode, RunFlags, Verbosity};
pub use run_metrics::{OpStats, ReplicaMetrics, ReplicaOp, RunMetrics, RunPhase};
pub use run_record::{
    ActionCounts, EntryRecord, RecordedFailure, RecordedOutcome, RunRecord, SidePath,
};
pub use run_summary::RunSummary;
pub use scan_entry::{FileMeta, FileState, MTIME_WINDOW_US, ScanEntry, Status, Unchanged};
pub use scan_exchange::{
    Bucket, BucketCount, BucketCountMismatch, BucketDigests, Digested, UnchangedEntries,
    status_list,
};
pub use scan_probe_report::{ScanProbeLayer, ScanProbeLayerResult, ScanProbePass, ScanProbeReport};
pub use scan_result::ScanResult;
pub use scan_tally::ScanTally;
pub use scan_verdict::WalkedTree;
pub use side::Side;
pub use skipped_path::{SkippedAt, SkippedPath, SkippedReason, failure_count, unreadable_of};
pub use ssh_access::{EmptySshValue, SshAccess, SshCommand, SshOption};
pub use sync_target::{AdHocTarget, SyncTarget};
pub use temp_name::{
    ROOT_LOCK_FILE, STAGING_DIR, TEMP_FILE_MARKER, file_root_lock_for, file_staging_dir_for,
    is_root_lock_name, is_staging_dir_name, is_temp_file_name, temp_name_for,
};
pub use text_diff::{Block, Hunk, Line, Span, TextDiff};
pub use tuning::Tuning;
pub use unfinished_apply::UnfinishedApply;
pub use unreadable_paths::UnreadablePaths;
pub use unreadable_replica_root::UnreadableReplicaRoot;
pub use unusable_root::UnusableRoot;
pub use write_stats::{Stage, StageTime, WriteStats};
pub use wrong_root_kind::WrongRootKind;
