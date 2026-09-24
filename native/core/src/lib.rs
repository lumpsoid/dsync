//! `dsync-core`: the I/O core of dsync-in-Rust - stores, replicas (local and
//! remote), transport, server, pairing and run. It calls down into
//! `dsync-domain` for every decision and never decides for itself; this
//! crate only fetches facts and executes plans. Replaces the spike
//! (`native/spike`, crate `dsync-spike`) module by module; see
//! native/NOTES.md.

mod archive_inventory;
mod archive_line;
mod archive_store;
pub mod atomic_write;
mod replica_lock;
mod run_marker;
mod state_dir;
mod stored_archive;

pub use archive_inventory::{ArchiveDeleteError, ArchiveInventory};
pub use archive_store::{
    ARCHIVE_SCHEMA_VERSION, ArchiveError, ArchiveHeader, ArchiveStore, ForeignHeader,
};
pub use replica_lock::{LockError, ReplicaLock};
pub use run_marker::RunMarker;
pub use state_dir::StateDir;
pub use stored_archive::StoredArchive;
