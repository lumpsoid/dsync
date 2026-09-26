//! What the accepting side makes of a pairing code before redeeming it
//! (SPEC §4.4): the device it names and where that device answers, shown
//! to the user before anything is sent, and the name to offer for it.
//!
//! "Nothing scanned yet" is the caller's `Option<PairCode>`, not a case
//! here.

use crate::host_port::PeerAddress;
use crate::pairing_payload::{PairingPayload, PairingPayloadError};

/// A text the user scanned or pasted, as the pairing screen shows it.
#[derive(Clone, Debug)]
pub enum PairCode {
    /// Not a payload this build can use; the decode error says which way.
    Unreadable(PairingPayloadError),
    Read(ReadPairCode),
}

/// A payload that decoded, with what the user checks before redeeming it.
/// Derived at construction, so the card and the exchange that follows
/// cannot describe two different devices.
#[derive(Clone, Debug)]
pub struct ReadPairCode {
    payload: PairingPayload,
    desktop_name: String,
}

impl PairCode {
    /// `common_name` reads the subject common name out of a certificate's
    /// DER (X.509 parsing is the core's; `None` for bytes that are not a
    /// certificate or carry no name).
    pub fn read(text: &str, common_name: impl FnOnce(&[u8]) -> Option<String>) -> PairCode {
        match PairingPayload::decode(text) {
            Err(error) => PairCode::Unreadable(error),
            Ok(payload) => {
                let desktop_name =
                    default_peer_name(common_name(payload.certificate_der()).as_deref(), &payload);
                PairCode::Read(ReadPairCode {
                    payload,
                    desktop_name,
                })
            }
        }
    }
}

impl ReadPairCode {
    /// The decoded payload, for the enrolment that redeems it.
    pub fn payload(&self) -> &PairingPayload {
        &self.payload
    }

    /// What the showing device calls itself: the name field's default.
    pub fn desktop_name(&self) -> &str {
        &self.desktop_name
    }

    /// Where the device will answer from now on (its peer:// address, not
    /// the one-shot enrolment endpoint): the address the pairing leaves
    /// behind, shown before anything is sent.
    pub fn address(&self) -> &PeerAddress {
        self.payload.service_address()
    }
}

/// The name to offer for the device that showed `payload`, whose
/// certificate's common name is `common_name`: that name (the showing
/// device names its identity after its host), without an mDNS `.local`
/// suffix; else the payload's host - a poor name but a true one. Only a
/// default for an editable field, so an unreadable name is an empty offer
/// that falls back, never an error.
pub fn default_peer_name(common_name: Option<&str>, payload: &PairingPayload) -> String {
    let name = without_local_suffix(common_name.unwrap_or("").trim());
    if name.is_empty() {
        payload.address().host().to_owned()
    } else {
        name.to_owned()
    }
}

const LOCAL_SUFFIX: &str = ".local";

fn without_local_suffix(name: &str) -> &str {
    let cut = name.len().saturating_sub(LOCAL_SUFFIX.len());
    match name.get(cut..) {
        Some(suffix) if cut > 0 && suffix.eq_ignore_ascii_case(LOCAL_SUFFIX) => &name[..cut],
        _ => name,
    }
}

#[cfg(test)]
mod tests {
    //! Every case of `test/app/features/pair/default_names_test.dart`, and
    //! `pair_code.dart`'s two cases.

    use super::*;
    use crate::pairing_payload::EnrolmentToken;

    fn payload() -> PairingPayload {
        PairingPayload::new(
            vec![9, 9, 9],
            PeerAddress::new("192.168.1.5", 51234).unwrap(),
            28771,
            EnrolmentToken::from_bytes([1; EnrolmentToken::LEN]),
        )
        .unwrap()
    }

    #[test]
    fn the_default_is_the_name_the_desktop_gave_its_certificate() {
        assert_eq!(default_peer_name(Some("studio"), &payload()), "studio");
    }

    #[test]
    fn the_default_falls_back_to_the_address_hint_without_a_readable_name() {
        assert_eq!(default_peer_name(None, &payload()), "192.168.1.5");
        assert_eq!(default_peer_name(Some("  "), &payload()), "192.168.1.5");
    }

    #[test]
    fn an_mdns_suffix_is_the_network_s_not_the_device_s() {
        assert_eq!(
            default_peer_name(Some("studio.local"), &payload()),
            "studio"
        );
        assert_eq!(
            default_peer_name(Some("Studio.LOCAL"), &payload()),
            "Studio"
        );
        // A name that is only the suffix is kept, not emptied.
        assert_eq!(default_peer_name(Some(".local"), &payload()), ".local");
    }

    #[test]
    fn a_read_code_shows_the_device_and_its_serving_address() {
        let text = payload().encode();
        let PairCode::Read(read) = PairCode::read(&text, |der| {
            assert_eq!(der, [9, 9, 9]);
            Some("studio".into())
        }) else {
            panic!("the code should read");
        };
        assert_eq!(read.desktop_name(), "studio");
        assert_eq!(read.address().to_string(), "192.168.1.5:28771");
        assert_eq!(read.payload().address().port(), 51234);
    }

    #[test]
    fn an_unreadable_code_carries_the_decode_error() {
        let code = PairCode::read("dsync-pair:0.9:AAAA", |_| None);
        assert!(matches!(
            code,
            PairCode::Unreadable(PairingPayloadError::OlderVersion(_))
        ));
    }
}
