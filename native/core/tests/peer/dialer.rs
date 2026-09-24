//! The dialer: resolution by name, the dial bound, and what a successful
//! dial records - the cases of `socket_channel_test` and
//! `connect_secure_leak_test` that are not the listener's.

use std::time::{Duration, Instant, SystemTime};

use dsync_core::{PeerDialError, PeerDialer};
use dsync_domain::Tuning;
use tokio::io::AsyncReadExt;
use tokio::net::TcpListener;

use crate::support::{Host, address_of, identity, name, serve, somewhere, spec, with_deadline};

#[tokio::test]
async fn a_successful_dial_records_the_address_and_the_renewed_certificate() {
    let original = identity("desktop");
    let server = Host::new(original.renewed(None, SystemTime::now()).unwrap());
    let client = Host::new(identity("phone"));
    server.pair(&client.identity, "phone", somewhere(), &[]);
    client.pair(&original, "desktop", somewhere(), &[]);
    let serving = serve(&server).await;
    let before = client.paired("desktop");
    assert_eq!(before.last_known_address(), &somewhere());
    assert_eq!(before.certificate(), original.certificate());

    let dialed = with_deadline("dial", client.dial("desktop", Some(serving.at), "/"))
        .await
        .unwrap();
    assert_eq!(dialed.address, address_of(serving.at));
    with_deadline("close", dialed.replica.close())
        .await
        .unwrap();

    let after = client.paired("desktop");
    assert_eq!(after.last_known_address(), &address_of(serving.at));
    assert_eq!(after.certificate(), server.identity.certificate());
    assert_eq!(after.device_id(), original.device_id());

    // The next dial needs no address: it starts where the last one worked.
    let again = with_deadline("dial again", client.dial("desktop", None, "/"))
        .await
        .unwrap();
    with_deadline("close", again.replica.close()).await.unwrap();
}

#[tokio::test]
async fn a_failed_dial_records_nothing() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let serving = serve(&server).await;
    let before = client.paired("desktop");
    let refused = with_deadline("dial", client.dial("desktop", Some(serving.at), "/")).await;
    assert!(refused.is_err());
    assert_eq!(client.paired("desktop"), before);
}

#[tokio::test]
async fn a_name_that_is_not_paired_is_refused_before_any_socket() {
    let client = Host::new(identity("phone"));
    client.pair(&identity("desktop"), "desktop", somewhere(), &[]);
    let dialed = with_deadline("dial", client.dial("laptop", None, "/")).await;
    match dialed {
        Err(PeerDialError::NotPaired(name)) => assert_eq!(name.to_string(), "laptop"),
        other => panic!("{:?}", other.map(|_| ())),
    }
}

#[tokio::test]
async fn nothing_listening_is_unreachable_at_once() {
    let client = Host::new(identity("phone"));
    let server = identity("desktop");
    let closed = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let at = closed.local_addr().unwrap();
    drop(closed);
    client.pair(&server, "desktop", address_of(at), &[]);
    let dialed = with_deadline("dial", client.dial("desktop", None, "/")).await;
    match dialed {
        Err(error @ PeerDialError::Unreachable { .. }) => {
            let text = error.to_string();
            assert!(
                text.contains("desktop") && text.contains(&at.to_string()),
                "{text}"
            );
        }
        other => panic!("{:?}", other.map(|_| ())),
    }
}

/// A peer that accepts and never answers: the dial fails at the bound
/// ([`Tuning::handshake`], shortened here to wait out in real time), says
/// so, and leaves nothing open behind it.
#[tokio::test]
async fn a_silent_peer_is_abandoned_at_the_dial_bound_holding_nothing() {
    let client = Host::new(identity("phone"));
    let silent = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let at = silent.local_addr().unwrap();
    client.pair(&identity("desktop"), "desktop", address_of(at), &[]);
    let bound = Duration::from_millis(300);
    let dialer = PeerDialer::new(
        client.identity.clone(),
        client.store(),
        Tuning {
            handshake: bound,
            ..Tuning::DEFAULT
        },
    );
    let desktop = name("desktop");
    let started = Instant::now();
    let (dialed, accepted) = with_deadline("dial", async {
        tokio::join!(dialer.dial(&desktop, None, spec("/")), silent.accept())
    })
    .await;
    let waited = started.elapsed();
    match dialed {
        Err(PeerDialError::Unreachable { cause, .. }) => {
            assert_eq!(cause.kind(), std::io::ErrorKind::TimedOut);
        }
        other => panic!("{:?}", other.map(|_| ())),
    }
    assert!(waited >= bound, "{waited:?}");
    // The abandoned dial closed its socket: the far side reads its end.
    let (mut far, _) = accepted.unwrap();
    let mut sink = Vec::new();
    with_deadline("the far end", far.read_to_end(&mut sink))
        .await
        .unwrap();
    assert!(!sink.is_empty(), "the dial sent its hello before giving up");
}

/// Positive control for the bound: a peer that answers within it is
/// untouched by it.
#[tokio::test]
async fn a_dial_that_finishes_in_time_is_untouched_by_the_bound() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    server.pair(&client.identity, "phone", somewhere(), &[]);
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let serving = serve(&server).await;
    let dialer = PeerDialer::new(
        client.identity.clone(),
        client.store(),
        Tuning {
            handshake: Duration::from_secs(2),
            ..Tuning::DEFAULT
        },
    );
    let dialed = with_deadline(
        "dial",
        dialer.dial(&name("desktop"), Some(address_of(serving.at)), spec("/")),
    )
    .await
    .unwrap();
    with_deadline("close", dialed.replica.close())
        .await
        .unwrap();
}

#[tokio::test]
async fn a_probe_proves_admission_and_leaves_nothing_behind() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    server.pair(&client.identity, "phone", somewhere(), &[]);
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let serving = serve(&server).await;
    let before = client.paired("desktop");

    let probed = with_deadline(
        "probe",
        client
            .dialer()
            .probe(&name("desktop"), Some(address_of(serving.at))),
    )
    .await
    .unwrap();
    assert_eq!(probed, address_of(serving.at));
    assert_eq!(client.paired("desktop"), before, "a probe records nothing");
    assert_eq!(serving.opened(), 0, "a probe opens no replica");
    serving.assert_running();
}

#[tokio::test]
async fn a_probe_of_a_peer_that_does_not_admit_this_host_is_refused() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let serving = serve(&server).await;
    let probed = with_deadline(
        "probe",
        client
            .dialer()
            .probe(&name("desktop"), Some(address_of(serving.at))),
    )
    .await;
    assert!(
        matches!(probed, Err(PeerDialError::RefusedByPeer { .. })),
        "{probed:?}"
    );
}

#[tokio::test]
async fn a_dial_notes_a_certificate_close_to_its_end() {
    // Issued so that ten days of its lifetime are left.
    let lifetime = dsync_domain::CertificateValidity::LIFETIME;
    let ageing = crate::support::identity_issued(
        "phone",
        SystemTime::now() - lifetime + Duration::from_secs(10 * 24 * 60 * 60),
    );
    let server = Host::new(identity("desktop"));
    let client = Host::new(ageing);
    server.pair(&client.identity, "phone", somewhere(), &[]);
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let serving = serve(&server).await;
    let dialed = with_deadline("dial", client.dial("desktop", Some(serving.at), "/"))
        .await
        .unwrap();
    let notes: Vec<String> = dialed.expiries.iter().map(ToString::to_string).collect();
    with_deadline("close", dialed.replica.close())
        .await
        .unwrap();
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(notes[0].contains("this host"), "{notes:?}");

    // Positive control's converse: fresh certificates on both ends say nothing.
    let fresh = Host::new(identity("laptop"));
    server.pair(&fresh.identity, "laptop", somewhere(), &[]);
    fresh.pair(&server.identity, "desktop", somewhere(), &[]);
    let dialed = with_deadline("dial", fresh.dial("desktop", Some(serving.at), "/"))
        .await
        .unwrap();
    assert!(dialed.expiries.is_empty());
    with_deadline("close", dialed.replica.close())
        .await
        .unwrap();
}
