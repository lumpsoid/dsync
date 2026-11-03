//! `dsync-core`: the I/O core of dsync-in-Rust - stores, replicas (local and
//! remote), transport, server, pairing and run. It calls down into
//! `dsync-domain` for every decision and never decides for itself; this
//! crate only fetches facts and executes plans. Replaced the spike
//! (`native/spike`, crate `dsync-spike`) module by module; see SPEC.md.

mod any_replica;
mod archive_inventory;
mod archive_line;
mod archive_store;
pub mod atomic_write;
mod body;
mod case_folding;
mod certificate;
mod confinement;
mod connector;
mod cpu;
mod credit;
mod device_identity;
mod device_identity_store;
mod diagnostics_log;
mod enrolment_dialer;
mod enrolment_listener;
mod enrolment_message;
mod enrolment_token;
mod file_write;
mod filter_listing;
mod folder_access;
mod frame;
mod granted_roots;
mod inbound;
mod interface_addresses;
mod link_error;
mod live_sessions;
mod local_replica;
mod local_root;
mod paired_device;
mod paired_device_store;
mod paired_devices;
mod peer_dialer;
mod peer_event;
mod peer_listener;
mod peer_pin;
mod peer_preamble;
mod peer_sessions;
mod profile_run;
mod profile_store;
mod remote_replica;
mod replica;
mod replica_error;
mod replica_lock;
mod replica_server;
mod request_window;
mod rotating_file;
pub mod run;
mod run_history;
mod run_marker;
mod scan_pool;
mod scan_probe;
mod scan_session;
mod scanner;
mod served_reads;
mod session_token;
mod ssh_transport;
mod state_dir;
mod stored_archive;
mod symlinks;
mod transport;
mod unauthenticated_slots;
#[cfg(unix)]
mod unix_transport;
mod version_handshake;
mod wire;
mod write_error;
mod writer_pool;

pub use any_replica::AnyReplica;
pub use archive_inventory::{ArchiveDeleteError, ArchiveInventory};
pub use archive_store::{ARCHIVE_FORMAT_VERSION, ArchiveError, ArchiveHeader, ArchiveStore};
pub use body::{Body, BodyDropped, BodyError, BodySender, SourceMoved, body_channel};
pub use case_folding::probe_case_folding;
pub use certificate::{Certificate, CertificateError};
pub use connector::{ConnectError, ConnectFailure, Connected, Connector, PeerContact};
pub use device_identity::{DeviceIdentity, IdentityIssueError, IdentityPairError};
pub use device_identity_store::{DeviceIdentityStore, IdentityError};
pub use diagnostics_log::DiagnosticsLog;
pub use dsync_domain::{Stage, StageTime, WriteStats};
pub use enrolment_dialer::{EnrolError, EnrolmentDialer, read_pair_code};
pub use enrolment_listener::{
    EnrolmentBindError, EnrolmentEnd, EnrolmentEvent, EnrolmentListener, EnrolmentRefusal,
    PendingEnrolment,
};
pub use enrolment_message::{EnrolmentDenial, EnrolmentMessageError};
pub use enrolment_token::TokenRefusal;
pub use filter_listing::{UnlistableFolder, list_filter_folder, preview_filters_at};
pub use folder_access::{ACCESS_PROBE_NAME, FolderRefused, check_root_access};
pub use granted_roots::GrantedRoots;
pub use interface_addresses::interface_addresses;
pub use link_error::LinkError;
pub use local_replica::LocalReplica;
pub use local_root::{Root, RootError};
pub use paired_device::{DifferentKey, GrantNests, PairedDevice, resolve_grant};
pub use paired_device_store::{
    PAIRED_DEVICES_FORMAT_VERSION, PairedDeviceStore, PairedDeviceStoreError,
};
pub use paired_devices::{PairedDevices, PairingError};
pub use peer_dialer::{DialedPeer, PeerDialError, PeerDialer};
pub use peer_event::{PeerEvent, PeerRefusal};
pub use peer_listener::{GRANTS_NEST, NOT_GRANTED, PeerBindError, PeerListener, bind_peer};
pub use peer_pin::CertificateRefusal;
pub use peer_sessions::PeerSessions;
pub use profile_run::{
    EntryFailure, EntryOutcome, EntryReport, ListedEntry, ProfileEvent, ProfileReport, ProfileRun,
    ProfileStop, ReconnectCause, ResolvedOverlap, SkipReason,
};
pub use profile_store::{ProfileStore, ProfileStoreError};
pub use remote_replica::RemoteReplica;
pub use replica::{
    BucketTicket, DigestTicket, DigestedScan, OpenedScan, Reading, Replica, Settled,
};
pub use replica_error::{FileOp, ReplicaError};
pub use replica_lock::{LockError, ReplicaLock, canonical_root};
pub use replica_server::ReplicaServer;
pub use run::{
    ActionChoice, ActionFailure, BatchDecider, Compared, ConflictChoice, Decider, DryRunDecider,
    Peek, Recall, RowRecall, Run, RunError, RunEvent, RunReport, RunStop, Stopped,
};
pub use run_history::RunHistory;
pub use run_marker::RunMarker;
pub use scan_probe::ScanProbe;
pub use scan_session::ScanSession;
pub use scanner::{HASH_READ_BUFFER_BYTES, Scanner, UnreadableRoot};
pub use served_reads::ServedReads;
pub use ssh_transport::SshLaunch;
pub use state_dir::StateDir;
pub use stored_archive::StoredArchive;
pub use symlinks::Symlinks;
pub use transport::{Liveness, Transport};
#[cfg(unix)]
pub use unix_transport::{UnixBindError, bind_unix, dial_unix};
pub use version_handshake::PROTOCOL_VERSION;
pub use write_error::WriteError;
