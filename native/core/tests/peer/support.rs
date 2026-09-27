//! Fixtures for the peer:// tests: hosts with their own state dir,
//! identity and paired-device store; a listener serving one of them over
//! loopback; and a raw TLS client for what the dialer will not do (present
//! an out-of-date certificate, or none, or stall mid-handshake).

use std::fs;
use std::future::Future;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, SystemTime};

use dsync_core::{
    DeviceIdentity, DialedPeer, LocalReplica, PairedDevice, PairedDeviceStore, PeerDialError,
    PeerDialer, PeerEvent, PeerListener, ReplicaError, StateDir, Symlinks, bind_peer,
    resolve_grant,
};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{EntryId, HostFacts, Jobs, PeerName, Platform, ReplicaSpec, Side, Tuning};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{WebPkiSupportedAlgorithms, ring};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use tempfile::TempDir;
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio_rustls::TlsConnector;
use tokio_rustls::client::TlsStream;

/// Every real-time async test's own deadline: a few seconds, far above
/// what any of them takes.
pub const DEADLINE: Duration = Duration::from_secs(5);

pub async fn with_deadline<T>(label: &str, work: impl Future<Output = T>) -> T {
    tokio::time::timeout(DEADLINE, work)
        .await
        .unwrap_or_else(|_| panic!("{label} did not finish within {DEADLINE:?}"))
}

pub const PROFILE: &str = "0123456789abcdef0123456789abcdef";
pub const HOUR: Duration = Duration::from_secs(60 * 60);
pub const YEAR: Duration = Duration::from_secs(365 * 24 * 60 * 60);

pub fn name(text: &str) -> PeerName {
    PeerName::parse(text).unwrap()
}

/// A fresh identity valid now.
pub fn identity(common_name: &str) -> DeviceIdentity {
    DeviceIdentity::generate(common_name, SystemTime::now()).unwrap()
}

/// An identity issued at `at`: long expired for a date ten years back,
/// not yet valid for one more than an hour ahead.
pub fn identity_issued(common_name: &str, at: SystemTime) -> DeviceIdentity {
    DeviceIdentity::generate(common_name, at).unwrap()
}

pub fn expired(common_name: &str) -> DeviceIdentity {
    identity_issued(common_name, SystemTime::now() - 11 * YEAR)
}

pub fn not_yet_valid(common_name: &str) -> DeviceIdentity {
    identity_issued(common_name, SystemTime::now() + 2 * HOUR)
}

/// One installation: a temp dir holding its state dir and its replica
/// roots, its identity and its paired-device store.
pub struct Host {
    dir: TempDir,
    pub identity: DeviceIdentity,
}

impl Host {
    pub fn new(identity: DeviceIdentity) -> Host {
        Host {
            dir: tempfile::tempdir().unwrap(),
            identity,
        }
    }

    pub fn state(&self) -> StateDir {
        StateDir::new(self.dir.path().join("state"))
    }

    pub fn store(&self) -> PairedDeviceStore {
        PairedDeviceStore::new(&self.state())
    }

    /// A replica root under this host's temp dir (not created).
    pub fn root(&self, leaf: &str) -> PathBuf {
        self.dir.path().join(leaf)
    }

    /// `home` for root expansion: the temp dir itself.
    pub fn home(&self) -> &Path {
        self.dir.path()
    }

    /// Pairs `peer` as `label`, reached at `address`, granted `roots`.
    pub fn pair(&self, peer: &DeviceIdentity, label: &str, address: PeerAddress, roots: &[&Path]) {
        let mut device = PairedDevice::new(
            peer.certificate().clone(),
            name(label),
            address,
            SystemTime::now(),
        );
        for root in roots {
            device
                .grant(root.to_str().unwrap().to_owned(), resolve_grant)
                .unwrap();
        }
        self.store().update(|devices| devices.add(device)).unwrap();
    }

    pub fn revoke(&self, peer: &DeviceIdentity) {
        self.store()
            .update(|devices| devices.revoke(&peer.device_id()).map(|_| ()))
            .unwrap();
    }

    pub fn paired(&self, label: &str) -> PairedDevice {
        self.store()
            .load()
            .unwrap()
            .by_name(&name(label))
            .unwrap()
            .clone()
    }

    pub fn dialer(&self) -> PeerDialer {
        PeerDialer::new(self.identity.clone(), self.store(), Tuning::DEFAULT)
    }

    /// Dials the device paired here as `label`, resolving it to its id
    /// first - as a caller who read `label` off a profile would.
    pub async fn dial(
        &self,
        label: &str,
        at: Option<SocketAddr>,
        root: &str,
    ) -> Result<DialedPeer, PeerDialError> {
        let address = at.map(|at| PeerAddress::new(&at.ip().to_string(), at.port()).unwrap());
        let id = self.paired(label).device_id();
        self.dialer().dial(&id, address, spec(root)).await
    }
}

pub fn spec(root: &str) -> ReplicaSpec {
    ReplicaSpec {
        root: root.to_owned(),
        kind: dsync_domain::RootKind::Folder,
        as_path: None,
        entry: EntryId::parse(PROFILE).unwrap(),
        side: Side::B,
        jobs: Jobs::DEFAULT,
    }
}

/// An address nothing is listening at yet (for pairing records the
/// tests override or never dial).
pub fn somewhere() -> PeerAddress {
    PeerAddress::new("127.0.0.1", 9).unwrap()
}

pub fn address_of(at: SocketAddr) -> PeerAddress {
    PeerAddress::new(&at.ip().to_string(), at.port()).unwrap()
}

type Opening = Pin<Box<dyn Future<Output = Result<LocalReplica, ReplicaError>> + Send>>;

/// A listener serving `host` on loopback: its address, the events it
/// reports, how many times its replica factory ran, and its task.
pub struct Serving {
    pub at: SocketAddr,
    pub events: mpsc::UnboundedReceiver<PeerEvent>,
    pub opened: Arc<AtomicUsize>,
    task: JoinHandle<std::io::Result<()>>,
}

impl Serving {
    pub fn opened(&self) -> usize {
        self.opened.load(Ordering::SeqCst)
    }

    pub async fn next_event(&mut self) -> PeerEvent {
        with_deadline("the next listener event", self.events.recv())
            .await
            .expect("the listener is running")
    }

    /// Asserts the listener is still accepting (no connection took it
    /// down).
    pub fn assert_running(&self) {
        assert!(!self.task.is_finished(), "the listener stopped");
    }
}

impl Drop for Serving {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub async fn serve(host: &Host) -> Serving {
    serve_with(host, Tuning::DEFAULT).await
}

/// What `agent --serve` will do: open the spec's root, expanded with the
/// shared expansion, on this host - counting every call, so a test can
/// say the factory (and so the filesystem) was never reached.
pub async fn serve_with(host: &Host, tuning: Tuning) -> Serving {
    let listener = bind_peer(IpAddr::from([127, 0, 0, 1]), 0).await.unwrap();
    let at = listener.local_addr().unwrap();
    let opened = Arc::new(AtomicUsize::new(0));
    let facts = HostFacts::new(
        Platform::HOST,
        Some(host.home().to_str().unwrap().to_owned()),
        Vec::new(),
        "/".to_owned(),
    );
    let open = {
        let (opened, state, home) = (
            opened.clone(),
            host.state(),
            facts.home().map(str::to_owned),
        );
        move |spec: ReplicaSpec, symlinks: Symlinks| -> Opening {
            opened.fetch_add(1, Ordering::SeqCst);
            let state = state.clone();
            let root = spec.expanded_root(home.as_deref());
            Box::pin(async move {
                let root = root.map_err(|e| ReplicaError::Refused(e.to_string()))?;
                let opened = tokio::task::spawn_blocking(move || {
                    LocalReplica::open(
                        root, state, spec.entry, spec.side, spec.jobs, tuning, symlinks,
                    )
                });
                Ok(opened.await.unwrap()?)
            })
        }
    };
    let server = Arc::new(PeerListener::new(
        open,
        host.identity.clone(),
        host.store(),
        &facts,
        tuning,
    ));
    let (sender, events) = mpsc::unbounded_channel();
    let task = tokio::spawn(server.serve(listener, move |event| {
        let _ = sender.send(event);
    }));
    Serving {
        at,
        events,
        opened,
        task,
    }
}

/// Makes `dir` exist with `mode` (unix permission bits).
#[cfg(unix)]
pub fn dir_with_mode(dir: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(dir).unwrap();
    fs::set_permissions(dir, fs::Permissions::from_mode(mode)).unwrap();
}

/// A TLS client that trusts any server and presents `identity` (or no
/// certificate at all): what a stranger, or a peer with an out-of-date
/// certificate, would run.
pub fn raw_client_config(identity: Option<&DeviceIdentity>) -> ClientConfig {
    let provider = Arc::new(ring::default_provider());
    let algorithms = provider.signature_verification_algorithms;
    let builder = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(TrustAnyServer(algorithms)));
    match identity {
        Some(identity) => builder
            .with_client_auth_cert(
                vec![CertificateDer::from(identity.certificate().der().to_vec())],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(identity.key_pkcs8_der().to_vec())),
            )
            .unwrap(),
        None => builder.with_no_client_auth(),
    }
}

pub fn raw_server_name() -> ServerName<'static> {
    ServerName::try_from("dsync").unwrap()
}

/// Completes the client's half of a TLS handshake with the listener at
/// `at` - which, under TLS 1.3, it does before the listener has judged
/// its certificate.
pub async fn raw_tls(
    at: SocketAddr,
    identity: Option<&DeviceIdentity>,
) -> std::io::Result<TlsStream<TcpStream>> {
    let tcp = TcpStream::connect(at).await?;
    TlsConnector::from(Arc::new(raw_client_config(identity)))
        .connect(raw_server_name(), tcp)
        .await
}

#[derive(Debug)]
struct TrustAnyServer(WebPkiSupportedAlgorithms);

impl ServerCertVerifier for TrustAnyServer {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::PeerIncompatible(
            rustls::PeerIncompatible::Tls12NotOffered,
        ))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.0)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.supported_schemes()
    }
}
