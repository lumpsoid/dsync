//! The listener's timers under a paused clock, over an in-memory stream
//! (real sockets and a paused clock race: the clock can jump before the
//! kernel's readiness is polled): the token's expiry, the operator's
//! window, the handshake deadline. Plus what only a hand-rolled client can
//! send. The listener on loopback is `tests/pairing`'s.

use std::future::{Pending, Ready, pending, ready};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::atomic::{AtomicUsize, Ordering};

use tokio::io::{AsyncReadExt, duplex};

use super::*;
use crate::enrolment_dialer::{EnrolError, EnrolmentDialer};
use crate::peer_pin::{PeerPin, enrolment_client_config, server_name};
use crate::state_dir::StateDir;

const FROM: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 40000);

/// Where the enrolling phone says it serves: not the default, so a
/// listener that recorded the default instead would be caught.
const SERVES_ON: NonZeroU16 = NonZeroU16::new(40123).unwrap();

struct Side {
    _dir: tempfile::TempDir,
    identity: DeviceIdentity,
    paired: PairedDeviceStore,
}

fn side(common_name: &str) -> Side {
    let dir = tempfile::tempdir().unwrap();
    let paired = PairedDeviceStore::new(&StateDir::new(dir.path()));
    Side {
        _dir: dir,
        identity: DeviceIdentity::generate(common_name, SystemTime::now()).unwrap(),
        paired,
    }
}

fn name(text: &str) -> PeerName {
    PeerName::parse(text).unwrap()
}

fn slot() -> UnauthenticatedSlot {
    UnauthenticatedSlots::new(&Tuning::DEFAULT)
        .admit(FROM.ip())
        .unwrap()
}

/// The showing side, bound (on loopback, unused: connections come over
/// `duplex`), its payload and its state with `confirm`.
async fn showing<C>(desktop: &Side, confirm: C) -> (PairingPayload, Arc<Enrolling<C>>) {
    let listener = EnrolmentListener::bind(
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        desktop.identity.clone(),
        desktop.paired.clone(),
        name("phone"),
        Tuning::DEFAULT,
    )
    .await
    .unwrap();
    let payload = listener
        .payload("127.0.0.1", Tuning::DEFAULT.peer_port)
        .unwrap();
    let (_tcp, enrolling) = listener.into_parts(confirm).unwrap();
    (payload, enrolling)
}

/// The phone's enrolment of `payload` against `enrolling`, over memory.
async fn enrol_over_memory<C, Confirming>(
    phone: &Side,
    payload: &PairingPayload,
    enrolling: &Enrolling<C>,
) -> (
    Result<PairedDevice, EnrolError>,
    Result<EnrolmentEnd, EnrolmentRefusal>,
)
where
    C: Fn(PendingEnrolment) -> Confirming,
    Confirming: Future<Output = bool>,
{
    let dialer = EnrolmentDialer::new(
        phone.identity.clone(),
        phone.paired.clone(),
        Tuning::DEFAULT,
    );
    let device = dialer.candidate(payload, name("desktop")).unwrap();
    let (client, server) = duplex(64 * 1024);
    tokio::join!(
        dialer.enrol_over(client, payload, device, SERVES_ON),
        enrolling.enrol(server, FROM, slot())
    )
}

fn yes(_: PendingEnrolment) -> Ready<bool> {
    ready(true)
}

fn never(_: PendingEnrolment) -> Pending<bool> {
    pending()
}

#[tokio::test(start_paused = true)]
async fn a_token_redeemed_at_its_expiry_is_refused() {
    let (desktop, phone) = (side("desktop"), side("phone"));
    let (payload, enrolling) = showing(&desktop, yes).await;
    tokio::time::advance(Tuning::DEFAULT.pairing_token).await;

    let (enrolled, ended) = enrol_over_memory(&phone, &payload, &enrolling).await;
    assert!(
        matches!(
            enrolled,
            Err(EnrolError::Denied(EnrolmentDenial::TokenRejected))
        ),
        "{enrolled:?}"
    );
    assert!(
        matches!(ended, Err(EnrolmentRefusal::Token(TokenRefusal::Expired))),
        "{ended:?}"
    );
    assert!(desktop.paired.load().unwrap().is_empty());
    assert!(phone.paired.load().unwrap().is_empty());
}

/// Positive control: the same exchange a moment before the expiry pairs.
#[tokio::test(start_paused = true)]
async fn a_token_redeemed_just_before_its_expiry_pairs() {
    let (desktop, phone) = (side("desktop"), side("phone"));
    let (payload, enrolling) = showing(&desktop, yes).await;
    tokio::time::advance(Tuning::DEFAULT.pairing_token - Duration::from_secs(1)).await;

    let (enrolled, ended) = enrol_over_memory(&phone, &payload, &enrolling).await;
    assert!(enrolled.is_ok(), "{enrolled:?}");
    assert!(matches!(ended, Ok(EnrolmentEnd::Enrolled(_))), "{ended:?}");
}

#[tokio::test(start_paused = true)]
async fn a_confirmation_nobody_answers_is_refused_when_the_token_expires() {
    let (desktop, phone) = (side("desktop"), side("phone"));
    let (payload, enrolling) = showing(&desktop, never).await;
    let started = Instant::now();

    let (enrolled, ended) = enrol_over_memory(&phone, &payload, &enrolling).await;
    assert_eq!(started.elapsed(), Tuning::DEFAULT.pairing_token);
    assert!(
        matches!(
            enrolled,
            Err(EnrolError::Denied(EnrolmentDenial::Unconfirmed))
        ),
        "{enrolled:?}"
    );
    assert!(
        matches!(ended, Ok(EnrolmentEnd::Unconfirmed { device }) if device == phone.identity.device_id()),
        "{ended:?}"
    );
    assert!(desktop.paired.load().unwrap().is_empty());
    assert!(phone.paired.load().unwrap().is_empty());
}

/// Cut at the hello's deadline, well inside the handshake's, and its slot
/// is free again from that instant.
#[tokio::test(start_paused = true)]
async fn a_peer_that_never_speaks_is_cut_at_the_hello_deadline_and_frees_its_slot() {
    let desktop = side("desktop");
    let (_, enrolling) = showing(&desktop, yes).await;
    let only = UnauthenticatedSlots::new(&Tuning {
        unauthenticated_connections: 1,
        ..Tuning::DEFAULT
    });
    let held = only.admit(FROM.ip()).unwrap();
    assert!(only.admit(FROM.ip()).is_err(), "the one slot is held");
    let (_client, server) = duplex(64 * 1024);
    let started = Instant::now();

    let ended = enrolling.enrol(server, FROM, held).await;
    assert_eq!(started.elapsed(), Tuning::DEFAULT.client_hello);
    assert!(
        matches!(ended, Err(EnrolmentRefusal::HelloTimedOut { limit }) if limit == Tuning::DEFAULT.client_hello),
        "{ended:?}"
    );
    assert!(only.admit(FROM.ip()).is_ok(), "the slot came back");
}

/// The deadline covers the request as well as the handshake: a peer that
/// completes TLS and then sends nothing is cut at the handshake's deadline
/// (its hello arrived, so not at the hello's).
#[tokio::test(start_paused = true)]
async fn a_peer_that_stalls_after_the_handshake_is_cut_at_the_deadline() {
    let desktop = side("desktop");
    let (_, enrolling) = showing(&desktop, yes).await;
    let (client, server) = duplex(64 * 1024);
    let started = Instant::now();

    let (ended, _connected) = tokio::join!(enrolling.enrol(server, FROM, slot()), async {
        let config = enrolment_client_config(PeerPin::new([desktop.identity.device_id()])).unwrap();
        let mut tls = tokio_rustls::TlsConnector::from(Arc::new(config))
            .connect(server_name(), client)
            .await
            .unwrap();
        // Hold the connection open until the listener closes it.
        let mut sink = [0u8; 1];
        let _ = tls.read(&mut sink).await;
    });
    assert_eq!(started.elapsed(), Tuning::DEFAULT.handshake);
    assert!(
        matches!(ended, Err(EnrolmentRefusal::TimedOut { .. })),
        "{ended:?}"
    );
}

#[tokio::test]
async fn a_malformed_certificate_is_refused_without_asking_anyone_or_spending_the_token() {
    let (desktop, phone) = (side("desktop"), side("phone"));
    let asked = Arc::new(AtomicUsize::new(0));
    let counted = asked.clone();
    let (payload, enrolling) = showing(&desktop, move |_| {
        counted.fetch_add(1, Ordering::SeqCst);
        ready(true)
    })
    .await;

    let (client, server) = duplex(64 * 1024);
    let (ended, reply) = tokio::join!(enrolling.enrol(server, FROM, slot()), async {
        let config = enrolment_client_config(PeerPin::new([desktop.identity.device_id()])).unwrap();
        let mut tls = tokio_rustls::TlsConnector::from(Arc::new(config))
            .connect(server_name(), client)
            .await
            .unwrap();
        let request = EnrolmentRequest {
            token: *payload.token().as_bytes(),
            certificate_der: b"nope".to_vec(),
            serves_on: SERVES_ON,
        };
        write_message(&mut tls, &request).await.unwrap();
        read_message::<EnrolmentReply>(&mut tls).await.unwrap()
    });
    assert_eq!(
        reply,
        EnrolmentReply::Denied(EnrolmentDenial::UnreadableCertificate)
    );
    assert!(
        matches!(ended, Err(EnrolmentRefusal::UnreadableCertificate(_))),
        "{ended:?}"
    );
    assert_eq!(asked.load(Ordering::SeqCst), 0);
    assert!(!enrolling.redeemed());

    // Positive control: the token is still live for a real certificate,
    // and that one is put to the operator.
    let (enrolled, _) = enrol_over_memory(&phone, &payload, &enrolling).await;
    assert!(enrolled.is_ok(), "{enrolled:?}");
    assert_eq!(asked.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn the_enrolled_device_is_recorded_on_the_port_it_serves_on() {
    let (desktop, phone) = (side("desktop"), side("phone"));
    let (payload, enrolling) = showing(&desktop, yes).await;

    let (enrolled, ended) = enrol_over_memory(&phone, &payload, &enrolling).await;
    assert!(enrolled.is_ok(), "{enrolled:?}");
    let Ok(EnrolmentEnd::Enrolled(recorded)) = ended else {
        panic!("expected the phone enrolled: {ended:?}");
    };
    let expected = PeerAddress::new(&FROM.ip().to_string(), SERVES_ON.get()).unwrap();
    assert_eq!(recorded.last_known_address(), &expected);
    let stored = desktop.paired.load().unwrap();
    assert_eq!(
        stored.iter().next().unwrap().last_known_address(),
        &expected
    );
}

/// The request's layout with a plain port: only a hand-rolled peer can
/// say it serves on 0.
#[derive(serde::Serialize)]
struct AnyPortRequest {
    token: [u8; dsync_domain::EnrolmentToken::LEN],
    certificate_der: Vec<u8>,
    serves_on: u16,
}

#[tokio::test]
async fn a_request_serving_on_port_zero_is_refused_as_malformed_and_spends_nothing() {
    let (desktop, phone) = (side("desktop"), side("phone"));
    let asked = Arc::new(AtomicUsize::new(0));
    let counted = asked.clone();
    let (payload, enrolling) = showing(&desktop, move |_| {
        counted.fetch_add(1, Ordering::SeqCst);
        ready(true)
    })
    .await;

    let (client, server) = duplex(64 * 1024);
    let (ended, ()) = tokio::join!(enrolling.enrol(server, FROM, slot()), async {
        let config = enrolment_client_config(PeerPin::new([desktop.identity.device_id()])).unwrap();
        let mut tls = tokio_rustls::TlsConnector::from(Arc::new(config))
            .connect(server_name(), client)
            .await
            .unwrap();
        let request = AnyPortRequest {
            token: *payload.token().as_bytes(),
            certificate_der: phone.identity.certificate().der().to_vec(),
            serves_on: 0,
        };
        write_message(&mut tls, &request).await.unwrap();
        // Held open until the listener drops the connection.
        let mut sink = [0u8; 1];
        let _ = tls.read(&mut sink).await;
    });
    assert!(
        matches!(
            ended,
            Err(EnrolmentRefusal::Request(EnrolmentMessageError::Malformed(
                _
            )))
        ),
        "{ended:?}"
    );
    assert_eq!(asked.load(Ordering::SeqCst), 0);
    assert!(!enrolling.redeemed());
    assert!(desktop.paired.load().unwrap().is_empty());

    // Positive control: the token is still live for a request that names
    // a port.
    let (enrolled, _) = enrol_over_memory(&phone, &payload, &enrolling).await;
    assert!(enrolled.is_ok(), "{enrolled:?}");
    assert_eq!(asked.load(Ordering::SeqCst), 1);
}
