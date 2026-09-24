//! The cap on connections that have not presented a token. (The handshake
//! deadline is proven under a paused clock in `enrolment_listener`'s unit
//! tests: real sockets and a paused clock race.)

use dsync_core::{EnrolmentEvent, EnrolmentRefusal};
use dsync_domain::Tuning;
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;

use crate::support::{Host, enrol_confirmed, show, with_deadline};

#[tokio::test]
async fn a_connection_over_the_cap_is_refused_at_accept_and_its_slot_comes_back() {
    let (desktop, phone) = (Host::new("desktop"), Host::new("phone"));
    let mut showing = show(&desktop, "phone").await;
    let limit = Tuning::DEFAULT.unauthenticated_connections;

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
