use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use dsync_domain::host_port::PeerAddress;
use dsync_domain::{DeviceId, FormatVersion, OutOfValidity, PeerName, ReplicaOp, Side, Tuning};

use super::{Attempt, ReconnectCause, Verdict, Window, verdict};
use crate::connector::{ConnectError, ConnectFailure};
use crate::link_error::LinkError;
use crate::peer_dialer::PeerDialError;
use crate::replica_error::ReplicaError;
use crate::replica_lock::LockError;
use crate::run::RunError;

const PEER_B: &[Side] = &[Side::B];

fn run(side: Side, op: ReplicaOp, source: ReplicaError) -> ReconnectCause {
    ReconnectCause::Run(RunError::Replica {
        side,
        op,
        source: Arc::new(source),
    })
}

fn link(error: LinkError) -> ReconnectCause {
    run(Side::B, ReplicaOp::Scan, ReplicaError::Link(error))
}

fn held(side: Side) -> ReconnectCause {
    run(
        side,
        ReplicaOp::Lock,
        ReplicaError::Lock(LockError::Held {
            path: PathBuf::from("/state/lock"),
        }),
    )
}

fn connect(failure: ConnectFailure) -> ReconnectCause {
    ReconnectCause::Connect(Arc::new(ConnectError {
        side: Side::B,
        failure,
    }))
}

fn dial(error: PeerDialError) -> ReconnectCause {
    connect(error.into())
}

fn device() -> PeerName {
    PeerName::parse("phone").unwrap()
}

fn address() -> PeerAddress {
    PeerAddress::new("127.0.0.1", 28771).unwrap()
}

fn id(byte: u8) -> DeviceId {
    DeviceId::from_spki_der(&[byte])
}

fn unreachable() -> ReconnectCause {
    dial(PeerDialError::Unreachable {
        device: device(),
        address: address(),
        cause: io::Error::from(io::ErrorKind::ConnectionRefused),
    })
}

fn silent() -> LinkError {
    LinkError::PeerSilent {
        limit: Duration::from_secs(1),
    }
}

fn drops() -> Vec<LinkError> {
    vec![
        LinkError::Closed,
        LinkError::Io(Arc::new(io::Error::from(io::ErrorKind::ConnectionReset))),
        silent(),
    ]
}

fn versions() -> (FormatVersion, FormatVersion) {
    (FormatVersion::new(1, 0), FormatVersion::new(2, 0))
}

/// Link failures that are not a drop: the far side said something this
/// side will hear again.
fn refusing_links() -> Vec<LinkError> {
    let (local, remote) = versions();
    vec![
        LinkError::ClosedBeforeHandshake,
        LinkError::VersionMismatch { local, remote },
        LinkError::NotSpeakingProtocol {
            received: b"banner".to_vec(),
            truncated: false,
        },
        LinkError::NoPeerPreamble {
            received: vec![0, 1],
        },
        LinkError::PreambleVersionMismatch { local, remote },
        LinkError::Protocol("bad frame".to_owned()),
    ]
}

/// Every connect failure a re-dial must not try again.
fn final_connects() -> Vec<ReconnectCause> {
    let mut finals: Vec<ReconnectCause> = refusing_links()
        .into_iter()
        .map(|error| dial(PeerDialError::Link(error)))
        .collect();
    finals.extend([
        dial(PeerDialError::NotPaired(id(1))),
        dial(PeerDialError::OwnCertificate(OutOfValidity::Expired {
            not_after: SystemTime::UNIX_EPOCH,
        })),
        dial(PeerDialError::Impostor {
            device: device(),
            address: address(),
            expected: id(1),
            presented: id(2),
        }),
        dial(PeerDialError::PeerCertificate {
            device: device(),
            breach: OutOfValidity::Expired {
                not_after: SystemTime::UNIX_EPOCH,
            },
        }),
        dial(PeerDialError::RefusedByPeer {
            device: device(),
            address: address(),
            cause: LinkError::Closed,
        }),
        dial(PeerDialError::Tls {
            device: device(),
            address: address(),
            cause: io::Error::other("bad certificate"),
        }),
        connect(ConnectFailure::Link(LinkError::Closed)),
        connect(ConnectFailure::NoIdentity),
    ]);
    finals
}

/// Every run failure no attempt tries again.
fn final_runs() -> Vec<ReconnectCause> {
    let mut finals: Vec<ReconnectCause> = refusing_links().into_iter().map(link).collect();
    finals.extend([
        run(
            Side::B,
            ReplicaOp::Hello,
            ReplicaError::Refused("NOT_GRANTED: not granted".to_owned()),
        ),
        run(
            Side::B,
            ReplicaOp::Hello,
            ReplicaError::Refused("GRANTS_NEST: grants nest".to_owned()),
        ),
        run(
            Side::B,
            ReplicaOp::Lock,
            ReplicaError::Lock(LockError::FolderInUse {
                folder: PathBuf::from("/notes"),
                lock: PathBuf::from("/state/folder.lock"),
            }),
        ),
    ]);
    finals
}

#[test]
fn a_dropped_link_to_a_peer_is_dialled_again_on_any_attempt() {
    for error in drops() {
        for attempt in [Attempt::First, Attempt::Redial] {
            assert_eq!(
                verdict(attempt, &link(error.clone()), PEER_B),
                Verdict::Retry,
                "{error:?}"
            );
        }
    }
}

#[test]
fn a_dropped_link_on_a_side_that_is_not_a_peer_is_final() {
    for error in drops() {
        assert_eq!(
            verdict(Attempt::First, &link(error.clone()), &[Side::A]),
            Verdict::Final
        );
        assert_eq!(verdict(Attempt::Redial, &link(error), &[]), Verdict::Final);
    }
}

#[test]
fn a_redials_connect_is_retried_only_when_it_may_pass() {
    assert_eq!(
        verdict(Attempt::Redial, &unreachable(), PEER_B),
        Verdict::Retry
    );
    for error in drops() {
        assert_eq!(
            verdict(Attempt::Redial, &dial(PeerDialError::Link(error)), PEER_B),
            Verdict::Retry
        );
    }
    for cause in final_connects() {
        assert_eq!(
            verdict(Attempt::Redial, &cause, PEER_B),
            Verdict::Final,
            "{cause:?}"
        );
    }
}

#[test]
fn a_first_connect_is_never_retried() {
    assert_eq!(
        verdict(Attempt::First, &unreachable(), PEER_B),
        Verdict::Final
    );
    assert_eq!(
        verdict(Attempt::First, &dial(PeerDialError::Link(silent())), PEER_B),
        Verdict::Final
    );
}

#[test]
fn a_held_lock_on_a_peer_is_retried_only_on_a_redial() {
    assert_eq!(
        verdict(Attempt::Redial, &held(Side::B), PEER_B),
        Verdict::Retry
    );
    assert_eq!(
        verdict(Attempt::First, &held(Side::B), PEER_B),
        Verdict::Final
    );
    assert_eq!(
        verdict(Attempt::Redial, &held(Side::A), PEER_B),
        Verdict::Final
    );
}

#[test]
fn every_other_run_failure_is_final() {
    for cause in final_runs() {
        for attempt in [Attempt::First, Attempt::Redial] {
            assert_eq!(
                verdict(attempt, &cause, PEER_B),
                Verdict::Final,
                "{cause:?}"
            );
        }
    }
}

fn tuning() -> Tuning {
    Tuning {
        reconnect_backoff: Duration::from_secs(1),
        reconnect_backoff_max: Duration::from_secs(4),
        reconnect_window: Duration::from_secs(10),
        reconnects_per_entry: 10,
        ..Tuning::DEFAULT
    }
}

#[test]
fn the_backoff_doubles_up_to_its_cap() {
    let start = Instant::now();
    let mut window = Window::open(start, tuning());
    let waits: Vec<u64> = (0..4)
        .map(|made| window.next(made, start).unwrap().as_secs())
        .collect();
    assert_eq!(waits, [1, 2, 4, 4]);
}

#[test]
fn no_wait_is_started_that_would_end_past_the_window() {
    let start = Instant::now();
    let mut window = Window::open(start, tuning());
    // Waits of 1 and 2 seconds: the next, of 4, ends at 11 s from 7 s.
    assert!(window.next(0, start).is_some());
    assert!(window.next(1, start + Duration::from_secs(1)).is_some());
    assert_eq!(window.next(2, start + Duration::from_secs(7)), None);

    // Positive control: the same wait from 6 s ends exactly at the window.
    let mut window = Window::open(start, tuning());
    window.next(0, start);
    window.next(1, start);
    assert_eq!(
        window.next(2, start + Duration::from_secs(6)),
        Some(Duration::from_secs(4))
    );
}

#[test]
fn the_cap_ends_the_redials_whatever_the_window() {
    let start = Instant::now();
    let mut window = Window::open(start, tuning());
    assert!(window.next(9, start).is_some());
    let mut fresh = Window::open(start, tuning());
    assert_eq!(fresh.next(10, start), None);
}
