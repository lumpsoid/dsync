//! `host:port` text, both ways, and the host literal rules around it.
//!
//! One place for these because an IPv6 literal already contains colons:
//! `format!("{host}:{port}")` gives `fe80::1:28771`, which nothing can read
//! back reliably. Pure: an [`IpAddr`] here is a parsed literal, never a
//! resolution.

use std::fmt;
use std::net::{IpAddr, Ipv4Addr};
use std::num::NonZeroU16;

use crate::tuning::Tuning;

/// `host:port`, bracketing `host` when it is an IPv6 literal
/// (RFC 3986 §3.2.2), so [`parse_host_port`] reads it back.
pub fn format_host_port(host: &str, port: u16) -> String {
    if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

/// A host with the port the text carried, if any.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct HostPort {
    pub host: String,
    pub port: Option<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum HostPortError {
    #[error("unclosed \"[\" in address {0:?}")]
    UnclosedBracket(String),
    #[error("expected \":port\" after \"]\" in address {0:?}")]
    TrailingText(String),
    #[error("port must be a number from 0 to 65535: {0:?}")]
    BadPort(String),
}

/// `host`, `host:port`, `[v6]` or `[v6]:port`, split. Surrounding
/// whitespace is ignored. A bare IPv6 literal (`fe80::1`, more than one
/// colon and no brackets) is all host: it cannot be an authority with a
/// port. Whether an empty host or port 0 is acceptable is the caller's rule
/// ([`PeerAddress`] has its own).
pub fn parse_host_port(text: &str) -> Result<HostPort, HostPortError> {
    let trimmed = text.trim();
    if let Some(bracketed) = trimmed.strip_prefix('[') {
        let (host, rest) = bracketed
            .split_once(']')
            .ok_or_else(|| HostPortError::UnclosedBracket(text.to_owned()))?;
        let port = match rest {
            "" => None,
            _ => {
                let digits = rest
                    .strip_prefix(':')
                    .ok_or_else(|| HostPortError::TrailingText(text.to_owned()))?;
                Some(parse_port(digits)?)
            }
        };
        return Ok(HostPort {
            host: host.to_owned(),
            port,
        });
    }
    match trimmed.split_once(':') {
        Some((host, digits)) if !digits.contains(':') => Ok(HostPort {
            host: host.to_owned(),
            port: Some(parse_port(digits)?),
        }),
        _ => Ok(HostPort {
            host: trimmed.to_owned(),
            port: None,
        }),
    }
}

fn parse_port(digits: &str) -> Result<u16, HostPortError> {
    digits
        .parse()
        .map_err(|_| HostPortError::BadPort(digits.to_owned()))
}

/// `host` with an IPv4-mapped IPv6 literal in dotted-quad form
/// (`::ffff:192.168.1.5`, what a dual-stack listener reports for an IPv4
/// peer) reduced to its IPv4 form; anything else unchanged. The hex-group
/// spelling (`::ffff:c0a8:105`) is left alone: no library prints a mapped
/// peer that way, and rewriting it would be guessing.
pub fn normalized_host(host: &str) -> String {
    const PREFIX: &str = "::ffff:";
    let mapped = host
        .get(..PREFIX.len())
        .filter(|prefix| prefix.eq_ignore_ascii_case(PREFIX))
        .and_then(|_| host.get(PREFIX.len()..));
    match mapped {
        Some(v4) if v4.parse::<Ipv4Addr>().is_ok() => v4.to_owned(),
        _ => host.to_owned(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error(
    "{0:?} is not an IP address. Give an address literal this machine has - \
     0.0.0.0 for every IPv4 interface, :: for every interface of either \
     family, or one interface's own address - not a hostname."
)]
pub struct BindAddressError(String);

/// An address literal for `--bind`, bracketed or bare - never a hostname,
/// which may resolve to several addresses or a different one later.
pub fn parse_bind_address(text: &str) -> Result<IpAddr, BindAddressError> {
    let trimmed = text.trim();
    let bare = trimmed
        .strip_prefix('[')
        .and_then(|inner| inner.strip_suffix(']'))
        .unwrap_or(trimmed);
    bare.parse().map_err(|_| BindAddressError(text.to_owned()))
}

/// `0.0.0.0` or `::`: where a listener binds, never where a peer dials,
/// so it cannot be advertised.
pub fn is_wildcard_address(address: IpAddr) -> bool {
    address.is_unspecified()
}

/// Where a paired peer was last reached: a non-empty host, normalized at
/// construction so nothing downstream meets the mapped IPv4 spelling, and
/// a non-zero port.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct PeerAddress {
    host: String,
    port: NonZeroU16,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PeerAddressError {
    #[error("empty host")]
    EmptyHost,
    #[error("port out of range: 0")]
    ZeroPort,
}

impl PeerAddress {
    pub fn new(host: &str, port: u16) -> Result<PeerAddress, PeerAddressError> {
        let host = host.trim();
        if host.is_empty() {
            return Err(PeerAddressError::EmptyHost);
        }
        let port = NonZeroU16::new(port).ok_or(PeerAddressError::ZeroPort)?;
        Ok(PeerAddress {
            host: normalized_host(host),
            port,
        })
    }

    /// `host` on the default peer port ([`Tuning::peer_port`]).
    pub fn with_default_port(host: &str) -> Result<PeerAddress, PeerAddressError> {
        PeerAddress::new(host, Tuning::DEFAULT.peer_port)
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port.get()
    }
}

/// The text a user sees and can paste back: bracketed for IPv6.
impl fmt::Display for PeerAddress {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&format_host_port(&self.host, self.port.get()))
    }
}

#[cfg(test)]
mod tests {
    //! Every case of `test/dsync_core/models/host_port_test.dart`.

    use std::net::Ipv6Addr;

    use super::*;

    fn host_port(host: &str, port: Option<u16>) -> Result<HostPort, HostPortError> {
        Ok(HostPort {
            host: host.to_owned(),
            port,
        })
    }

    #[test]
    fn format_leaves_ipv4_and_hostnames_alone() {
        assert_eq!(format_host_port("192.168.1.5", 28771), "192.168.1.5:28771");
        assert_eq!(format_host_port("laptop.local", 22), "laptop.local:22");
    }

    #[test]
    fn format_brackets_an_ipv6_literal() {
        assert_eq!(format_host_port("fe80::1", 28771), "[fe80::1]:28771");
        assert_eq!(format_host_port("::1", 1), "[::1]:1");
    }

    #[test]
    fn format_round_trips_through_parse() {
        for host in ["192.168.1.5", "fe80::1", "::1", "host.example"] {
            assert_eq!(
                parse_host_port(&format_host_port(host, 28771)),
                host_port(host, Some(28771))
            );
        }
    }

    #[test]
    fn a_host_with_no_port_reports_no_port() {
        assert_eq!(
            parse_host_port("192.168.1.5"),
            host_port("192.168.1.5", None)
        );
    }

    #[test]
    fn splits_host_and_port() {
        assert_eq!(
            parse_host_port(" 192.168.1.5:28771 "),
            host_port("192.168.1.5", Some(28771))
        );
    }

    #[test]
    fn reads_a_bare_ipv6_literal_as_a_host() {
        assert_eq!(parse_host_port("fe80::1"), host_port("fe80::1", None));
        assert_eq!(
            parse_host_port("2001:db8::5"),
            host_port("2001:db8::5", None)
        );
    }

    #[test]
    fn a_bracketed_literal_may_carry_a_port_or_not() {
        assert_eq!(
            parse_host_port("[fe80::1]:28771"),
            host_port("fe80::1", Some(28771))
        );
        assert_eq!(parse_host_port("[fe80::1]"), host_port("fe80::1", None));
    }

    #[test]
    fn refuses_an_unclosed_bracket_a_stray_tail_or_a_bad_port() {
        assert!(matches!(
            parse_host_port("[fe80::1"),
            Err(HostPortError::UnclosedBracket(_))
        ));
        assert!(matches!(
            parse_host_port("[fe80::1]x"),
            Err(HostPortError::TrailingText(_))
        ));
        assert!(matches!(
            parse_host_port("192.168.1.5:http"),
            Err(HostPortError::BadPort(_))
        ));
        assert!(matches!(
            parse_host_port("192.168.1.5:65536"),
            Err(HostPortError::BadPort(_))
        ));
    }

    #[test]
    fn normalizes_an_ipv4_mapped_literal() {
        assert_eq!(normalized_host("::ffff:192.168.1.5"), "192.168.1.5");
        assert_eq!(normalized_host("::FFFF:10.0.0.1"), "10.0.0.1");
    }

    #[test]
    fn leaves_real_ipv6_ipv4_and_names_alone() {
        for host in [
            "fe80::1",
            "::ffff",
            "::ffff:c0a8:105",
            "192.168.1.5",
            "laptop.local",
        ] {
            assert_eq!(normalized_host(host), host);
        }
    }

    #[test]
    fn peer_address_normalizes_at_construction() {
        let address = PeerAddress::with_default_port("::ffff:192.168.1.5");
        assert_eq!(address.as_ref().map(PeerAddress::host), Ok("192.168.1.5"));
        assert_eq!(address.map(|a| a.port()), Ok(28771));
    }

    #[test]
    fn peer_address_text_brackets_ipv6_and_leaves_ipv4() {
        let text = |host: &str| PeerAddress::new(host, 28771).map(|a| a.to_string());
        assert_eq!(text("fe80::1"), Ok("[fe80::1]:28771".to_owned()));
        assert_eq!(text("10.0.0.4"), Ok("10.0.0.4:28771".to_owned()));
    }

    #[test]
    fn peer_address_refuses_an_empty_host_or_port_zero() {
        assert_eq!(PeerAddress::new("  ", 1), Err(PeerAddressError::EmptyHost));
        assert_eq!(PeerAddress::new("h", 0), Err(PeerAddressError::ZeroPort));
        assert!(PeerAddress::new("h", 1).is_ok());
    }

    #[test]
    fn bind_takes_the_two_wildcards_and_an_interface_address() {
        assert_eq!(
            parse_bind_address("0.0.0.0"),
            Ok(IpAddr::V4(Ipv4Addr::UNSPECIFIED))
        );
        assert_eq!(
            parse_bind_address("::"),
            Ok(IpAddr::V6(Ipv6Addr::UNSPECIFIED))
        );
        assert_eq!(
            parse_bind_address("10.8.0.3"),
            Ok(IpAddr::V4(Ipv4Addr::new(10, 8, 0, 3)))
        );
        assert_eq!(
            parse_bind_address("[fe80::1]").map(|a| a.to_string()),
            Ok("fe80::1".to_owned())
        );
    }

    #[test]
    fn bind_refuses_a_hostname_naming_the_value() {
        let message = parse_bind_address("laptop.local")
            .err()
            .map(|e| e.to_string())
            .unwrap_or_default();
        assert!(message.contains("laptop.local"), "{message}");
        assert!(message.contains("not a hostname"), "{message}");
    }

    #[test]
    fn wildcard_is_true_for_the_two_wildcards_only() {
        assert!(is_wildcard_address(IpAddr::V4(Ipv4Addr::UNSPECIFIED)));
        assert!(is_wildcard_address(IpAddr::V6(Ipv6Addr::UNSPECIFIED)));
        assert!(!is_wildcard_address(IpAddr::V4(Ipv4Addr::LOCALHOST)));
        assert!(!is_wildcard_address(IpAddr::V4(Ipv4Addr::new(10, 8, 0, 3))));
    }
}
