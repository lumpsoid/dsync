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

mod content_hash;
mod device_id;
mod glob;
mod hex;
mod host_facts;
pub mod host_port;
mod jobs;
mod location;
mod peer_name;
mod platform;
mod profile;
mod profile_id;
mod rel_path;
mod replica_location;
mod rule_set;
mod side;
mod ssh_access;
mod tuning;
mod unreadable_paths;

pub use content_hash::{ContentHash, ContentHashError};
pub use device_id::{DeviceId, DeviceIdError};
pub use glob::{Glob, GlobError};
pub use host_facts::HostFacts;
pub use jobs::{Jobs, JobsError};
pub use location::{
    ExpandError, LocalLocation, Locality, Location, LocationError, PeerLocation, SshForm,
    SshLocation, UnixLocation,
};
pub use peer_name::{PeerName, PeerNameError};
pub use platform::Platform;
pub use profile::{Profile, ProfileError, ProfileName, ProfileNameError};
pub use profile_id::{CanonicalSide, ProfileId, ProfileIdError};
pub use rel_path::{RelPath, RelPathError};
pub use replica_location::{ReplicaLocation, ReplicaLocationError};
pub use rule_set::RuleSet;
pub use side::Side;
pub use ssh_access::{EmptySshValue, SshAccess, SshCommand, SshOption};
pub use tuning::Tuning;
pub use unreadable_paths::UnreadablePaths;
