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
mod changed_scan;
mod conflict;
mod content_hash;
mod device_id;
mod effective_options;
mod exit_code;
mod filter_preview;
mod folder_spread;
mod glob;
mod hex;
mod host_facts;
pub mod host_port;
mod jobs;
mod location;
mod options_error;
mod peer_name;
mod plan;
mod platform;
mod profile;
mod profile_id;
mod reconcile;
mod rel_path;
mod replica_info;
mod replica_location;
mod rule_set;
mod run_flags;
mod run_summary;
mod scan_entry;
mod scan_exchange;
mod scan_result;
mod scan_tally;
mod side;
mod skipped_path;
mod ssh_access;
mod sync_target;
mod tuning;
mod unreadable_paths;
mod write_target;

pub use action::Action;
pub use changed_scan::ChangedScan;
pub use conflict::Conflict;
pub use content_hash::{ContentHash, ContentHashError};
pub use device_id::{DeviceId, DeviceIdError};
pub use effective_options::EffectiveOptions;
pub use exit_code::{RunOutcome, StopSignal};
pub use filter_preview::{
    EntryKind, FilterFolderRow, FilterPreviewFolder, FilterPreviewReport, ListedEntry,
    filter_folder_rows, preview_filters,
};
pub use folder_spread::spread_across_folders;
pub use glob::{Glob, GlobError};
pub use host_facts::HostFacts;
pub use jobs::{Jobs, JobsError};
pub use location::{
    ExpandError, LocalLocation, Locality, Location, LocationError, PeerLocation, SshForm,
    SshLocation, UnixLocation,
};
pub use options_error::OptionsError;
pub use peer_name::{PeerName, PeerNameError};
pub use plan::Plan;
pub use platform::Platform;
pub use profile::{Profile, ProfileError, ProfileName, ProfileNameError};
pub use profile_id::{CanonicalSide, ProfileId, ProfileIdError};
pub use reconcile::reconcile;
pub use rel_path::{RelPath, RelPathError};
pub use replica_info::{MissingReplicaRoot, ReplicaInfo, ReplicaRoot};
pub use replica_location::{ReplicaLocation, ReplicaLocationError};
pub use rule_set::RuleSet;
pub use run_flags::{Command, Flags, Mode, RunFlags, Verbosity};
pub use run_summary::RunSummary;
pub use scan_entry::{FileMeta, FileState, ScanEntry, Status, Unchanged};
pub use scan_exchange::{
    Bucket, BucketCount, BucketCountMismatch, BucketDigests, Digested, UnchangedEntries,
    status_list,
};
pub use scan_result::ScanResult;
pub use scan_tally::ScanTally;
pub use side::Side;
pub use skipped_path::{SkippedPath, SkippedReason, failure_count, unreadable_of};
pub use ssh_access::{EmptySshValue, SshAccess, SshCommand, SshOption};
pub use sync_target::{AdHocTarget, SyncTarget};
pub use tuning::Tuning;
pub use unreadable_paths::UnreadablePaths;
pub use write_target::{WriteMode, WriteTarget};
