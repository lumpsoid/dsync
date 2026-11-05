//! What [`crate::Replica::take_landed`] answers (SPEC §4.2): every staged
//! body that finished landing since the last call, and how many are still
//! queued. In core, not domain, because each landing's failure is a
//! [`ReplicaError`].

use dsync_domain::{FileMeta, RelPath};

use crate::replica_error::ReplicaError;

#[derive(Debug, Default)]
pub struct Landings {
    /// Each finished landing: the path it landed onto and what landed
    /// there, exactly as a `write` to it would have answered.
    pub landed: Vec<(RelPath, Result<FileMeta, ReplicaError>)>,
    /// Staged landings not yet finished.
    pub queued: u64,
}
