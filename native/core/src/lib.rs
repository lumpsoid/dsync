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
mod certificate;
mod device_identity;
mod device_identity_store;
mod interface_addresses;
mod paired_device;
mod paired_device_store;
mod paired_devices;
mod profile_store;
mod replica_lock;
mod run_marker;
mod state_dir;
mod stored_archive;

pub use archive_inventory::{ArchiveDeleteError, ArchiveInventory};
pub use archive_store::{
    ARCHIVE_SCHEMA_VERSION, ArchiveError, ArchiveHeader, ArchiveStore, ForeignHeader,
};
pub use certificate::{Certificate, CertificateError};
pub use device_identity::{DeviceIdentity, IdentityIssueError, IdentityPairError};
pub use device_identity_store::{DeviceIdentityStore, IdentityError};
pub use interface_addresses::interface_addresses;
pub use paired_device::{DifferentKey, PairedDevice};
pub use paired_device_store::{
    PAIRED_DEVICES_SCHEMA_VERSION, PairedDeviceStore, PairedDeviceStoreError,
};
pub use paired_devices::{PairedDevices, PairingError};
pub use profile_store::{ProfileStore, ProfileStoreError};
pub use replica_lock::{LockError, ReplicaLock};
pub use run_marker::RunMarker;
pub use state_dir::StateDir;
pub use stored_archive::StoredArchive;
