//! The peer:// listener (SPEC §4.4): the engine behind `dsync agent
//! --serve` and the head's Serve page. Serves paired devices over mutual
//! TLS, each connection its own [`ReplicaServer`] session.
//!
//! Bounds hold before a peer has authenticated, so a stranger costs this
//! host at most a descriptor and a TLS session for a while: at most
//! [`Tuning::unauthenticated_connections`] connections mid-handshake, at
//! most [`Tuning::unauthenticated_per_address`] of them from one address
//! (past either, the next is closed at accept, before any TLS), each cut
//! off at [`Tuning::client_hello`] if it has not sent its whole hello and
//! at [`Tuning::handshake`] in all.
//!
//! After the handshake the authenticated key selects the paired device,
//! and its `hello` is held to that device's grants: the root, expanded as
//! the factory will expand it, must be one the device was granted, or the
//! session gets one generic refusal before the factory - and so the
//! filesystem - is reached. A missing, an unreadable and an ungranted root
//! cannot be told apart from the refusal, so a paired device cannot map
//! this host's filesystem by asking. A root it may open is opened bounded
//! by all its grants: a link is gone through only to a target inside one.

use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::SystemTime;

use dsync_domain::{DeviceId, HostFacts, ReplicaSpec, Tuning};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;
use tokio::time::Instant;
use tokio_rustls::LazyConfigAcceptor;
use tokio_rustls::server::TlsStream;

use crate::device_identity::DeviceIdentity;
use crate::granted_roots::GrantedRoots;
use crate::link_error::LinkError;
use crate::live_sessions::{LiveSession, LiveSessions};
use crate::paired_device::{PairedDevice, resolve_grant};
use crate::paired_device_store::PairedDeviceStore;
use crate::paired_devices::PairedDevices;
use crate::peer_event::{PeerEvent, PeerRefusal};
use crate::peer_pin::{CertificateRefusal, PeerPin, presented, server_config};
use crate::peer_preamble::{read_claim, write_draining, write_issued};
use crate::replica::Replica;
use crate::replica_error::ReplicaError;
use crate::replica_server::ReplicaServer;
use crate::served_reads::ServedReads;
use crate::spool_drain::SpoolDrain;
use crate::symlinks::Symlinks;
use crate::transport::{Liveness, Transport};
use crate::unauthenticated_slots::{SlotRefusal, UnauthenticatedSlot, UnauthenticatedSlots};

/// The one answer to a `hello` for a root the device may not reach -
/// whether it exists, is readable or is simply not granted.
pub const NOT_GRANTED: &str = "this device is not authorized to reach that replica";

/// The answer to a `hello` for a granted root while two of the device's
/// grants nest as this host resolves them now (a path moved or was
/// replaced by a link after granting). Given only after the root passed
/// the grant check, so it says nothing about roots not granted.
pub const GRANTS_NEST: &str =
    "this device's granted roots now overlap on this host; withdraw one to sync";

#[derive(Debug, thiserror::Error)]
#[error("cannot listen on {address}: {source}")]
pub struct PeerBindError {
    pub address: SocketAddr,
    #[source]
    pub source: io::Error,
}

/// Listens for peers on `address:port` ([`Tuning::peer_port`] by default,
/// the `--bind` address and `--port`).
pub async fn bind_peer(address: IpAddr, port: u16) -> Result<TcpListener, PeerBindError> {
    let address = SocketAddr::new(address, port);
    TcpListener::bind(address)
        .await
        .map_err(|source| PeerBindError { address, source })
}

/// Serves paired devices the replicas `open` opens, presenting
/// `identity`, and admitting whoever the paired-device store holds at the
/// moment each connection is accepted.
pub struct PeerListener<F> {
    open: Arc<F>,
    identity: DeviceIdentity,
    paired: PairedDeviceStore,
    home: Option<String>,
    tuning: Tuning,
    sessions: Arc<LiveSessions>,
    /// Shared by every session this listener serves (SPEC §4.2).
    reads: ServedReads,
}

impl<F, Opening, R> PeerListener<F>
where
    F: Fn(ReplicaSpec, Symlinks) -> Opening + Send + Sync + 'static,
    Opening: Future<Output = Result<R, ReplicaError>> + Send + 'static,
    R: Replica + 'static,
{
    /// `open` is the replica factory, as for [`ReplicaServer::new`] with
    /// the links the replica may go through beside the spec
    /// ([`Symlinks::WithinGrants`] of the connected device); it must
    /// expand the spec's root with [`ReplicaSpec::expanded_root`] against
    /// `host`'s home, the expansion the grant check uses.
    pub fn new(
        open: F,
        identity: DeviceIdentity,
        paired: PairedDeviceStore,
        host: &HostFacts,
        tuning: Tuning,
    ) -> PeerListener<F> {
        PeerListener {
            open: Arc::new(open),
            identity,
            paired,
            home: host.home().map(str::to_owned),
            tuning,
            sessions: Arc::default(),
            reads: ServedReads::new(&tuning),
        }
    }

    /// Serves every connection `listener` accepts, each its own session,
    /// concurrently, until accepting fails. Each connection's story goes
    /// to `events`; one failing does not stop the others.
    pub async fn serve(
        self: Arc<Self>,
        listener: TcpListener,
        events: impl Fn(PeerEvent) + Send + Sync + 'static,
    ) -> io::Result<()> {
        let events = Arc::new(events);
        let unauthenticated = UnauthenticatedSlots::new(&self.tuning);
        loop {
            let (stream, from) = listener.accept().await?;
            // Taken here, in accept order, so the connection over a cap is
            // the one refused, before it costs a task or any TLS.
            let slot = match unauthenticated.admit(from.ip()) {
                Ok(slot) => slot,
                Err(refusal) => {
                    drop(stream);
                    let why = match refusal {
                        SlotRefusal::OverCapacity { limit } => PeerRefusal::OverCapacity { limit },
                        SlotRefusal::OverAddressCapacity { limit } => {
                            PeerRefusal::OverAddressCapacity { limit }
                        }
                    };
                    events(PeerEvent::Refused { from, why });
                    continue;
                }
            };
            let (served, events) = (self.clone(), events.clone());
            tokio::spawn(async move {
                if let Err(error) = stream.set_nodelay(true) {
                    let why = PeerRefusal::Handshake(error);
                    return events(PeerEvent::Refused { from, why });
                }
                let authenticated = served.authenticate(stream, slot).await;
                let (mut tls, device) = match authenticated {
                    Ok(authenticated) => authenticated,
                    Err(why) => return events(PeerEvent::Refused { from, why }),
                };
                let (id, name) = (device.device_id(), device.name().clone());
                events(PeerEvent::Started {
                    from,
                    device: id,
                    name: name.clone(),
                });
                let failed = {
                    let (events, name) = (events.clone(), name.clone());
                    move |error: &ReplicaError| {
                        events(PeerEvent::Failed {
                            from,
                            device: id,
                            name: name.clone(),
                            failure: error.to_string(),
                        });
                    }
                };
                let (open, home) = (served.open.clone(), served.home.clone());
                let symlinks = Symlinks::WithinGrants(GrantedRoots::of(&device));
                // `open` is reached only for a root `device` was granted,
                // while its grants do not nest.
                let session = ReplicaServer::new(
                    move |spec: ReplicaSpec| {
                        let granted = device.serves_spec(&spec, home.as_deref());
                        let (device, open, symlinks) =
                            (device.clone(), open.clone(), symlinks.clone());
                        async move {
                            if !granted {
                                return Err(ReplicaError::Refused(NOT_GRANTED.to_owned()));
                            }
                            if grants_nest(device).await {
                                return Err(ReplicaError::Refused(GRANTS_NEST.to_owned()));
                            }
                            open(spec, symlinks).await
                        }
                    },
                    served.tuning,
                    served.reads.clone(),
                )
                .reporting(failed);
                // Registered before the reclaim, so this session's token
                // can never be the one it ends.
                let live = served.sessions.register(id);
                let session = session.publishing_drain(live.drain_publisher());
                let outcome = match served.claimed(&mut tls, &live, id).await {
                    Ok(()) => {
                        let transport =
                            Transport::split(tls).with_liveness(Liveness::of(&served.tuning));
                        session.serve_until(transport, live.ended()).await
                    }
                    Err(error) => Err(error),
                };
                drop(session);
                drop(live);
                events(PeerEvent::Ended {
                    from,
                    device: id,
                    name,
                    outcome,
                });
            });
        }
    }

    /// The preamble (SPEC §4.2): reads the dialer's claim under the
    /// handshake deadline; if it names a session of the dialer's own that
    /// is still live here, ends it and waits for it to let go of its
    /// replica, so the claimant's lock finds it free; then issues `live`'s
    /// token. While the ended session's spool is busy - anything queued or
    /// on a writer, whether the session has reached its settle or is
    /// still joining a request that waits on a landing - the dialer is
    /// told so every [`Tuning::heartbeat`] with a `Draining` frame: the
    /// dialer bounds that wait, and a dialer gone fails the next frame. A
    /// session not busy - no spool, or done landing - is waited on at most
    /// [`Tuning::reclaim_wait`] from the first sample that found it so,
    /// checked each heartbeat.
    async fn claimed<S>(
        &self,
        tls: &mut S,
        live: &LiveSession,
        device: DeviceId,
    ) -> Result<(), LinkError>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let handshake = self.tuning.handshake;
        let claim = tokio::time::timeout(handshake, read_claim(tls))
            .await
            .map_err(|_| timed_out())??;
        let ending = claim.and_then(|claim| self.sessions.end(&claim, device));
        if let Some(mut ending) = ending {
            // When a sample first found the session not busy; busy again
            // starts it over.
            let mut idle_since = None;
            let mut waited_out = |drain: SpoolDrain| {
                let now = Instant::now();
                if drain.busy {
                    idle_since = None;
                    return false;
                }
                now.duration_since(*idle_since.get_or_insert(now)) >= self.tuning.reclaim_wait
            };
            if !waited_out(ending.drain()) {
                while !ending.gone_within(self.tuning.heartbeat).await {
                    let drain = ending.drain();
                    if waited_out(drain) {
                        break;
                    }
                    tokio::time::timeout(handshake, write_draining(tls, drain.queued_bytes))
                        .await
                        .map_err(|_| timed_out())??;
                }
            }
        }
        tokio::time::timeout(handshake, write_issued(tls, live.token()))
            .await
            .map_err(|_| timed_out())??;
        Ok(())
    }

    /// The TLS handshake against the paired set as it is now, under the
    /// deadlines - the hello's, inside the whole handshake's - holding
    /// `slot` until it is done either way.
    async fn authenticate<S>(
        &self,
        stream: S,
        slot: UnauthenticatedSlot,
    ) -> Result<(TlsStream<S>, PairedDevice), PeerRefusal>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let paired = self.paired.load().map_err(PeerRefusal::Store)?;
        let pin = PeerPin::new(paired.iter().map(PairedDevice::device_id));
        let config = server_config(&self.identity, pin.clone())
            .map_err(|error| PeerRefusal::Handshake(io::Error::other(error)))?;
        let accepting = async {
            let hello = LazyConfigAcceptor::new(rustls::server::Acceptor::default(), stream);
            let limit = self.tuning.client_hello;
            let started = match tokio::time::timeout(limit, hello).await {
                Err(_) => return Err(PeerRefusal::HelloTimedOut { limit }),
                Ok(Err(error)) => return Err(self.why_refused(&pin, &paired, error)),
                Ok(Ok(started)) => started,
            };
            (started.into_stream(Arc::new(config)).await)
                .map_err(|error| self.why_refused(&pin, &paired, error))
        };
        let accepted = tokio::time::timeout(self.tuning.handshake, accepting).await;
        drop(slot);
        let tls = accepted.map_err(|_| PeerRefusal::HandshakeTimedOut {
            limit: self.tuning.handshake,
        })??;
        let device = presented(tls.get_ref().1)
            .and_then(|certificate| paired.get(&certificate.device_id()).cloned())
            .ok_or_else(|| {
                PeerRefusal::Handshake(io::Error::other("no admitted certificate after TLS"))
            })?;
        Ok((tls, device))
    }

    /// A failed handshake, named: what the pin refused, else this host's
    /// own certificate if that is out of date (the peer refused it), else
    /// the TLS error itself.
    fn why_refused(&self, pin: &PeerPin, paired: &PairedDevices, error: io::Error) -> PeerRefusal {
        match pin.refusal() {
            Some(CertificateRefusal::NotPinned(_)) if paired.is_empty() => {
                PeerRefusal::NoDevicesPaired
            }
            Some(refusal) => PeerRefusal::Certificate(refusal),
            None => match self
                .identity
                .certificate()
                .validity()
                .check_at(SystemTime::now())
            {
                Err(breach) => PeerRefusal::OwnCertificate(breach),
                Ok(()) => PeerRefusal::Handshake(error),
            },
        }
    }
}

/// A preamble step that ran past the handshake deadline.
fn timed_out() -> LinkError {
    LinkError::from(io::Error::from(io::ErrorKind::TimedOut))
}

/// Whether two of `device`'s grants nest as this host resolves them now,
/// resolved off the executor since it asks the filesystem.
async fn grants_nest(device: PairedDevice) -> bool {
    let resolving =
        tokio::task::spawn_blocking(move || device.nesting_grants(resolve_grant).is_some());
    match resolving.await {
        Ok(nest) => nest,
        Err(error) => match error.try_into_panic() {
            Ok(panic) => std::panic::resume_unwind(panic),
            Err(_) => panic!("the runtime shut down while a device's grants resolved"),
        },
    }
}

#[cfg(test)]
mod tests {
    //! The handshake deadline under a paused clock, over an in-memory
    //! stream (real sockets and a paused clock race: the clock can jump
    //! before the kernel's readiness is polled). The listener around it is
    //! `tests/peer`'s.

    use std::time::Duration;

    use tokio::io::{AsyncReadExt, AsyncWriteExt, duplex};
    use tokio::time::Instant;

    use super::*;
    use crate::local_replica::LocalReplica;
    use crate::peer_preamble::Preamble;
    use crate::session_token::SessionToken;
    use crate::state_dir::StateDir;
    use crate::version_handshake::{PROTOCOL_VERSION, handshake, version_frame};
    use tokio::io::BufReader;

    type Open = fn(ReplicaSpec, Symlinks) -> std::future::Ready<Result<LocalReplica, ReplicaError>>;

    fn listener(state: &StateDir) -> PeerListener<Open> {
        let identity = DeviceIdentity::generate("desktop", SystemTime::now()).unwrap();
        let host = HostFacts::new(dsync_domain::Platform::HOST, None, Vec::new(), "/".into());
        let refuse: Open = |_, _| std::future::ready(Err(ReplicaError::Refused("unused".into())));
        PeerListener::new(
            refuse,
            identity,
            PairedDeviceStore::new(state),
            &host,
            Tuning::DEFAULT,
        )
    }

    const FROM: IpAddr = IpAddr::V4(std::net::Ipv4Addr::LOCALHOST);

    fn slot() -> UnauthenticatedSlot {
        UnauthenticatedSlots::new(&Tuning::DEFAULT)
            .admit(FROM)
            .unwrap()
    }

    fn cut(refused: Result<impl Sized, PeerRefusal>) -> Option<Duration> {
        match refused {
            Err(PeerRefusal::HandshakeTimedOut { limit }) => Some(limit),
            _ => None,
        }
    }

    /// Cut at the hello's deadline, well inside the handshake's, and its
    /// slot is free again from that instant.
    #[tokio::test(start_paused = true)]
    async fn a_peer_that_never_speaks_is_cut_at_the_hello_deadline_and_frees_its_slot() {
        let dir = tempfile::tempdir().unwrap();
        let listener = listener(&StateDir::new(dir.path()));
        let only = UnauthenticatedSlots::new(&Tuning {
            unauthenticated_connections: 1,
            ..Tuning::DEFAULT
        });
        let held = only.admit(FROM).unwrap();
        assert!(only.admit(FROM).is_err(), "the one slot is held");
        let (_client, server) = duplex(64 * 1024);
        let started = Instant::now();
        let refused = listener.authenticate(server, held).await;
        assert_eq!(started.elapsed(), Tuning::DEFAULT.client_hello);
        assert!(
            matches!(refused, Err(PeerRefusal::HelloTimedOut { limit }) if limit == Tuning::DEFAULT.client_hello),
            "{:?}",
            refused.err()
        );
        assert!(only.admit(FROM).is_ok(), "the slot came back");
    }

    /// Part of a hello is no hello: a peer that sends one byte and stalls
    /// is cut at the same deadline.
    #[tokio::test(start_paused = true)]
    async fn a_peer_that_stalls_inside_its_hello_is_cut_at_the_hello_deadline() {
        let dir = tempfile::tempdir().unwrap();
        let listener = listener(&StateDir::new(dir.path()));
        let (mut client, server) = duplex(64 * 1024);
        // A TLS handshake record's first byte.
        client.write_all(&[0x16]).await.unwrap();
        let started = Instant::now();
        let refused = listener.authenticate(server, slot()).await;
        assert_eq!(started.elapsed(), Tuning::DEFAULT.client_hello);
        assert!(
            matches!(refused, Err(PeerRefusal::HelloTimedOut { .. })),
            "{:?}",
            refused.err()
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_peer_that_stalls_after_its_first_flight_is_cut_at_the_deadline() {
        let dir = tempfile::tempdir().unwrap();
        let listener = listener(&StateDir::new(dir.path()));
        let (mut client, server) = duplex(64 * 1024);
        let config = Arc::new(
            rustls::ClientConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .dangerous()
            .with_custom_certificate_verifier(PeerPin::new([]))
            .with_no_client_auth(),
        );
        let mut hello = Vec::new();
        rustls::ClientConnection::new(config, crate::peer_pin::server_name())
            .unwrap()
            .write_tls(&mut hello)
            .unwrap();
        client.write_all(&hello).await.unwrap();

        let started = Instant::now();
        let (refused, answered) = tokio::join!(listener.authenticate(server, slot()), async {
            let mut answer = [0u8; 1];
            client.read(&mut answer).await.unwrap()
        });
        assert_eq!(answered, 1, "the listener answered the hello");
        assert_eq!(started.elapsed(), Tuning::DEFAULT.handshake);
        assert_eq!(cut(refused), Some(Tuning::DEFAULT.handshake));
    }

    /// Positive control for all three: the same stream and clock, a peer that
    /// completes nothing but closes, is refused at once - not at the
    /// deadline.
    #[tokio::test(start_paused = true)]
    async fn a_peer_that_hangs_up_is_refused_at_once() {
        let dir = tempfile::tempdir().unwrap();
        let listener = listener(&StateDir::new(dir.path()));
        let (client, server) = duplex(64 * 1024);
        drop(client);
        let started = Instant::now();
        let refused = listener.authenticate(server, slot()).await;
        assert_eq!(started.elapsed(), Duration::ZERO);
        assert!(matches!(refused, Err(PeerRefusal::Handshake(_))));
    }

    fn phone() -> DeviceId {
        DeviceId::from_spki_der(&[1])
    }

    /// The bytes a listener wrote, split into its preamble frames, in
    /// order, and whatever followed them.
    async fn frames(written: &[u8]) -> (Vec<Preamble>, Vec<u8>) {
        let mut rest = written;
        let mut frames = Vec::new();
        while rest.starts_with(b"dsync-ps") {
            frames.push(Preamble::read_from(&mut rest).await.unwrap());
        }
        (frames, rest.to_vec())
    }

    /// A dialer claiming `claim` against `listener`, its version frame
    /// sent straight after, as `PeerDialer` would; the listener's half
    /// served for `live`, then the version exchange. How the preamble
    /// ended, how long it took, and every byte the listener wrote.
    async fn dial(
        listener: &PeerListener<Open>,
        live: &LiveSession,
        claim: Option<SessionToken>,
    ) -> (Result<(), LinkError>, Duration, Vec<u8>) {
        let (mut dialer, far) = duplex(64 * 1024);
        Preamble::Claim { reclaim: claim }
            .write_to(&mut dialer)
            .await
            .unwrap();
        version_frame(PROTOCOL_VERSION)
            .write_to(&mut dialer)
            .await
            .unwrap();
        let started = Instant::now();
        let serving = async {
            let mut far = far;
            let claimed = listener.claimed(&mut far, live, phone()).await;
            let took = started.elapsed();
            if claimed.is_ok() {
                let (read, mut write) = tokio::io::split(&mut far);
                handshake(&mut BufReader::new(read), &mut write)
                    .await
                    .unwrap();
            }
            (claimed, took)
        };
        let reading = async {
            let mut written = Vec::new();
            dialer.read_to_end(&mut written).await.unwrap();
            written
        };
        let ((claimed, took), written) = tokio::join!(serving, reading);
        (claimed, took, written)
    }

    /// This build's version frame, as the listener writes it.
    async fn version_bytes() -> Vec<u8> {
        let mut bytes = Vec::new();
        version_frame(PROTOCOL_VERSION)
            .write_to(&mut bytes)
            .await
            .unwrap();
        bytes
    }

    /// Publishes a probe for `session` that samples what the test sets.
    fn probed(session: &LiveSession, drain: SpoolDrain) -> tokio::sync::watch::Sender<SpoolDrain> {
        let (set, now) = tokio::sync::watch::channel(drain);
        let probe: crate::spool_drain::DrainProbe = Arc::new(move || Some(*now.borrow()));
        session.drain_publisher().send_replace(Some(probe));
        set
    }

    fn busy(queued_bytes: u64) -> SpoolDrain {
        SpoolDrain {
            queued_bytes,
            busy: true,
        }
    }

    /// A served session that, once ended, goes through `steps` - each
    /// drain held for its time - and then goes.
    fn draining(session: LiveSession, steps: Vec<(SpoolDrain, Duration)>) {
        let ended = session.ended();
        // As it stands when the claim ends it, before its task first runs.
        let set = probed(&session, steps[0].0);
        tokio::spawn(async move {
            ended.await;
            for (drain, held) in steps {
                set.send_replace(drain);
                tokio::time::sleep(held).await;
            }
            drop(session);
        });
    }

    fn draining_frames(frames: &[Preamble]) -> Vec<u64> {
        frames
            .iter()
            .filter_map(|frame| match frame {
                Preamble::Draining { queued_bytes } => Some(*queued_bytes),
                _ => None,
            })
            .collect()
    }

    /// V15: on the wire, a reclaim of a draining session is the dialer's
    /// claim, then the listener's `Draining` frames every heartbeat, then
    /// `Issued` once the session has gone, then the version frame - and
    /// nothing preamble-shaped after `Issued`.
    #[tokio::test(start_paused = true)]
    async fn a_reclaim_drains_before_it_issues_and_then_only_the_version_frame_follows() {
        let dir = tempfile::tempdir().unwrap();
        let listener = listener(&StateDir::new(dir.path()));
        let old = listener.sessions.register(phone());
        let claim = old.token().clone();
        let seven = Duration::from_secs(7);
        draining(
            old,
            vec![(busy(300), seven), (busy(200), seven), (busy(100), seven)],
        );
        let live = listener.sessions.register(phone());
        let (claimed, took, written) = dial(&listener, &live, Some(claim)).await;
        claimed.unwrap();
        // Gone at 21 s; a frame at each heartbeat before that.
        assert_eq!(took, Duration::from_secs(21));
        let (frames, rest) = frames(&written).await;
        let queued = draining_frames(&frames);
        assert_eq!(queued, [300, 200, 100, 100]);
        // Every Draining first, then the one Issued last.
        assert_eq!(frames.len(), queued.len() + 1, "{frames:?}");
        assert!(
            matches!(frames.last(), Some(Preamble::Issued { token }) if token.is(live.token())),
            "{frames:?}"
        );
        assert_eq!(rest, version_bytes().await);
    }

    /// A claimed session with nothing queued is waited on at most
    /// `reclaim_wait`, and the dialer hears nothing but `Issued`.
    #[tokio::test(start_paused = true)]
    async fn a_claimed_session_with_nothing_queued_is_waited_on_only_so_long() {
        let dir = tempfile::tempdir().unwrap();
        let listener = listener(&StateDir::new(dir.path()));
        let stuck = listener.sessions.register(phone());
        let live = listener.sessions.register(phone());
        let (claimed, took, written) = dial(&listener, &live, Some(stuck.token().clone())).await;
        claimed.unwrap();
        assert_eq!(took, Tuning::DEFAULT.reclaim_wait);
        let (frames, rest) = frames(&written).await;
        assert!(
            matches!(frames.as_slice(), [Preamble::Issued { .. }]),
            "{frames:?}"
        );
        assert_eq!(rest, version_bytes().await);
        drop(stuck);
    }

    /// Nothing left to hand a writer is not done: a session whose last
    /// landings are still on their writers - `queued_bytes` 0, busy - is
    /// waited on until it goes, far past `reclaim_wait`, and the dialer is
    /// told it is draining meanwhile.
    #[tokio::test(start_paused = true)]
    async fn a_session_busy_with_nothing_queued_is_waited_on_until_it_goes() {
        let dir = tempfile::tempdir().unwrap();
        let listener = listener(&StateDir::new(dir.path()));
        let old = listener.sessions.register(phone());
        let claim = old.token().clone();
        draining(old, vec![(busy(0), Duration::from_secs(23))]);
        let live = listener.sessions.register(phone());
        let (claimed, took, written) = dial(&listener, &live, Some(claim)).await;
        claimed.unwrap();
        assert_eq!(took, Duration::from_secs(23));
        let (frames, _) = frames(&written).await;
        assert_eq!(draining_frames(&frames), [0, 0, 0, 0]);
    }

    /// A session that stops being busy just before a heartbeat still gets
    /// all of `reclaim_wait` from the sample that first found it so.
    #[tokio::test(start_paused = true)]
    async fn the_wait_after_a_drain_counts_from_the_first_idle_sample() {
        let dir = tempfile::tempdir().unwrap();
        let listener = listener(&StateDir::new(dir.path()));
        let old = listener.sessions.register(phone());
        let claim = old.token().clone();
        let heartbeat = Tuning::DEFAULT.heartbeat;
        // Busy until just before the first heartbeat, then idle for good,
        // its lock still held.
        draining(
            old,
            vec![
                (busy(100), heartbeat - Duration::from_millis(100)),
                (SpoolDrain::default(), Duration::from_secs(3600)),
            ],
        );
        let live = listener.sessions.register(phone());
        let (claimed, took, written) = dial(&listener, &live, Some(claim)).await;
        claimed.unwrap();
        assert_eq!(took, heartbeat + Tuning::DEFAULT.reclaim_wait);
        let (frames, _) = frames(&written).await;
        assert_eq!(draining_frames(&frames), [0]);
    }

    /// A dial that claims nothing is issued at once while another session
    /// of the same device drains, and ends nothing.
    #[tokio::test(start_paused = true)]
    async fn a_dial_without_a_claim_does_not_wait_on_a_drain() {
        let dir = tempfile::tempdir().unwrap();
        let listener = listener(&StateDir::new(dir.path()));
        let old = listener.sessions.register(phone());
        let ended = old.ended();
        let _drain = probed(&old, busy(300));
        let live = listener.sessions.register(phone());
        let (claimed, took, written) = dial(&listener, &live, None).await;
        claimed.unwrap();
        assert_eq!(took, Duration::ZERO);
        let (frames, _) = frames(&written).await;
        assert!(
            matches!(frames.as_slice(), [Preamble::Issued { .. }]),
            "{frames:?}"
        );
        assert!(
            tokio::time::timeout(Duration::ZERO, ended).await.is_err(),
            "the drained session was not ended"
        );
    }

    /// A paired dialer that never sends its claim holds the listener only
    /// to the handshake deadline.
    #[tokio::test(start_paused = true)]
    async fn a_dialer_that_never_claims_is_cut_at_the_handshake_deadline() {
        let dir = tempfile::tempdir().unwrap();
        let listener = listener(&StateDir::new(dir.path()));
        let live = listener.sessions.register(phone());
        let (_dialer, mut far) = duplex(64 * 1024);
        let started = Instant::now();
        let claimed = listener.claimed(&mut far, &live, phone()).await;
        assert_eq!(started.elapsed(), Tuning::DEFAULT.handshake);
        assert!(claimed.is_err());
    }

    /// A dialer that gives up on a drain fails the listener's next
    /// `Draining` write: the listener does not wait on for nobody.
    #[tokio::test(start_paused = true)]
    async fn a_dialer_gone_mid_drain_ends_the_wait_at_the_next_frame() {
        let dir = tempfile::tempdir().unwrap();
        let listener = listener(&StateDir::new(dir.path()));
        let stuck = listener.sessions.register(phone());
        let _drain = probed(&stuck, busy(300));
        let live = listener.sessions.register(phone());
        let (mut dialer, mut far) = duplex(64 * 1024);
        Preamble::Claim {
            reclaim: Some(stuck.token().clone()),
        }
        .write_to(&mut dialer)
        .await
        .unwrap();
        let started = Instant::now();
        let (claimed, ()) = tokio::join!(listener.claimed(&mut far, &live, phone()), async {
            assert!(matches!(
                Preamble::read_from(&mut dialer).await.unwrap(),
                Preamble::Draining { queued_bytes: 300 }
            ));
            drop(dialer);
        });
        assert!(claimed.is_err());
        assert_eq!(started.elapsed(), 2 * Tuning::DEFAULT.heartbeat);
        drop(stuck);
    }
}
