//! Why a `sync`/`status` invocation's arguments were refused (exit 3).

use crate::glob::GlobError;
use crate::location::{ExpandError, LocationError};
use crate::profile::ProfileNameError;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum OptionsError {
    #[error("sync takes a profile name, or two locations - got {0} argument(s)")]
    SyncArity(usize),
    #[error("status takes exactly one profile name - got {0} argument(s)")]
    StatusArity(usize),
    #[error(transparent)]
    ProfileName(#[from] ProfileNameError),
    #[error(transparent)]
    Location(#[from] LocationError),
    #[error("put the local path first: \"{remote}\" is remote and \"{local}\" is local")]
    RemoteFirst { remote: String, local: String },
    #[error("invalid --ignore: {0}")]
    Ignore(#[from] GlobError),
    #[error("--ssh-option cannot be empty")]
    EmptySshOption,
    #[error("--remote-dsync cannot be empty")]
    EmptyRemoteDsync,
    #[error("--batch cannot be combined with --dry-run (or with status, which forces --dry-run)")]
    BatchWithDryRun,
    #[error("--json requires --batch or --dry-run")]
    JsonNeedsBatchOrDryRun,
    #[error("cannot combine --verbose and --quiet")]
    VerboseWithQuiet,
    #[error("--warn-size must be a non-negative integer, got \"{0}\"")]
    WarnSize(i64),
    #[error("--jobs must be a positive integer of at most 256, got \"{0}\"")]
    Jobs(i64),
    #[error("--apply-concurrency must be a positive integer, got \"{0}\"")]
    ApplyConcurrency(i64),
    #[error(
        "profile \"{profile}\" has the same location for both replicas once \"~\" and \
         environment variables are expanded: {canonical}"
    )]
    ProfileSameLocation { profile: String, canonical: String },
    #[error(
        "the two locations are the same once \"~\" and environment variables are expanded: \
         {canonical}"
    )]
    AdHocSameLocation { canonical: String },
    #[error(transparent)]
    Expand(#[from] ExpandError),
}
