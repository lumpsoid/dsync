//! The bounds on connections that have not authenticated: the handshake
//! deadline and the cap on connections mid-handshake.

use std::sync::Arc;
use std::time::Duration;

use dsync_core::{PeerEvent, PeerRefusal};
use dsync_domain::Tuning;
use rustls::ClientConnection;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::Instant;

use crate::support::{
    Host, identity, raw_client_config, raw_server_name, serve, serve_with, somewhere, with_deadline,
};

/// A handshake deadline short enough to wait out in real time. (The
/// default's own 10 s cut is proven under a paused clock in
/// `peer_listener`'s unit tests, over an in-memory stream: real sockets
/// and a paused clock race.)
const SHORT: Duration = Duration::from_millis(300);

fn short_deadline() -> Tuning {
    Tuning {
        handshake: SHORT,
        ..Tuning::DEFAULT
    }
}

/// Reads until the far side closes; how long that took.
async fn closed_after(stream: &mut TcpStream) -> Duration {
    let started = Instant::now();
    let mut sink = [0u8; 4096];
    while !matches!(stream.read(&mut sink).await, Ok(0) | Err(_)) {}
    started.elapsed()
}

fn cut_at(event: &PeerEvent) -> Option<Duration> {
    match event {
        PeerEvent::Refused {
            why: PeerRefusal::HandshakeTimedOut { limit },
            ..
        } => Some(*limit),
        _ => None,
    }
}

#[tokio::test]
async fn a_connection_that_never_speaks_is_cut_at_the_handshake_deadline() {
    let server = Host::new(identity("desktop"));
    let mut serving = serve_with(&server, short_deadline()).await;
    let mut silent = TcpStream::connect(serving.at).await.unwrap();

    let waited = with_deadline("the cut", closed_after(&mut silent)).await;
    assert!(waited >= SHORT, "{waited:?}");
    let event = serving.next_event().await;
    assert_eq!(cut_at(&event), Some(SHORT), "{event:?}");
    serving.assert_running();
}

#[tokio::test]
async fn a_peer_that_sends_its_first_flight_and_stalls_is_cut_at_the_deadline() {
    let server = Host::new(identity("desktop"));
    let mut serving = serve_with(&server, short_deadline()).await;
    let mut stalled = TcpStream::connect(serving.at).await.unwrap();
    let mut client =
        ClientConnection::new(Arc::new(raw_client_config(None)), raw_server_name()).unwrap();
    let mut hello = Vec::new();
    client.write_tls(&mut hello).unwrap();
    stalled.write_all(&hello).await.unwrap();

    // The listener answers the hello, then waits for a flight that never
    // comes - until the deadline.
    let waited = with_deadline("the cut", closed_after(&mut stalled)).await;
    assert!(waited >= SHORT, "{waited:?}");
    let event = serving.next_event().await;
    assert_eq!(cut_at(&event), Some(SHORT), "{event:?}");
}

#[tokio::test]
async fn a_slot_freed_by_the_deadline_takes_the_next_connection() {
    let server = Host::new(identity("desktop"));
    let tuning = Tuning {
        unauthenticated_connections: 1,
        ..short_deadline()
    };
    let mut serving = serve_with(&server, tuning).await;
    let mut first = TcpStream::connect(serving.at).await.unwrap();
    // While `first` holds the only slot, the next is refused at once...
    let mut over = TcpStream::connect(serving.at).await.unwrap();
    assert!(with_deadline("over", closed_after(&mut over)).await < SHORT);
    let event = serving.next_event().await;
    assert!(
        matches!(
            event,
            PeerEvent::Refused {
                why: PeerRefusal::OverCapacity { limit: 1 },
                ..
            }
        ),
        "{event:?}"
    );
    // ...and once the deadline frees it, the next takes it (and is cut at
    // its own deadline, not refused at accept).
    with_deadline("first", closed_after(&mut first)).await;
    let event = serving.next_event().await;
    assert!(cut_at(&event).is_some(), "{event:?}");
    let mut next = TcpStream::connect(serving.at).await.unwrap();
    assert!(with_deadline("next", closed_after(&mut next)).await >= SHORT);
    let event = serving.next_event().await;
    assert!(cut_at(&event).is_some(), "{event:?}");
}

#[tokio::test]
async fn the_connection_over_the_cap_is_refused_and_a_freed_slot_is_reusable() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    server.pair(&client.identity, "phone", somewhere(), &[]);
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let mut serving = serve(&server).await;
    let cap = Tuning::DEFAULT.unauthenticated_connections;

    // One short of the cap, a real peer still gets through (the positive
    // control), and an authenticated session holds no slot.
    let mut stalls = Vec::new();
    for _ in 0..cap - 1 {
        stalls.push(TcpStream::connect(serving.at).await.unwrap());
    }
    let served = with_deadline(
        "dial under the cap",
        client.dial("desktop", Some(serving.at), "/"),
    )
    .await
    .unwrap();
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Started { .. }
    ));

    // At the cap, the next connection is refused before any TLS.
    stalls.push(TcpStream::connect(serving.at).await.unwrap());
    let refused = with_deadline(
        "dial over the cap",
        client.dial("desktop", Some(serving.at), "/"),
    )
    .await;
    assert!(refused.is_err());
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Refused {
            why: PeerRefusal::OverCapacity { .. },
            ..
        }
    ));

    // A stall that gives up frees its slot.
    drop(stalls.pop());
    assert!(matches!(
        serving.next_event().await,
        PeerEvent::Refused {
            why: PeerRefusal::Handshake(_),
            ..
        }
    ));
    let again = with_deadline(
        "dial after a slot freed",
        client.dial("desktop", Some(serving.at), "/"),
    )
    .await
    .unwrap();
    with_deadline("close", again.replica.close()).await.unwrap();
    with_deadline("close", served.replica.close())
        .await
        .unwrap();
}
