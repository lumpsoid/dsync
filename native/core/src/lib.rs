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
mod body;
mod case_folding;
mod certificate;
mod device_identity;
mod device_identity_store;
mod file_write;
mod filter_listing;
mod interface_addresses;
mod local_replica;
mod paired_device;
mod paired_device_store;
mod paired_devices;
mod profile_store;
mod replica;
mod replica_error;
mod replica_lock;
mod run_marker;
mod scan_pool;
mod scan_probe;
mod scan_session;
mod scanner;
mod state_dir;
mod stored_archive;
mod write_error;
mod write_stats;
mod writer_pool;

pub use archive_inventory::{ArchiveDeleteError, ArchiveInventory};
pub use archive_store::{
    ARCHIVE_SCHEMA_VERSION, ArchiveError, ArchiveHeader, ArchiveStore, ForeignHeader,
};
pub use body::{Body, BodyDropped, BodyError, BodySender, body_channel};
pub use case_folding::probe_case_folding;
pub use certificate::{Certificate, CertificateError};
pub use device_identity::{DeviceIdentity, IdentityIssueError, IdentityPairError};
pub use device_identity_store::{DeviceIdentityStore, IdentityError};
pub use filter_listing::{UnlistableFolder, list_filter_folder, preview_filters_at};
pub use interface_addresses::interface_addresses;
pub use local_replica::LocalReplica;
pub use paired_device::{DifferentKey, PairedDevice};
pub use paired_device_store::{
    PAIRED_DEVICES_SCHEMA_VERSION, PairedDeviceStore, PairedDeviceStoreError,
};
pub use paired_devices::{PairedDevices, PairingError};
pub use profile_store::{ProfileStore, ProfileStoreError};
pub use replica::{BucketTicket, DigestTicket, DigestedScan, OpenedScan, Replica};
pub use replica_error::{FileOp, ReplicaError};
pub use replica_lock::{LockError, ReplicaLock};
pub use run_marker::RunMarker;
pub use scan_probe::ScanProbe;
pub use scan_session::ScanSession;
pub use scanner::{HASH_READ_BUFFER_BYTES, Scanner, UnreadableRoot};
pub use state_dir::StateDir;
pub use stored_archive::StoredArchive;
pub use write_error::WriteError;
pub use write_stats::{Stage, StageTime, WriteStats};
