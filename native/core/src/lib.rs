//! `dsync-core`: the I/O core of dsync-in-Rust - stores, replicas (local and
//! remote), transport, server, pairing and run. It calls down into
//! `dsync-domain` for every decision and never decides for itself; this
//! crate only fetches facts and executes plans. Replaces the spike
//! (`native/spike`, crate `dsync-spike`) module by module; see
//! native/NOTES.md.

mod any_replica;
mod archive_inventory;
mod archive_line;
mod archive_store;
pub mod atomic_write;
mod body;
mod case_folding;
mod certificate;
mod connector;
mod cpu;
mod device_identity;
mod device_identity_store;
mod enrolment_dialer;
mod enrolment_listener;
mod enrolment_message;
mod enrolment_token;
mod file_write;
mod filter_listing;
mod frame;
mod inbound;
mod interface_addresses;
mod link_error;
mod local_replica;
mod paired_device;
mod paired_device_store;
mod paired_devices;
mod peer_dialer;
mod peer_event;
mod peer_listener;
mod peer_pin;
mod profile_store;
mod remote_replica;
mod replica;
mod replica_error;
mod replica_lock;
mod replica_server;
mod request_window;
pub mod run;
mod run_marker;
mod scan_pool;
mod scan_probe;
mod scan_session;
mod scanner;
mod ssh_transport;
mod state_dir;
mod stored_archive;
mod transport;
#[cfg(unix)]
mod unix_transport;
mod version_handshake;
mod wire;
mod write_error;
mod writer_pool;

pub use any_replica::AnyReplica;
pub use archive_inventory::{ArchiveDeleteError, ArchiveInventory};
pub use archive_store::{
    ARCHIVE_SCHEMA_VERSION, ArchiveError, ArchiveHeader, ArchiveStore, ForeignHeader,
};
pub use body::{Body, BodyDropped, BodyError, BodySender, body_channel};
pub use case_folding::probe_case_folding;
pub use certificate::{Certificate, CertificateError};
pub use connector::{ConnectError, ConnectFailure, Connector};
pub use device_identity::{DeviceIdentity, IdentityIssueError, IdentityPairError};
pub use device_identity_store::{DeviceIdentityStore, IdentityError};
pub use dsync_domain::{Stage, StageTime, WriteStats};
pub use enrolment_dialer::{EnrolError, EnrolmentDialer, read_pair_code};
pub use enrolment_listener::{
    EnrolmentBindError, EnrolmentEnd, EnrolmentEvent, EnrolmentListener, EnrolmentRefusal,
    PendingEnrolment,
};
pub use enrolment_message::{EnrolmentDenial, EnrolmentMessageError};
pub use enrolment_token::TokenRefusal;
pub use filter_listing::{UnlistableFolder, list_filter_folder, preview_filters_at};
pub use interface_addresses::interface_addresses;
pub use link_error::LinkError;
pub use local_replica::LocalReplica;
pub use paired_device::{DifferentKey, PairedDevice};
pub use paired_device_store::{
    PAIRED_DEVICES_SCHEMA_VERSION, PairedDeviceStore, PairedDeviceStoreError,
};
pub use paired_devices::{PairedDevices, PairingError};
pub use peer_dialer::{DialedPeer, PeerDialError, PeerDialer};
pub use peer_event::{PeerEvent, PeerRefusal};
pub use peer_listener::{NOT_GRANTED, PeerBindError, PeerListener, bind_peer};
pub use peer_pin::CertificateRefusal;
pub use profile_store::{ProfileStore, ProfileStoreError};
pub use remote_replica::RemoteReplica;
pub use replica::{BucketTicket, DigestTicket, DigestedScan, OpenedScan, Replica};
pub use replica_error::{FileOp, ReplicaError};
pub use replica_lock::{LockError, ReplicaLock};
pub use replica_server::ReplicaServer;
pub use run::{
    ActionFailure, BatchDecider, Decider, DryRunDecider, Run, RunError, RunEvent, RunReport,
    RunStop, Stopped,
};
pub use run_marker::RunMarker;
pub use scan_probe::ScanProbe;
pub use scan_session::ScanSession;
pub use scanner::{HASH_READ_BUFFER_BYTES, Scanner, UnreadableRoot};
pub use ssh_transport::SshLaunch;
pub use state_dir::StateDir;
pub use stored_archive::StoredArchive;
pub use transport::{Liveness, Transport};
#[cfg(unix)]
pub use unix_transport::{UnixBindError, bind_unix, dial_unix};
pub use version_handshake::PROTOCOL_VERSION;
pub use write_error::WriteError;
