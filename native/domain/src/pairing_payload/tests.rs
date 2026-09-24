//! Every case of `test/dsync_core/identity/pairing_payload_test.dart`,
//! bumped to v3, plus the fields the v3 layout refuses outright.

use super::*;

/// Stands in for a certificate: the payload carries the DER, it never
/// parses it (the enrolment's pin does).
fn certificate() -> Vec<u8> {
    (0..300u32).map(|i| (i * 31 % 251) as u8).collect()
}

fn token() -> EnrolmentToken {
    EnrolmentToken::from_bytes(std::array::from_fn(|i| (i * 7 % 256) as u8))
}

fn payload(host: &str, port: u16, service_port: u16) -> PairingPayload {
    PairingPayload::new(
        certificate(),
        PeerAddress::new(host, port).unwrap(),
        service_port,
        token(),
    )
    .unwrap()
}

fn sample() -> PairingPayload {
    payload("192.168.1.5", 51234, 28771)
}

fn body_of(text: &str) -> Vec<u8> {
    STANDARD.decode(text.split(':').nth(2).unwrap()).unwrap()
}

fn with_body(version: &str, bytes: &[u8]) -> String {
    format!("{MAGIC}:{version}:{}", STANDARD.encode(bytes))
}

#[test]
fn construction_rejects_an_empty_certificate() {
    let built = PairingPayload::new(
        Vec::new(),
        PeerAddress::new("h", 1).unwrap(),
        28771,
        token(),
    );
    assert_eq!(built.unwrap_err(), PairingPayloadError::EmptyCertificate);
}

#[test]
fn construction_rejects_a_service_port_no_socket_could_use() {
    let built = PairingPayload::new(certificate(), PeerAddress::new("h", 1).unwrap(), 0, token());
    assert_eq!(
        built.unwrap_err(),
        PairingPayloadError::Address(PeerAddressError::ZeroPort)
    );
}

#[test]
fn construction_rejects_fields_the_layout_cannot_carry() {
    let huge = vec![1u8; usize::from(u16::MAX) + 1];
    let at = PeerAddress::new("h", 1).unwrap();
    assert_eq!(
        PairingPayload::new(huge, at.clone(), 2, token()).unwrap_err(),
        PairingPayloadError::CertificateTooLarge(usize::from(u16::MAX) + 1)
    );
    let long_host = PeerAddress::new(&"h".repeat(256), 1).unwrap();
    assert_eq!(
        PairingPayload::new(certificate(), long_host, 2, token()).unwrap_err(),
        PairingPayloadError::HostTooLong(256)
    );
    // Positive control: the largest of each still builds and round-trips.
    let widest = PairingPayload::new(
        vec![1u8; usize::from(u16::MAX)],
        PeerAddress::new(&"h".repeat(255), 1).unwrap(),
        2,
        token(),
    )
    .unwrap();
    let decoded = PairingPayload::decode(&widest.encode()).unwrap();
    assert_eq!(decoded.certificate_der().len(), usize::from(u16::MAX));
    assert_eq!(decoded.address().host().len(), 255);
}

#[test]
fn it_serves_from_the_same_host_as_the_enrolment_endpoint() {
    let p = payload("10.0.0.9", 51234, 28771);
    assert_eq!(p.service_address().host(), "10.0.0.9");
    assert_eq!(p.service_address().port(), 28771);
    assert_eq!(p.address().port(), 51234);
}

#[test]
fn encode_is_one_line_of_plain_base64_ascii() {
    let text = sample().encode();
    assert!(!text.contains('\n'));
    let body = text.strip_prefix("dsync-pair:v3:").expect("the v3 prefix");
    assert!(STANDARD.decode(body).is_ok());
    assert!(
        body.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=')
    );
}

#[test]
fn decode_of_encode_reproduces_every_field() {
    let original = payload("10.0.0.9", 9000, 40);
    let decoded = PairingPayload::decode(&original.encode()).unwrap();
    assert_eq!(decoded.certificate_der(), original.certificate_der());
    assert_eq!(decoded.address(), original.address());
    assert_eq!(decoded.service_address().host(), "10.0.0.9");
    assert_eq!(decoded.service_address().port(), 40);
    assert_eq!(decoded.token().as_bytes(), original.token().as_bytes());
}

#[test]
fn a_host_containing_a_colon_round_trips() {
    let decoded = PairingPayload::decode(&payload("::1", 9000, 40).encode()).unwrap();
    assert_eq!(decoded.address().host(), "::1");
}

#[test]
fn surrounding_whitespace_is_ignored() {
    let text = format!("  {}\n", sample().encode());
    assert!(PairingPayload::decode(&text).is_ok());
}

#[test]
fn text_that_is_not_a_payload_is_refused() {
    for text in ["not-dsync-pair:v3:AAAA", "dsync-pair:v3", ""] {
        assert_eq!(
            PairingPayload::decode(text).unwrap_err(),
            PairingPayloadError::NotAPayload,
            "{text:?}"
        );
    }
}

#[test]
fn a_v2_payload_is_refused_as_from_an_older_dsync() {
    let body = body_of(&sample().encode());
    let refused = PairingPayload::decode(&with_body("v2", &body)).unwrap_err();
    assert_eq!(refused, PairingPayloadError::OlderVersion("v2".into()));
    assert!(refused.to_string().contains("older dsync"), "{refused}");
    // Positive control: the same body under v3 decodes.
    assert!(PairingPayload::decode(&with_body("v3", &body)).is_ok());
}

#[test]
fn other_versions_are_refused() {
    let body = body_of(&sample().encode());
    assert_eq!(
        PairingPayload::decode(&with_body("v1", &body)).unwrap_err(),
        PairingPayloadError::OlderVersion("v1".into())
    );
    assert_eq!(
        PairingPayload::decode(&with_body("v4", &body)).unwrap_err(),
        PairingPayloadError::NewerVersion("v4".into())
    );
    assert_eq!(
        PairingPayload::decode(&with_body("vx", &body)).unwrap_err(),
        PairingPayloadError::UnknownVersion("vx".into())
    );
}

#[test]
fn corrupt_base64_is_refused() {
    assert!(matches!(
        PairingPayload::decode("dsync-pair:v3:not-valid-base64!!!"),
        Err(PairingPayloadError::Base64(_))
    ));
}

#[test]
fn a_payload_truncated_inside_the_layout_is_refused() {
    let body = body_of(&sample().encode());
    assert_eq!(
        PairingPayload::decode(&with_body("v3", &body[..4])).unwrap_err(),
        PairingPayloadError::Truncated
    );
    // Cut inside the token: every field before it is whole.
    assert_eq!(
        PairingPayload::decode(&with_body("v3", &body[..body.len() - 1])).unwrap_err(),
        PairingPayloadError::Truncated
    );
}

#[test]
fn a_length_prefix_that_overruns_what_is_there_is_refused() {
    let mut body = body_of(&sample().encode());
    body[0] = 0xff;
    body[1] = 0xff;
    assert_eq!(
        PairingPayload::decode(&with_body("v3", &body)).unwrap_err(),
        PairingPayloadError::Truncated
    );
}

#[test]
fn bytes_past_the_token_are_refused() {
    let mut body = body_of(&sample().encode());
    body.push(0);
    assert_eq!(
        PairingPayload::decode(&with_body("v3", &body)).unwrap_err(),
        PairingPayloadError::TrailingBytes(1)
    );
}

#[test]
fn a_token_of_any_other_length_is_refused() {
    let body = body_of(&sample().encode());
    let before_token = body.len() - EnrolmentToken::LEN - 1;
    for len in [0usize, 15, 17] {
        let mut resized = body[..before_token].to_vec();
        resized.push(len as u8);
        resized.extend(std::iter::repeat_n(7u8, len));
        assert_eq!(
            PairingPayload::decode(&with_body("v3", &resized)).unwrap_err(),
            PairingPayloadError::TokenLength(len),
            "{len}"
        );
    }
}

#[test]
fn a_zero_port_in_the_body_is_refused() {
    let body = body_of(&sample().encode());
    let service_port_at = body.len() - EnrolmentToken::LEN - 1 - 2;
    let mut zeroed = body.clone();
    zeroed[service_port_at] = 0;
    zeroed[service_port_at + 1] = 0;
    assert_eq!(
        PairingPayload::decode(&with_body("v3", &zeroed)).unwrap_err(),
        PairingPayloadError::Address(PeerAddressError::ZeroPort)
    );
}

#[test]
fn the_token_is_not_printed() {
    assert_eq!(format!("{:?}", token()), "EnrolmentToken(..)");
}
