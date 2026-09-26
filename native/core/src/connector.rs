//! Turns a run's two locations into two replicas (SPEC §4.1, §4.4), for
//! the CLI and the hub alike: a location this process serves itself opens
//! a [`LocalReplica`]; `ssh` spawns the far side's agent over ssh's stdio;
//! `unix://` dials the socket an agent listens on; `peer://` dials a paired
//! device over pinned TLS. Which transport is the location's own
//! declaration; whether an unschemed `host:path` is this machine is
//! [`dsync_domain::Location::locality`]'s verdict.
//!
//! A remote side is given its root unexpanded: `~` is the far side's home.

use std::ffi::OsString;
use std::io;

use dsync_domain::host_port::PeerAddress;
use dsync_domain::{
    CertificateExpiry, DeviceId, EffectiveOptions, ExpandError, Locality, Location,
    ReplicaLocation, ReplicaSpec, Side, Tuning,
};

use crate::any_replica::AnyReplica;
use crate::archive_store::ArchiveError;
use crate::link_error::LinkError;
use crate::local_replica::LocalReplica;
use crate::peer_dialer::{PeerDialError, PeerDialer};
use crate::remote_replica::RemoteReplica;
use crate::replica::Replica;
use crate::ssh_transport::SshLaunch;
use crate::state_dir::StateDir;
use crate::symlinks::Symlinks;

/// Connects a run's locations, as this host.
pub struct Connector {
    state: StateDir,
    home: Option<String>,
    tuning: Tuning,
    local_addresses: Vec<String>,
    peers: Option<PeerDialer>,
    peer_address: Option<PeerAddress>,
    ssh_program: Option<OsString>,
}

/// Both sides of a run, connected, and what dialling learned about each
/// `peer://` one.
pub struct Connected {
    pub a: AnyReplica,
    pub b: AnyReplica,
    pub peers: Vec<PeerContact>,
}

/// A `peer://` side as its dial found it: the device, where it answered,
/// and the certificate notes the run header shows under it (SPEC §4.4).
#[derive(Clone, Debug)]
pub struct PeerContact {
    pub side: Side,
    pub device: DeviceId,
    pub address: PeerAddress,
    pub expiries: Vec<CertificateExpiry>,
}

/// One side could not be connected. Fatal for the run (SPEC §11.5 exit 3).
#[derive(Debug, thiserror::Error)]
#[error("replica {side}: {failure}")]
pub struct ConnectError {
    pub side: Side,
    #[source]
    pub failure: ConnectFailure,
}

#[derive(Debug, thiserror::Error)]
pub enum ConnectFailure {
    /// A local root spelled with a `~` on a host with no home.
    #[error(transparent)]
    Root(#[from] ExpandError),
    /// A local replica's archive could not be opened.
    #[error(transparent)]
    Archive(#[from] ArchiveError),
    /// An ssh or socket connection failed before it was up: ssh would not
    /// start, the far side did not speak the protocol, or it went away. An
    /// ssh failure carries what ssh printed.
    #[error(transparent)]
    Link(#[from] LinkError),
    /// Nothing listens at a `unix://` socket.
    #[error("no agent answers at {socket}: {source}")]
    Socket {
        socket: String,
        #[source]
        source: io::Error,
    },
    /// SPEC §4.4's distinct failures: not paired, unreachable at the
    /// address tried, the wrong device, a certificate out of date.
    #[error(transparent)]
    Peer(#[from] PeerDialError),
    /// A `peer://` side on a connector given no identity to dial with.
    #[error("peer:// locations need this host's device identity")]
    NoIdentity,
    #[error("unix:// sockets are not available on this platform")]
    NoUnixSockets,
}

impl ConnectFailure {
    /// Whether this failure says the device or transport is unreachable,
    /// so a profile's later entries - over the same one - would only fail
    /// the same way, each after its own timeout. A root or archive failure
    /// is the entry's own.
    pub fn ends_profile(&self) -> bool {
        match self {
            ConnectFailure::Root(_) | ConnectFailure::Archive(_) => false,
            ConnectFailure::Link(_)
            | ConnectFailure::Socket { .. }
            | ConnectFailure::Peer(_)
            | ConnectFailure::NoIdentity
            | ConnectFailure::NoUnixSockets => true,
        }
    }
}

impl Connector {
    /// Local replicas keep their archives and locks in `state`; `home`
    /// expands a local root's `~`.
    pub fn new(state: StateDir, home: Option<String>, tuning: Tuning) -> Connector {
        Connector {
            state,
            home,
            tuning,
            local_addresses: Vec::new(),
            peers: None,
            peer_address: None,
            ssh_program: None,
        }
    }

    /// This machine's names and addresses, for an unschemed `host:path`
    /// (fetch them only when [`Location::consults_local_addresses`] says).
    pub fn with_local_addresses(self, local_addresses: Vec<String>) -> Connector {
        Connector {
            local_addresses,
            ..self
        }
    }

    /// Dials `peer://` sides with `dialer`.
    pub fn with_peers(self, dialer: PeerDialer) -> Connector {
        Connector {
            peers: Some(dialer),
            ..self
        }
    }

    /// Dials a `peer://` side at `address` rather than where it was last
    /// reached.
    pub fn with_peer_address(self, address: PeerAddress) -> Connector {
        Connector {
            peer_address: Some(address),
            ..self
        }
    }

    /// Runs `program` in place of `ssh` (a test's stand-in).
    pub fn with_ssh_program(self, program: impl Into<OsString>) -> Connector {
        Connector {
            ssh_program: Some(program.into()),
            ..self
        }
    }

    /// Both sides, A first. A side that fails closes the one already
    /// connected before the failure is returned.
    pub async fn connect(&self, options: &EffectiveOptions) -> Result<Connected, ConnectError> {
        let (a, peer_a) = self.side(options, Side::A).await?;
        match self.side(options, Side::B).await {
            Ok((b, peer_b)) => Ok(Connected {
                a,
                b,
                peers: peer_a.into_iter().chain(peer_b).collect(),
            }),
            Err(error) => {
                let _ = a.close().await;
                Err(error)
            }
        }
    }

    async fn side(
        &self,
        options: &EffectiveOptions,
        side: Side,
    ) -> Result<(AnyReplica, Option<PeerContact>), ConnectError> {
        let replica_location = options.replica(side);
        let location = replica_location.to_location();
        let spec = ReplicaSpec {
            root: location.path().to_owned(),
            kind: options.kind(),
            as_path: options.as_path().cloned(),
            entry: options.entry_id.clone(),
            side,
            jobs: options.jobs.unwrap_or(self.tuning.scan_jobs),
        };
        let local = |replica| (replica, None);
        let connected = match (location.locality(&self.local_addresses), replica_location) {
            (Locality::InProcess, _) | (_, ReplicaLocation::Local(_)) => {
                self.open_local(&location, spec).await.map(local)
            }
            (Locality::Remote, ReplicaLocation::Ssh(ssh)) => {
                let mut launch = SshLaunch::new(options.ssh(side), ssh.user(), ssh.host());
                if let Some(program) = &self.ssh_program {
                    launch = launch.with_program(program.clone());
                }
                RemoteReplica::over_ssh(&launch, spec, &self.tuning)
                    .await
                    .map(|replica| local(AnyReplica::Remote(replica)))
                    .map_err(ConnectFailure::from)
            }
            (Locality::Remote, ReplicaLocation::Unix(unix)) => {
                self.dial_socket(unix.socket(), spec).await.map(local)
            }
            // Dialled by the device id the location was pinned to when it
            // was resolved (plan D7/OQ6), never by its cosmetic name: a
            // rename since then must not break this, and a different
            // device that has since taken the old name must never be
            // dialled in its place.
            (Locality::Remote, ReplicaLocation::Peer(_, device)) => match &self.peers {
                Some(dialer) => dialer
                    .dial(device, self.peer_address.clone(), spec)
                    .await
                    .map(|dialed| {
                        let contact = PeerContact {
                            side,
                            device: dialed.device,
                            address: dialed.address,
                            expiries: dialed.expiries,
                        };
                        (AnyReplica::Remote(dialed.replica), Some(contact))
                    })
                    .map_err(ConnectFailure::from),
                None => Err(ConnectFailure::NoIdentity),
            },
        };
        connected.map_err(|failure| ConnectError { side, failure })
    }

    async fn open_local(
        &self,
        location: &Location,
        spec: ReplicaSpec,
    ) -> Result<AnyReplica, ConnectFailure> {
        let root = location.expanded_path(self.home.as_deref())?;
        let state = self.state.clone();
        let tuning = self.tuning;
        // This host runs the run, so it owns both ends: its rules decide.
        let opening = tokio::task::spawn_blocking(move || {
            LocalReplica::open(
                root,
                state,
                spec.entry,
                spec.side,
                spec.jobs,
                tuning,
                Symlinks::AsRuled,
            )
        });
        match opening.await {
            Ok(opened) => Ok(AnyReplica::Local(opened?)),
            Err(error) => match error.try_into_panic() {
                Ok(panic) => std::panic::resume_unwind(panic),
                Err(_) => panic!("the runtime shut down while a replica opened"),
            },
        }
    }

    #[cfg(unix)]
    async fn dial_socket(
        &self,
        socket: &str,
        spec: ReplicaSpec,
    ) -> Result<AnyReplica, ConnectFailure> {
        let transport = crate::unix_transport::dial_unix(std::path::Path::new(socket))
            .await
            .map_err(|source| ConnectFailure::Socket {
                socket: socket.to_owned(),
                source,
            })?;
        Ok(AnyReplica::Remote(
            RemoteReplica::connect(transport, spec, &self.tuning).await?,
        ))
    }

    #[cfg(not(unix))]
    async fn dial_socket(&self, _: &str, _: ReplicaSpec) -> Result<AnyReplica, ConnectFailure> {
        Err(ConnectFailure::NoUnixSockets)
    }
}
