//! The enrolment exchange end to end: what each side records, and every
//! way the token, the operator and the pin turn an enrolment away.

use std::time::Duration;

use dsync_core::{
    EnrolError, EnrolmentBindError, EnrolmentDenial, EnrolmentEnd, EnrolmentEvent,
    EnrolmentListener, EnrolmentRefusal, PairedDeviceStoreError, PairingError, TokenRefusal,
    read_pair_code,
};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{EnrolmentToken, PairCode, PairingPayload, Tuning};

use crate::support::{
    Host, SERVICE_PORT, enrol_confirmed, loopback, name, show, show_with, with_deadline,
};

fn token_refusal(event: EnrolmentEvent) -> Option<TokenRefusal> {
    match event {
        EnrolmentEvent::Refused {
            why: EnrolmentRefusal::Token(why),
            ..
        } => Some(why),
        _ => None,
    }
}

fn with_token(payload: &PairingPayload, token: [u8; EnrolmentToken::LEN]) -> PairingPayload {
    PairingPayload::new(
        payload.certificate_der().to_vec(),
        payload.address().clone(),
        payload.service_address().port(),
        EnrolmentToken::from_bytes(token),
    )
    .unwrap()
}

#[tokio::test]
async fn a_confirmed_enrolment_leaves_each_side_holding_the_other() {
    let (desktop, phone) = (Host::new("desktop"), Host::new("phone"));
    let mut showing = show(&desktop, "my phone").await;

    let payload = showing.payload.clone();
    let enrolling = phone.enrol(&payload, "my desktop");
    let operating = async {
        let (pending, answer) = showing.next_question().await;
        // Before the operator answers, nothing is stored on either side.
        assert!(desktop.paired().is_empty());
        assert!(phone.paired().is_empty());
        answer.send(true).unwrap();
        pending
    };
    let (enrolled, pending) = with_deadline("the enrolment", async {
        tokio::join!(enrolling, operating)
    })
    .await;

    // The operator compared the phone's own id, under this side's name.
    assert_eq!(pending.device, phone.identity.device_id());
    assert_eq!(pending.name, name("my phone"));

    let on_desktop = desktop.paired();
    assert_eq!(on_desktop.len(), 1);
    assert_eq!(on_desktop[0].device_id(), phone.identity.device_id());
    assert_eq!(on_desktop[0].certificate(), phone.identity.certificate());
    assert_eq!(on_desktop[0].name(), &name("my phone"));
    assert_eq!(
        on_desktop[0].last_known_address(),
        &PeerAddress::with_default_port("127.0.0.1").unwrap()
    );
    assert!(on_desktop[0].granted_roots().is_empty());

    let on_phone = phone.paired();
    assert_eq!(on_phone, vec![enrolled.unwrap()]);
    assert_eq!(on_phone[0].device_id(), desktop.identity.device_id());
    assert_eq!(on_phone[0].certificate(), desktop.identity.certificate());
    assert_eq!(on_phone[0].name(), &name("my desktop"));
    // Its serving address from the payload, not the one-shot enrolment
    // endpoint this exchange connected to.
    assert_eq!(on_phone[0].last_known_address().port(), SERVICE_PORT);
    assert_ne!(on_phone[0].last_known_address().port(), showing.at.port());

    assert!(
        matches!(showing.ended().await, EnrolmentEnd::Enrolled(device)
        if device.device_id() == phone.identity.device_id())
    );
}

#[tokio::test]
async fn a_wrong_token_is_refused_and_does_not_spend_the_right_one() {
    let (desktop, phone) = (Host::new("desktop"), Host::new("phone"));
    let mut showing = show(&desktop, "phone").await;
    let mut wrong = *showing.payload.token().as_bytes();
    wrong[0] ^= 1;

    let refused = with_deadline(
        "the wrong token",
        phone.enrol(&with_token(&showing.payload, wrong), "desktop"),
    )
    .await;
    assert!(
        matches!(
            refused,
            Err(EnrolError::Denied(EnrolmentDenial::TokenRejected))
        ),
        "{refused:?}"
    );
    assert_eq!(
        token_refusal(showing.next_event().await),
        Some(TokenRefusal::Wrong)
    );
    assert!(desktop.paired().is_empty());
    assert!(phone.paired().is_empty());

    // Positive control: the right token, on the same listener, pairs.
    let enrolled = enrol_confirmed(&phone, &mut showing, "desktop").await;
    assert!(enrolled.is_ok(), "{enrolled:?}");
    assert_eq!(desktop.paired().len(), 1);
}

#[tokio::test]
async fn a_token_is_spent_at_redemption_so_a_second_redeemer_is_refused() {
    let desktop = Host::new("desktop");
    let (first, second) = (Host::new("phone"), Host::new("thief"));
    let mut showing = show(&desktop, "phone").await;

    let payload = showing.payload.clone();
    let enrolling = first.enrol(&payload, "desktop");
    let operating = async {
        // The first redeemer is waiting on the operator; the token is
        // already spent.
        let (pending, answer) = showing.next_question().await;
        let reused = second.enrol(&payload, "desktop").await;
        assert!(
            matches!(
                reused,
                Err(EnrolError::Denied(EnrolmentDenial::TokenRejected))
            ),
            "{reused:?}"
        );
        assert_eq!(
            token_refusal(showing.next_event().await),
            Some(TokenRefusal::Burned)
        );
        answer.send(true).unwrap();
        pending
    };
    let (enrolled, pending) = with_deadline("the enrolment", async {
        tokio::join!(enrolling, operating)
    })
    .await;

    assert!(enrolled.is_ok(), "{enrolled:?}");
    assert_eq!(pending.device, first.identity.device_id());
    let on_desktop = desktop.paired();
    assert_eq!(on_desktop.len(), 1);
    assert_eq!(on_desktop[0].device_id(), first.identity.device_id());
    assert!(second.paired().is_empty());
    assert!(matches!(showing.ended().await, EnrolmentEnd::Enrolled(_)));
}

#[tokio::test]
async fn a_declined_enrolment_stores_nothing_on_either_side_and_burns_the_token() {
    let desktop = Host::new("desktop");
    let (phone, retry) = (Host::new("phone"), Host::new("retry"));
    let mut showing = show(&desktop, "phone").await;

    let payload = showing.payload.clone();
    let enrolling = phone.enrol(&payload, "desktop");
    let operating = async {
        let (_, answer) = showing.next_question().await;
        answer.send(false).unwrap();
    };
    let (declined, ()) = with_deadline("the enrolment", async {
        tokio::join!(enrolling, operating)
    })
    .await;
    assert!(
        matches!(declined, Err(EnrolError::Denied(EnrolmentDenial::Declined))),
        "{declined:?}"
    );
    assert!(desktop.paired().is_empty());
    assert!(phone.paired().is_empty());
    assert!(
        matches!(showing.ended().await, EnrolmentEnd::Declined { device }
        if device == phone.identity.device_id())
    );

    // The pairing is over: the listener is closed, so the token cannot be
    // tried again (its burn before the answer is the previous test's).
    assert!(!showing.is_open());
    let again = with_deadline("the retry", retry.enrol(&showing.payload, "desktop")).await;
    assert!(
        matches!(again, Err(EnrolError::Unreachable { .. })),
        "{again:?}"
    );
    assert!(desktop.paired().is_empty());
}

#[tokio::test]
async fn a_listener_that_does_not_hold_the_payload_s_key_never_receives_the_token() {
    let (desktop, impostor, phone) = (
        Host::new("desktop"),
        Host::new("desktop"),
        Host::new("phone"),
    );
    let mut showing = show(&impostor, "phone").await;
    // The real desktop's certificate, the impostor's endpoint and token:
    // a payload relayed through someone who swapped the address.
    let relayed = PairingPayload::new(
        desktop.identity.certificate().der().to_vec(),
        showing.payload.address().clone(),
        SERVICE_PORT,
        showing.payload.token().clone(),
    )
    .unwrap();

    let refused = with_deadline("the impostor", phone.enrol(&relayed, "desktop")).await;
    match refused {
        Err(EnrolError::Impostor {
            expected,
            presented,
            ..
        }) => {
            assert_eq!(expected, desktop.identity.device_id());
            assert_eq!(presented, impostor.identity.device_id());
        }
        other => panic!("{other:?}"),
    }
    // The impostor saw a failed handshake, never a token.
    assert!(matches!(
        showing.next_event().await,
        EnrolmentEvent::Refused {
            why: EnrolmentRefusal::Handshake(_),
            ..
        }
    ));
    assert!(phone.paired().is_empty());

    // Positive control: the impostor's own payload (its own key) pairs -
    // so its token was still unspent, i.e. never sent.
    let enrolled = enrol_confirmed(&phone, &mut showing, "desktop").await;
    assert!(enrolled.is_ok(), "{enrolled:?}");
}

#[tokio::test]
async fn a_name_already_paired_here_is_refused_before_the_token_is_spent() {
    let (desktop, phone, other) = (Host::new("desktop"), Host::new("phone"), Host::new("other"));
    let mut elsewhere = show(&other, "phone").await;
    let first = enrol_confirmed(&phone, &mut elsewhere, "desktop").await;
    first.unwrap();

    let mut showing = show(&desktop, "phone").await;
    let taken = with_deadline("the taken name", phone.enrol(&showing.payload, "desktop")).await;
    assert!(
        matches!(
            taken,
            Err(EnrolError::Store(PairedDeviceStoreError::Pairing(
                PairingError::NameTaken(_)
            )))
        ),
        "{taken:?}"
    );

    // Positive control: another name pairs with the same, unspent token.
    let enrolled = enrol_confirmed(&phone, &mut showing, "studio").await;
    assert!(enrolled.is_ok(), "{enrolled:?}");
    assert_eq!(phone.paired().len(), 2);
}

#[tokio::test]
async fn a_name_already_paired_on_the_showing_side_is_refused_at_bind() {
    let (desktop, phone) = (Host::new("desktop"), Host::new("phone"));
    let mut showing = show(&desktop, "phone").await;
    let enrolled = enrol_confirmed(&phone, &mut showing, "desktop").await;
    enrolled.unwrap();

    let bind = |label: &str| {
        EnrolmentListener::bind(
            loopback(),
            desktop.identity.clone(),
            desktop.store.clone(),
            name(label),
            Tuning::DEFAULT,
        )
    };
    let taken = with_deadline("the taken name", bind("phone")).await;
    assert!(
        matches!(&taken, Err(EnrolmentBindError::NameTaken(n)) if *n == name("phone")),
        "{:?}",
        taken.err()
    );
    // Positive control: a free name binds.
    assert!(with_deadline("a free name", bind("tablet")).await.is_ok());
}

#[tokio::test]
async fn a_token_nobody_redeems_ends_the_pairing_when_it_expires() {
    let desktop = Host::new("desktop");
    let window = Duration::from_millis(300);
    let mut showing = show_with(
        &desktop,
        "phone",
        Tuning {
            pairing_token: window,
            ..Tuning::DEFAULT
        },
    )
    .await;
    assert!(matches!(showing.ended().await, EnrolmentEnd::Expired));
}

#[tokio::test]
async fn a_payload_whose_certificate_is_unreadable_is_refused_before_dialling() {
    let (desktop, phone) = (Host::new("desktop"), Host::new("phone"));
    let mut showing = show(&desktop, "phone").await;
    let broken = PairingPayload::new(
        b"not a certificate".to_vec(),
        showing.payload.address().clone(),
        SERVICE_PORT,
        showing.payload.token().clone(),
    )
    .unwrap();
    let refused = with_deadline("the broken payload", phone.enrol(&broken, "desktop")).await;
    assert!(
        matches!(refused, Err(EnrolError::PayloadCertificate(_))),
        "{refused:?}"
    );

    // Positive control: nothing reached the listener, whose token still pairs.
    let enrolled = enrol_confirmed(&phone, &mut showing, "desktop").await;
    assert!(enrolled.is_ok(), "{enrolled:?}");
}

#[tokio::test]
async fn a_pair_code_offers_the_name_the_showing_device_gave_itself() {
    let desktop = Host::new("studio.local");
    let showing = show(&desktop, "phone").await;
    let PairCode::Read(read) = read_pair_code(&showing.payload.encode()) else {
        panic!("the code should read");
    };
    assert_eq!(read.desktop_name(), "studio");
    assert_eq!(read.address().port(), SERVICE_PORT);
    assert!(matches!(
        read_pair_code("dsync-pair:0.9:AAAA"),
        PairCode::Unreadable(_)
    ));
}
