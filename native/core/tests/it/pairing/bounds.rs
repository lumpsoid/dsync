//! The cap on connections that have not presented a token. (The handshake
//! deadline is proven under a paused clock in `enrolment_listener`'s unit
//! tests: real sockets and a paused clock race.)

use dsync_core::{EnrolmentEvent, EnrolmentRefusal};
use dsync_domain::Tuning;
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;

use crate::pairing::support::{Host, enrol_confirmed, show_with, with_deadline};

#[tokio::test]
async fn a_connection_over_the_cap_is_refused_at_accept_and_its_slot_comes_back() {
    let (desktop, phone) = (Host::new("desktop"), Host::new("phone"));
    let limit = Tuning::DEFAULT.unauthenticated_connections;
    // Every connection here is from loopback: the per-address cap is
    // lifted past the global one so this proves the global cap alone.
    let tuning = Tuning {
        unauthenticated_per_address: limit + 1,
        ..Tuning::DEFAULT
    };
    let mut showing = show_with(&desktop, "phone", tuning).await;

    let mut silent = Vec::new();
    for _ in 0..limit {
        silent.push(TcpStream::connect(showing.at).await.unwrap());
    }
    let mut over = TcpStream::connect(showing.at).await.unwrap();
    let event = showing.next_event().await;
    assert!(
        matches!(event, EnrolmentEvent::Refused { why: EnrolmentRefusal::OverCapacity { limit: l }, .. } if l == limit),
        "{event:?}"
    );
    let mut sink = [0u8; 1];
    let read = with_deadline("the refused connection closing", over.read(&mut sink)).await;
    assert!(matches!(read, Ok(0) | Err(_)), "{read:?}");

    // The silent ones leave; each frees its slot as its handshake fails.
    drop(silent);
    for _ in 0..limit {
        let event = showing.next_event().await;
        assert!(
            matches!(
                event,
                EnrolmentEvent::Refused {
                    why: EnrolmentRefusal::Handshake(_),
                    ..
                }
            ),
            "{event:?}"
        );
    }
    // Positive control: a real enrolment now gets in.
    let enrolled = enrol_confirmed(&phone, &mut showing, "desktop").await;
    assert!(enrolled.is_ok(), "{enrolled:?}");
}

#[tokio::test]
async fn an_address_over_its_cap_is_refused_at_accept() {
    let desktop = Host::new("desktop");
    let mut showing = show_with(
        &desktop,
        "phone",
        Tuning {
            unauthenticated_per_address: 2,
            ..Tuning::DEFAULT
        },
    )
    .await;
    let _held = [
        TcpStream::connect(showing.at).await.unwrap(),
        TcpStream::connect(showing.at).await.unwrap(),
    ];
    let mut third = TcpStream::connect(showing.at).await.unwrap();
    let event = showing.next_event().await;
    assert!(
        matches!(
            event,
            EnrolmentEvent::Refused {
                why: EnrolmentRefusal::OverAddressCapacity { limit: 2 },
                ..
            }
        ),
        "{event:?}"
    );
    let mut sink = [0u8; 1];
    let read = with_deadline("the refused connection closing", third.read(&mut sink)).await;
    assert!(matches!(read, Ok(0) | Err(_)), "{read:?}");
}
