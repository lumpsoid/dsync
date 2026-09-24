//! How much moving peer:// TLS from Dart to Rust (rustls) would buy on the
//! phone, in throughput and in CPU per MiB (task 4dc926). Not part of the
//! build: a standalone receiver fed by benchmark/socket_pump.dart's `send`, so
//! the sending side is byte-for-byte the one the Dart receiver sees.
//!
//! LocalSend's choices, mirrored: tokio (multithreaded runtime), rustls with
//! the ring provider, TLS 1.3 only, and large reads (256 KiB, discarded). The
//! TLS configuration matches the Dart probe's: the server presents the probe
//! identity (benchmark/socket_pump.dart's `probeIdentity()`, exported as PEM)
//! and requires a client certificate that is that same certificate. Where
//! BoringSSL verifies the client against it as a trust anchor, this pins the
//! DER, as production's client side does; webpki would refuse the identity as
//! an end entity (it is `cA: TRUE`, see self_signed_certificate.dart). The
//! client's CertificateVerify signature is still checked (ring).
//!
//! Cases, each on the ports of the Dart sender's case of the same shape, from
//! the base port (default 47570, so both receivers can be up at once):
//!   plain          +0      tokio TcpStream            sender case `plain`
//!   rustls         +2      1 TLS connection           sender case `tls`
//!   rustls-1thread +6      rustls on a current-thread runtime of its own:
//!                          the minimum cost, one thread sender case `tls-iso`
//!   rustls-x2      +9–10   2 TLS connections          sender case `tls-iso-x2`
//!   rustls-x4      +11–14  4 TLS connections          sender case `tls-iso-x4`
//! Every case listens at once, each port accepts once, and the process exits
//! once every case in --cases (default all) has been served once.
//!
//! Per connection it prints MiB/s from its first byte to its last, reads and
//! bytes per read, and the negotiated suite; per case, the process CPU (user
//! plus system, all threads, /proc/self/stat at 10 ms resolution, as the Dart
//! probe reads it) from the accept (after the handshake) to the last read, in
//! seconds and in ms per MiB. A multi-connection case prints a line per
//! connection and a `total` line: all bytes from the first byte on any
//! connection to the last byte on all of them, and the CPU over that span.
//!
//! On the phone (from the repo root; bench phone 192.168.0.61):
//!   dart run benchmark/socket_pump.dart export-identity \
//!     benchmark/rust_tls_probe/identity
//!   (cd benchmark/rust_tls_probe && \
//!     cargo build --release --target aarch64-linux-android)
//!   adb push benchmark/rust_tls_probe/target/aarch64-linux-android/release/rust_tls_probe \
//!     benchmark/rust_tls_probe/identity/cert.pem \
//!     benchmark/rust_tls_probe/identity/key.pem /data/local/tmp/
//!   adb shell 'cd /data/local/tmp && chmod 755 rust_tls_probe && \
//!     ./rust_tls_probe --identity . [--port 47570] [--cases plain,rustls,…]'
//! then, once it prints `listening` for every case, from the desktop:
//!   dart run benchmark/socket_pump.dart send --host 192.168.0.61 \
//!     --port 47570 --cases plain,tls,tls-iso,tls-iso-x2,tls-iso-x4 [--mib 128]
//! (--cases lists the sender's cases for the Rust cases served, in the table
//! above; drop `tls-iso` without rustls-1thread and so on.)
//!
//! Comparing with Dart: run the Dart probe on the phone as its header says
//! (integration_test/socket_pump_probe_test.dart, port 47470) with
//!   --dart-define=CASES=plain,tls,tls-iso,tls-iso-x2,tls-iso-x4
//! and the same `send`, with --port 47470. Line up plain with plain; rustls
//! with tls (Dart, root isolate) and tls-iso (Dart, one background isolate);
//! rustls-x2/x4 with tls-iso-x2/x4 (Dart, one isolate per connection). Both
//! print MiB/s and CPU ms/MiB per case, measured the same way. Caveats: an
//! `adb shell` process is not in the app's top-app cgroup, so the scheduler
//! may place and clock it differently from the app; and the Dart number is the
//! whole Flutter process, engine threads included.
//!
//! Local check: `cargo run --release -- --identity identity` in this
//! directory, then the same `send` with --host 127.0.0.1.

use std::error::Error;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Instant;

use rustls::client::danger::HandshakeSignatureValid;
use rustls::crypto::{ring, WebPkiSupportedAlgorithms};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{
    CertificateError, DigitallySignedStruct, DistinguishedName, ServerConfig, SignatureScheme,
};
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::net::TcpListener;
use tokio::runtime;
use tokio_rustls::TlsAcceptor;

const DEFAULT_PORT: u16 = 47570;
const READ_BUFFER: usize = 256 << 10;

/// Clock ticks per second in /proc/self/stat: USER_HZ, 100 on Linux and
/// Android alike.
const TICKS_PER_SECOND: f64 = 100.0;

#[derive(Clone, Copy, PartialEq, Debug)]
enum Case {
    Plain,
    Rustls,
    Rustls1Thread,
    RustlsX2,
    RustlsX4,
}

impl Case {
    const ALL: [Case; 5] = [
        Case::Plain,
        Case::Rustls,
        Case::Rustls1Thread,
        Case::RustlsX2,
        Case::RustlsX4,
    ];

    fn label(self) -> &'static str {
        match self {
            Case::Plain => "plain",
            Case::Rustls => "rustls",
            Case::Rustls1Thread => "rustls-1thread",
            Case::RustlsX2 => "rustls-x2",
            Case::RustlsX4 => "rustls-x4",
        }
    }

    /// The Dart sender's case whose ports and connection count this one
    /// takes.
    fn sender_case(self) -> &'static str {
        match self {
            Case::Plain => "plain",
            Case::Rustls => "tls",
            Case::Rustls1Thread => "tls-iso",
            Case::RustlsX2 => "tls-iso-x2",
            Case::RustlsX4 => "tls-iso-x4",
        }
    }

    /// The first of this case's consecutive ports, from the base port: the
    /// sender case's offset in benchmark/socket_pump.dart.
    fn port_offset(self) -> u16 {
        match self {
            Case::Plain => 0,
            Case::Rustls => 2,
            Case::Rustls1Thread => 6,
            Case::RustlsX2 => 9,
            Case::RustlsX4 => 11,
        }
    }

    fn connections(self) -> usize {
        match self {
            Case::RustlsX2 => 2,
            Case::RustlsX4 => 4,
            _ => 1,
        }
    }

    fn secure(self) -> bool {
        self != Case::Plain
    }

    fn parse(list: &str) -> Result<Vec<Case>, String> {
        list.split(',')
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(|l| {
                Case::ALL
                    .into_iter()
                    .find(|c| c.label() == l)
                    .ok_or_else(|| format!("unknown case \"{l}\""))
            })
            .collect()
    }
}

/// This process's CPU so far, user plus system, in clock ticks, all threads:
/// fields 14 and 15 of /proc/self/stat. None where there is no /proc.
fn process_cpu_ticks() -> Option<u64> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    // Fields from the 3rd on follow the parenthesised command name, which may
    // itself hold spaces.
    let mut fields = stat[stat.rfind(')')? + 2..].split(' ').skip(11);
    let utime: u64 = fields.next()?.parse().ok()?;
    let stime: u64 = fields.next()?.parse().ok()?;
    Some(utime + stime)
}

/// `cpu 1.23 s 9.6 ms/MiB`.
fn cpu_report(start: Option<u64>, end: Option<u64>, bytes: u64) -> String {
    match (start, end) {
        (Some(start), Some(end)) => {
            let seconds = (end - start) as f64 / TICKS_PER_SECOND;
            format!(
                "cpu {seconds:.2} s {:.1} ms/MiB",
                seconds * 1000.0 / mib(bytes)
            )
        }
        _ => "cpu -".to_string(),
    }
}

fn mib(bytes: u64) -> f64 {
    bytes as f64 / (1u64 << 20) as f64
}

/// One connection's reading: bytes, reads, first and last read, the process
/// CPU as it began and ended, and the TLS suite if any.
struct Span {
    bytes: u64,
    reads: u64,
    first: Option<Instant>,
    last: Option<Instant>,
    cpu_start: Option<u64>,
    cpu_end: Option<u64>,
    suite: Option<String>,
}

impl Span {
    fn seconds(&self) -> f64 {
        match (self.first, self.last) {
            (Some(first), Some(last)) => (last - first).as_secs_f64().max(1e-6),
            _ => 1e-6,
        }
    }

    fn report(&self, label: &str, with_cpu: bool) -> String {
        if self.reads == 0 {
            return format!("{label}: no bytes");
        }
        let seconds = self.seconds();
        let mut line = format!(
            "{label:<16} {:.1} MiB/s  {:.0} MiB in {seconds:.2} s  reads {} ({:.0}/s)  \
             bytes/read mean {:.1} KiB",
            mib(self.bytes) / seconds,
            mib(self.bytes),
            self.reads,
            self.reads as f64 / seconds,
            self.bytes as f64 / self.reads as f64 / 1024.0,
        );
        if with_cpu {
            line += &format!("  {}", cpu_report(self.cpu_start, self.cpu_end, self.bytes));
        }
        if let Some(suite) = &self.suite {
            line += &format!("  {suite}");
        }
        line
    }
}

/// Reads [stream] to its end into a [READ_BUFFER] buffer, discarding. A peer
/// that ends TCP without close_notify (the Dart sender's half-close) is an
/// end, not an error.
async fn read_all<S: AsyncRead + Unpin>(
    mut stream: S,
    suite: Option<String>,
) -> std::io::Result<Span> {
    let mut buffer = vec![0u8; READ_BUFFER];
    let mut span = Span {
        bytes: 0,
        reads: 0,
        first: None,
        last: None,
        cpu_start: process_cpu_ticks(),
        cpu_end: None,
        suite,
    };
    loop {
        match stream.read(&mut buffer).await {
            Ok(0) => break,
            Ok(n) => {
                let now = Instant::now();
                span.first.get_or_insert(now);
                span.last = Some(now);
                span.bytes += n as u64;
                span.reads += 1;
            }
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(e),
        }
    }
    span.cpu_end = process_cpu_ticks();
    Ok(span)
}

/// Accepts [listener]'s one connection, handshakes it when [acceptor] is
/// given, and reads it to its end.
async fn serve_connection(
    listener: std::net::TcpListener,
    acceptor: Option<TlsAcceptor>,
) -> std::io::Result<Span> {
    let listener = TcpListener::from_std(listener)?;
    let (tcp, _) = listener.accept().await?;
    drop(listener);
    match acceptor {
        None => read_all(tcp, None).await,
        Some(acceptor) => {
            let tls = acceptor.accept(tcp).await?;
            let (_, connection) = tls.get_ref();
            let suite = connection
                .negotiated_cipher_suite()
                .map(|s| format!("{:?} {:?}", s.version().version, s.suite()));
            read_all(tls, suite).await
        }
    }
}

/// Serves [case] on [listeners], one per connection, all at once; prints a
/// line per connection (and a total for several) as they end.
async fn serve_case(case: Case, listeners: Vec<std::net::TcpListener>, acceptor: TlsAcceptor) {
    let n = case.connections();
    let tasks: Vec<_> = listeners
        .into_iter()
        .map(|l| tokio::spawn(serve_connection(l, case.secure().then(|| acceptor.clone()))))
        .collect();
    let mut spans = Vec::new();
    for (i, task) in tasks.into_iter().enumerate() {
        let label = if n == 1 {
            case.label().to_string()
        } else {
            format!("{}#{i}", case.label())
        };
        match task.await {
            Ok(Ok(span)) => {
                println!("{}", span.report(&label, n == 1));
                spans.push(span);
            }
            Ok(Err(e)) => println!("{label} failed: {e}"),
            Err(e) => println!("{label} failed: {e}"),
        }
    }
    if n > 1 {
        println!("{}", total(case, &spans));
    }
}

/// All of a multi-connection case's bytes from the first byte on any
/// connection to the last byte on all of them, and the process CPU from the
/// first connection's start to the last one's end.
fn total(case: Case, spans: &[Span]) -> String {
    let label = format!("{} total", case.label());
    let bytes: u64 = spans.iter().map(|s| s.bytes).sum();
    let first = spans.iter().filter_map(|s| s.first).min();
    let last = spans.iter().filter_map(|s| s.last).max();
    let (Some(first), Some(last)) = (first, last) else {
        return format!("{label:<16} no bytes");
    };
    let seconds = (last - first).as_secs_f64().max(1e-6);
    let cpu_start = spans.iter().map(|s| s.cpu_start).min().flatten();
    let cpu_end = spans.iter().map(|s| s.cpu_end).max().flatten();
    let cpu_known = spans
        .iter()
        .all(|s| s.cpu_start.is_some() && s.cpu_end.is_some());
    format!(
        "{label:<16} {:.1} MiB/s  {:.0} MiB in {seconds:.2} s over {}/{} connections, \
         first byte on any to last byte on all  {}",
        mib(bytes) / seconds,
        mib(bytes),
        spans.len(),
        case.connections(),
        if cpu_known {
            cpu_report(cpu_start, cpu_end, bytes)
        } else {
            "cpu -".to_string()
        },
    )
}

/// Requires the client to present exactly [PinnedClient::certificate], and
/// checks its handshake signature.
#[derive(Debug)]
struct PinnedClient {
    certificate: CertificateDer<'static>,
    algorithms: WebPkiSupportedAlgorithms,
}

impl ClientCertVerifier for PinnedClient {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        if end_entity.as_ref() == self.certificate.as_ref() {
            Ok(ClientCertVerified::assertion())
        } else {
            Err(rustls::Error::InvalidCertificate(
                CertificateError::ApplicationVerificationFailure,
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

/// TLS 1.3 on ring, the probe identity presented, the same one required of
/// the client.
fn acceptor(identity: &str) -> Result<TlsAcceptor, Box<dyn Error>> {
    let certificate = CertificateDer::from_pem_file(format!("{identity}/cert.pem"))?;
    let key = PrivateKeyDer::from_pem_file(format!("{identity}/key.pem"))?;
    let provider = Arc::new(ring::default_provider());
    let verifier = PinnedClient {
        certificate: certificate.clone(),
        algorithms: provider.signature_verification_algorithms,
    };
    let config = ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(Arc::new(verifier))
        .with_single_cert(vec![certificate], key)?;
    Ok(TlsAcceptor::from(Arc::new(config)))
}

fn main() -> Result<(), Box<dyn Error>> {
    let mut port = DEFAULT_PORT;
    let mut cases = Case::ALL.to_vec();
    let mut identity = "identity".to_string();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "--port" => port = value()?.parse()?,
            "--cases" => cases = Case::parse(&value()?)?,
            "--identity" => identity = value()?,
            _ => {
                return Err(format!(
                    "usage: rust_tls_probe [--port {DEFAULT_PORT}] [--identity DIR] \
                     [--cases {}]",
                    Case::ALL.map(Case::label).join(",")
                )
                .into())
            }
        }
    }
    let acceptor = acceptor(&identity)?;

    // Every port bound before any case is announced, as the Dart receiver
    // does.
    let mut bound = Vec::new();
    for case in cases {
        let at = port + case.port_offset();
        let listeners = (0..case.connections() as u16)
            .map(|i| {
                let l =
                    std::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::UNSPECIFIED, at + i)))?;
                l.set_nonblocking(true)?;
                Ok(l)
            })
            .collect::<std::io::Result<Vec<_>>>()?;
        let last = at + case.connections() as u16 - 1;
        let ports = if last == at {
            format!("{at}")
        } else {
            format!("{at}-{last}")
        };
        println!(
            "listening {} on port {ports} (sender case {})",
            case.label(),
            case.sender_case()
        );
        bound.push((case, listeners));
    }

    // The one-thread case gets its own current-thread runtime on its own OS
    // thread; the rest share one multithreaded runtime.
    let (single, multi): (Vec<_>, Vec<_>) = bound
        .into_iter()
        .partition(|(case, _)| *case == Case::Rustls1Thread);
    let single_thread = single.into_iter().next().map(|(case, listeners)| {
        let acceptor = acceptor.clone();
        std::thread::spawn(move || {
            runtime::Builder::new_current_thread()
                .enable_io()
                .build()
                .expect("current-thread runtime")
                .block_on(serve_case(case, listeners, acceptor));
        })
    });
    runtime::Builder::new_multi_thread()
        .enable_io()
        .build()?
        .block_on(async {
            let tasks: Vec<_> = multi
                .into_iter()
                .map(|(case, listeners)| {
                    tokio::spawn(serve_case(case, listeners, acceptor.clone()))
                })
                .collect();
            for task in tasks {
                let _ = task.await;
            }
        });
    if let Some(thread) = single_thread {
        let _ = thread.join();
    }
    println!("done");
    Ok(())
}
