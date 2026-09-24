//! The listener: sessions served, the store re-read per connection (so
//! revocations and new pairings need no restart), and refusals that
//! never take it down - the cases of `agent_listener_secure_test`,
//! `agent_listener_secure_e2e_test` and the TLS half of
//! `agent_listener_test`.

use dsync_core::{CertificateRefusal, PeerDialError, PeerEvent, PeerRefusal, Replica};

use crate::support::{Host, identity, raw_tls, serve, somewhere, with_deadline};

/// A granted root under `server`, created.
fn granted_root(server: &Host) -> String {
    let root = server.root("notes");
    std::fs::create_dir_all(&root).unwrap();
    root.to_str().unwrap().to_owned()
}

#[tokio::test]
async fn a_paired_peer_is_served_a_session_that_starts_and_ends() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    let root = granted_root(&server);
    server.pair(
        &client.identity,
        "phone",
        somewhere(),
        &[server.root("notes").as_path()],
    );
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let mut serving = serve(&server).await;

    let dialed = with_deadline("dial", client.dial("desktop", Some(serving.at), &root))
        .await
        .unwrap();
    assert_eq!(dialed.device, server.identity.device_id());
    with_deadline("hello", dialed.replica.hello())
        .await
        .unwrap();
    with_deadline("close", dialed.replica.close())
        .await
        .unwrap();

    match serving.next_event().await {
        PeerEvent::Started { device, name, .. } => {
            assert_eq!(device, client.identity.device_id());
            assert_eq!(name.to_string(), "phone");
        }
        other => panic!("{other:?}"),
    }
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Ended {
            outcome: Ok(()),
            ..
        }
    ));
    assert_eq!(serving.opened(), 1);
}

#[tokio::test]
async fn two_devices_with_the_same_common_name_both_connect() {
    let server = Host::new(identity("desktop"));
    let one = Host::new(identity("dsync-app"));
    let two = Host::new(identity("dsync-app"));
    server.pair(&one.identity, "one", somewhere(), &[]);
    server.pair(&two.identity, "two", somewhere(), &[]);
    let serving = serve(&server).await;
    for client in [&one, &two] {
        client.pair(&server.identity, "desktop", somewhere(), &[]);
        let dialed = with_deadline("dial", client.dial("desktop", Some(serving.at), "/"))
            .await
            .unwrap();
        with_deadline("close", dialed.replica.close())
            .await
            .unwrap();
    }
}

#[tokio::test]
async fn a_device_revoked_after_bind_is_refused_on_its_next_connection() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    let root = granted_root(&server);
    server.pair(
        &client.identity,
        "phone",
        somewhere(),
        &[server.root("notes").as_path()],
    );
    // Another device stays paired: this is a revocation, not an empty store.
    server.pair(&identity("tablet"), "tablet", somewhere(), &[]);
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let mut serving = serve(&server).await;

    // Connected before the revocation: this is the positive control, and
    // a live session survives a revocation made under it.
    let live = with_deadline("dial", client.dial("desktop", Some(serving.at), &root))
        .await
        .unwrap();
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Started { .. }
    ));
    server.revoke(&client.identity);
    with_deadline("hello after revoke", live.replica.hello())
        .await
        .unwrap();

    let refused = with_deadline("dial", client.dial("desktop", Some(serving.at), &root)).await;
    assert!(
        matches!(refused, Err(PeerDialError::RefusedByPeer { .. })),
        "{:?}",
        refused.map(|_| ())
    );
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Refused {
            why: PeerRefusal::Certificate(CertificateRefusal::NotPinned(_)),
            ..
        }
    ));
    with_deadline("close", live.replica.close()).await.unwrap();
}

#[tokio::test]
async fn a_device_paired_after_bind_connects_with_no_restart() {
    let server = Host::new(identity("desktop"));
    let first = Host::new(identity("first"));
    let later = Host::new(identity("later"));
    server.pair(&first.identity, "first", somewhere(), &[]);
    let mut serving = serve(&server).await;
    later.pair(&server.identity, "desktop", somewhere(), &[]);

    let refused = with_deadline("dial", later.dial("desktop", Some(serving.at), "/")).await;
    assert!(refused.is_err());
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Refused { .. }
    ));

    server.pair(&later.identity, "later", somewhere(), &[]);
    let dialed = with_deadline("dial", later.dial("desktop", Some(serving.at), "/"))
        .await
        .unwrap();
    with_deadline("close", dialed.replica.close())
        .await
        .unwrap();
}

#[tokio::test]
async fn with_nothing_paired_the_refusal_says_so_and_pairing_is_enough() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let mut serving = serve(&server).await;

    let refused = with_deadline("dial", client.dial("desktop", Some(serving.at), "/")).await;
    assert!(refused.is_err());
    let event = serving.next_event().await;
    let PeerEvent::Refused {
        why: why @ PeerRefusal::NoDevicesPaired,
        ..
    } = &event
    else {
        panic!("{event:?}");
    };
    assert!(why.to_string().contains("no devices are paired"), "{why}");

    server.pair(&client.identity, "phone", somewhere(), &[]);
    let dialed = with_deadline("dial", client.dial("desktop", Some(serving.at), "/"))
        .await
        .unwrap();
    with_deadline("close", dialed.replica.close())
        .await
        .unwrap();
}

#[tokio::test]
async fn strangers_never_reach_the_factory_and_do_not_take_the_listener_down() {
    let server = Host::new(identity("desktop"));
    let paired = Host::new(identity("phone"));
    let root = granted_root(&server);
    server.pair(
        &paired.identity,
        "phone",
        somewhere(),
        &[server.root("notes").as_path()],
    );
    paired.pair(&server.identity, "desktop", somewhere(), &[]);
    let mut serving = serve(&server).await;

    // No certificate at all.
    let _anonymous = with_deadline("anonymous", raw_tls(serving.at, None)).await;
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Refused {
            why: PeerRefusal::Handshake(_),
            ..
        }
    ));
    // A well-formed identity never paired.
    let stranger = identity("stranger");
    let _stranger = with_deadline("stranger", raw_tls(serving.at, Some(&stranger))).await;
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Refused {
            why: PeerRefusal::Certificate(CertificateRefusal::NotPinned(_)),
            ..
        }
    ));
    // Bytes that are not TLS.
    let mut junk = tokio::net::TcpStream::connect(serving.at).await.unwrap();
    tokio::io::AsyncWriteExt::write_all(&mut junk, b"SSH-2.0-OpenSSH\r\n")
        .await
        .unwrap();
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Refused { .. }
    ));
    assert_eq!(serving.opened(), 0);
    serving.assert_running();

    // Positive control: the paired peer is served, factory and all.
    let dialed = with_deadline("dial", paired.dial("desktop", Some(serving.at), &root))
        .await
        .unwrap();
    with_deadline("hello", dialed.replica.hello())
        .await
        .unwrap();
    assert_eq!(serving.opened(), 1);
    with_deadline("close", dialed.replica.close())
        .await
        .unwrap();
}

#[tokio::test]
async fn a_client_that_drops_holding_the_lock_leaves_it_free_for_the_next() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    let root = granted_root(&server);
    server.pair(
        &client.identity,
        "phone",
        somewhere(),
        &[server.root("notes").as_path()],
    );
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let mut serving = serve(&server).await;

    let dropped = with_deadline("dial", client.dial("desktop", Some(serving.at), &root))
        .await
        .unwrap();
    with_deadline("hello", dropped.replica.hello())
        .await
        .unwrap();
    with_deadline("lock", dropped.replica.lock()).await.unwrap();
    drop(dropped);
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Started { .. }
    ));
    // The session that failed is reported, and the listener stays up.
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Ended { .. }
    ));
    serving.assert_running();

    let next = with_deadline(
        "dial again",
        client.dial("desktop", Some(serving.at), &root),
    )
    .await
    .unwrap();
    with_deadline("hello", next.replica.hello()).await.unwrap();
    with_deadline("lock", next.replica.lock()).await.unwrap();
    with_deadline("unlock", next.replica.unlock())
        .await
        .unwrap();
    with_deadline("close", next.replica.close()).await.unwrap();
}

#[tokio::test]
async fn two_sessions_are_served_at_once() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    server.pair(&client.identity, "phone", somewhere(), &[]);
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let serving = serve(&server).await;
    let (one, two) = with_deadline("two dials", async {
        tokio::join!(
            client.dial("desktop", Some(serving.at), "/"),
            client.dial("desktop", Some(serving.at), "/")
        )
    })
    .await;
    let (one, two) = (one.unwrap(), two.unwrap());
    with_deadline("close", one.replica.close()).await.unwrap();
    with_deadline("close", two.replica.close()).await.unwrap();
}
