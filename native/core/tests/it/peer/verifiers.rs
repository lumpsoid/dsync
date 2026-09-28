//! The pinning verifiers in real handshakes, each refusal beside its
//! positive control: the same setup with the right key or date connects.

use dsync_core::{CertificateRefusal, PeerDialError, PeerEvent, PeerRefusal};
use dsync_domain::OutOfValidity;

use crate::peer::support::{
    Host, expired, identity, not_yet_valid, raw_tls, serve, somewhere, with_deadline,
};

/// Dials `server`'s listener from `client` as `label` and says whether
/// the session got as far as `hello`.
async fn hello_works(client: &Host, label: &str, at: std::net::SocketAddr) -> bool {
    let dialed = with_deadline("dial", client.dial(label, Some(at), "/")).await;
    dialed.is_ok()
}

#[tokio::test]
async fn an_unpaired_client_is_refused_by_the_server_verifier() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    let someone = identity("someone");
    server.pair(&someone, "someone", somewhere(), &[]);
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let mut serving = serve(&server).await;

    let refused = with_deadline("dial", client.dial("desktop", Some(serving.at), "/")).await;
    assert!(
        matches!(refused, Err(PeerDialError::RefusedByPeer { .. })),
        "{:?}",
        refused.map(|_| ())
    );
    let event = serving.next_event().await;
    assert!(
        matches!(
            &event,
            PeerEvent::Refused {
                why: PeerRefusal::Certificate(CertificateRefusal::NotPinned(id)),
                ..
            } if *id == client.identity.device_id()
        ),
        "{event:?}"
    );

    // Positive control: paired, the same client is served.
    server.pair(&client.identity, "phone", somewhere(), &[]);
    assert!(hello_works(&client, "desktop", serving.at).await);
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Started { .. }
    ));
    assert_eq!(serving.opened(), 0, "no hello was sent");
}

#[tokio::test]
async fn an_unpaired_server_is_refused_by_the_client_verifier() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    let other = identity("desktop");
    server.pair(&client.identity, "phone", somewhere(), &[]);
    client.pair(&other, "desktop", somewhere(), &[]);
    client.pair(&server.identity, "real", somewhere(), &[]);
    let serving = serve(&server).await;

    let refused = with_deadline("dial", client.dial("desktop", Some(serving.at), "/")).await;
    match refused {
        Err(PeerDialError::Impostor {
            expected,
            presented,
            ..
        }) => {
            assert_eq!(expected, other.device_id());
            assert_eq!(presented, server.identity.device_id());
        }
        other => panic!("{:?}", other.map(|_| ())),
    }
    // Positive control: pinned to the key it presents, it connects.
    assert!(hello_works(&client, "real", serving.at).await);
}

#[tokio::test]
async fn a_same_name_impostor_with_another_key_is_refused_on_both_sides() {
    let desktop = Host::new(identity("dsync-desktop"));
    let impostor_desktop = Host::new(identity("dsync-desktop"));
    let phone = Host::new(identity("dsync-phone"));
    let impostor_phone = Host::new(identity("dsync-phone"));
    for host in [&desktop, &impostor_desktop] {
        host.pair(&phone.identity, "phone", somewhere(), &[]);
    }
    for host in [&phone, &impostor_phone] {
        host.pair(&desktop.identity, "desktop", somewhere(), &[]);
    }
    let real = serve(&desktop).await;
    let mut fake = serve(&impostor_desktop).await;

    // The dialer refuses a listener under the paired name but another key.
    let dialed = with_deadline("dial", phone.dial("desktop", Some(fake.at), "/")).await;
    assert!(
        matches!(dialed, Err(PeerDialError::Impostor { .. })),
        "{:?}",
        dialed.map(|_| ())
    );
    let _ = fake.next_event().await;

    // The listener refuses a client under the paired name but another key.
    let mut real = real;
    let dialed = with_deadline("dial", impostor_phone.dial("desktop", Some(real.at), "/")).await;
    assert!(
        matches!(dialed, Err(PeerDialError::RefusedByPeer { .. })),
        "{:?}",
        dialed.map(|_| ())
    );
    assert!(matches!(
        real.next_event().await,
        PeerEvent::Refused {
            why: PeerRefusal::Certificate(CertificateRefusal::NotPinned(_)),
            ..
        }
    ));

    // Positive control: the real pair connects.
    assert!(hello_works(&phone, "desktop", real.at).await);
}

#[tokio::test]
async fn an_out_of_date_server_certificate_is_refused_by_the_client_verifier() {
    for (server_identity, breach) in [
        (expired("desktop"), "expired"),
        (not_yet_valid("desktop"), "not yet valid"),
    ] {
        let server = Host::new(server_identity);
        let client = Host::new(identity("phone"));
        server.pair(&client.identity, "phone", somewhere(), &[]);
        client.pair(&server.identity, "desktop", somewhere(), &[]);
        let mut serving = serve(&server).await;

        let dialed = with_deadline("dial", client.dial("desktop", Some(serving.at), "/")).await;
        let (Err(PeerDialError::PeerCertificate { breach: seen, .. }), own) =
            (dialed.map(|_| ()), serving.next_event().await)
        else {
            panic!("{breach}: the dial was not refused for the date");
        };
        let expected_expired = breach == "expired";
        assert_eq!(
            matches!(seen, OutOfValidity::Expired { .. }),
            expected_expired,
            "{breach}"
        );
        // The listener says why its own certificate was refused.
        assert!(
            matches!(
                &own,
                PeerEvent::Refused {
                    why: PeerRefusal::OwnCertificate(_),
                    ..
                }
            ),
            "{breach}: {own:?}"
        );
    }

    // Positive control: the same setup with a certificate valid now.
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    server.pair(&client.identity, "phone", somewhere(), &[]);
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let serving = serve(&server).await;
    assert!(hello_works(&client, "desktop", serving.at).await);
}

#[tokio::test]
async fn an_out_of_date_client_certificate_is_refused_by_the_server_verifier() {
    let server = Host::new(identity("desktop"));
    let mut serving = serve(&server).await;
    for (client, expired_case) in [(expired("phone"), true), (not_yet_valid("phone"), false)] {
        // Paired by its key: only the date is wrong.
        server.pair(&client, &format!("phone-{expired_case}"), somewhere(), &[]);
        let tls = with_deadline("raw handshake", raw_tls(serving.at, Some(&client))).await;
        let event = serving.next_event().await;
        match event {
            PeerEvent::Refused {
                why: PeerRefusal::Certificate(CertificateRefusal::OutOfValidity { device, breach }),
                ..
            } => {
                assert_eq!(device, client.device_id());
                assert_eq!(
                    matches!(breach, OutOfValidity::Expired { .. }),
                    expired_case
                );
            }
            other => panic!("{other:?}"),
        }
        drop(tls);
    }

    // Positive control: a paired client with a certificate valid now.
    let client = identity("phone");
    server.pair(&client, "phone-now", somewhere(), &[]);
    let _tls = with_deadline("raw handshake", raw_tls(serving.at, Some(&client)))
        .await
        .unwrap();
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Started { .. }
    ));
}

#[tokio::test]
async fn an_out_of_date_own_certificate_is_caught_before_dialling() {
    let client = Host::new(expired("phone"));
    client.pair(&identity("desktop"), "desktop", somewhere(), &[]);
    let dialed = with_deadline("dial", client.dial("desktop", None, "/")).await;
    assert!(
        matches!(
            dialed,
            Err(PeerDialError::OwnCertificate(OutOfValidity::Expired { .. }))
        ),
        "{:?}",
        dialed.map(|_| ())
    );
    // Positive control: a valid own certificate goes on to dial, and fails
    // only at the (dead) address.
    let client = Host::new(identity("phone"));
    client.pair(&identity("desktop"), "desktop", somewhere(), &[]);
    let dialed = with_deadline("dial", client.dial("desktop", None, "/")).await;
    assert!(
        matches!(dialed, Err(PeerDialError::Unreachable { .. })),
        "{:?}",
        dialed.map(|_| ())
    );
}

/// The pin is the key, not the certificate's bytes: a renewal under the
/// same key is accepted in both directions with nothing re-paired. (The
/// Dart listener, anchoring the exact bytes in BoringSSL, refused a
/// renewed client until its store had the new bytes; pinning by key has
/// no such gap.)
#[tokio::test]
async fn a_renewal_under_the_pinned_key_is_accepted_in_both_directions() {
    let now = std::time::SystemTime::now();
    let desktop = identity("desktop");
    let phone = identity("phone");
    let server = Host::new(desktop.renewed(None, now).unwrap());
    let client = Host::new(phone.renewed(None, now).unwrap());
    server.pair(&phone, "phone", somewhere(), &[]);
    client.pair(&desktop, "desktop", somewhere(), &[]);
    assert_ne!(server.identity.certificate(), desktop.certificate());
    let serving = serve(&server).await;

    let dialed = with_deadline("dial", client.dial("desktop", Some(serving.at), "/"))
        .await
        .unwrap();
    with_deadline("close", dialed.replica.close())
        .await
        .unwrap();
    // And the dialer carried the renewal forward.
    assert_eq!(
        client.paired("desktop").certificate(),
        server.identity.certificate()
    );
}
