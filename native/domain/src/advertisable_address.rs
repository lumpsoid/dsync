//! Which host a pairing payload advertises (SPEC §4.4). Two rules over
//! plain values: what the operator already chose, and - when they chose
//! nothing - which of this machine's interface addresses (fetched by the
//! core) to guess.

use std::net::IpAddr;

use crate::host_port::{is_wildcard_address, normalized_host};

/// The host the operator already chose, or `None` when the caller should
/// guess with [`preferred_advertisable_address`].
///
/// - `--advertise` wins outright, loopback or not, held here or not ("the
///   tunnel address that is not up yet" is a legitimate thing to mean). A
///   blank one is the same as none.
/// - Otherwise a listener bound to one interface answers at exactly that
///   address, so advertising any other would name somewhere it is not
///   listening. A wildcard bind says nothing, so it falls through.
pub fn chosen_advertisable_host(advertise: Option<&str>, bind: IpAddr) -> Option<String> {
    match advertise.map(str::trim).filter(|text| !text.is_empty()) {
        Some(explicit) => Some(normalized_host(explicit)),
        None if is_wildcard_address(bind) => None,
        None => Some(normalized_host(&bind.to_string())),
    }
}

/// The best guess among this machine's interface `addresses` at one a
/// peer could dial: the first IPv4 one, else the first routable IPv6 one,
/// else `None`. Never loopback (only useful to a peer on this same machine;
/// the caller falls back to it explicitly). Never an IPv6 link-local
/// (`fe80::/10`) one: it is not dialable without the interface's scope id,
/// which no payload carries - unlike IPv4 link-local, which at least
/// reaches the same segment.
///
/// IPv4 first because the far end may have no IPv6 route at all. A host
/// with several addresses is where no ordering can be right, and the
/// answer there is `--advertise` or a specific `--bind`, not a cleverer
/// rule here.
pub fn preferred_advertisable_address(addresses: &[IpAddr]) -> Option<IpAddr> {
    let candidates = || addresses.iter().filter(|address| !address.is_loopback());
    candidates()
        .find(|address| address.is_ipv4())
        .or_else(|| {
            candidates().find(|address| match address {
                IpAddr::V6(v6) => !v6.is_unicast_link_local(),
                IpAddr::V4(_) => false,
            })
        })
        .copied()
}

#[cfg(test)]
mod tests {
    //! Every case of `test/dsync_core/identity/advertisable_address_test.dart`,
    //! the interface guess now over plain values.

    use std::net::{Ipv4Addr, Ipv6Addr};

    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn a_wildcard_bind_and_no_advertise_leaves_the_caller_to_probe() {
        assert_eq!(
            chosen_advertisable_host(None, IpAddr::V4(Ipv4Addr::UNSPECIFIED)),
            None
        );
        assert_eq!(
            chosen_advertisable_host(None, IpAddr::V6(Ipv6Addr::UNSPECIFIED)),
            None
        );
    }

    #[test]
    fn a_bind_to_one_interface_is_what_gets_advertised() {
        assert_eq!(
            chosen_advertisable_host(None, ip("10.8.0.3")).as_deref(),
            Some("10.8.0.3")
        );
        assert_eq!(
            chosen_advertisable_host(None, ip("fd00::5")).as_deref(),
            Some("fd00::5")
        );
    }

    #[test]
    fn advertise_beats_a_wildcard_bind_and_a_specific_one_alike() {
        for bind in [ip("0.0.0.0"), ip("10.8.0.3")] {
            assert_eq!(
                chosen_advertisable_host(Some("203.0.113.7"), bind).as_deref(),
                Some("203.0.113.7")
            );
        }
    }

    #[test]
    fn a_blank_advertise_is_the_same_as_not_saying() {
        assert_eq!(chosen_advertisable_host(Some("  "), ip("0.0.0.0")), None);
        assert_eq!(chosen_advertisable_host(Some(""), ip("0.0.0.0")), None);
    }

    #[test]
    fn normalizes_an_ipv4_mapped_literal_either_way_it_arrives() {
        assert_eq!(
            chosen_advertisable_host(Some("::ffff:10.0.0.1"), ip("0.0.0.0")).as_deref(),
            Some("10.0.0.1")
        );
        assert_eq!(
            chosen_advertisable_host(None, ip("::ffff:10.0.0.1")).as_deref(),
            Some("10.0.0.1")
        );
    }

    #[test]
    fn prefers_ipv4_then_a_routable_ipv6_and_never_loopback_or_v6_link_local() {
        let v4 = ip("192.168.1.5");
        let v6 = ip("2001:db8::7");
        let link_local = ip("fe80::1");
        let loopbacks = [ip("127.0.0.1"), ip("::1")];

        let all = [loopbacks[0], link_local, v6, v4];
        assert_eq!(preferred_advertisable_address(&all), Some(v4));
        assert_eq!(
            preferred_advertisable_address(&[loopbacks[1], link_local, v6]),
            Some(v6)
        );
        assert_eq!(preferred_advertisable_address(&[link_local]), None);
        assert_eq!(preferred_advertisable_address(&loopbacks), None);
        assert_eq!(preferred_advertisable_address(&[]), None);
        // IPv4 link-local still reaches the same segment.
        assert_eq!(
            preferred_advertisable_address(&[ip("169.254.3.4")]),
            Some(ip("169.254.3.4"))
        );
    }
}
