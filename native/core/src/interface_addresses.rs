//! This host's network interface addresses: a fetch that decides nothing.
//! Which of them to advertise is
//! [`dsync_domain::preferred_advertisable_address`]'s call.

use std::io;
use std::net::IpAddr;

/// Every address on every interface, loopback and link-local included, in
/// the order the OS reports them.
pub fn interface_addresses() -> io::Result<Vec<IpAddr>> {
    Ok(if_addrs::get_if_addrs()?
        .iter()
        .map(if_addrs::Interface::ip)
        .collect())
}

#[cfg(test)]
mod tests {
    use std::net::IpAddr;

    use dsync_domain::preferred_advertisable_address;

    use super::*;

    /// The one assertion that holds on any machine, including a runner
    /// with no interfaces: the guess over the real list is never loopback
    /// nor an IPv6 link-local address.
    #[test]
    fn the_guess_over_this_hosts_interfaces_is_never_loopback_or_v6_link_local() {
        let addresses = interface_addresses().unwrap();
        match preferred_advertisable_address(&addresses) {
            None => {}
            Some(IpAddr::V4(v4)) => assert!(!v4.is_loopback(), "{v4}"),
            Some(IpAddr::V6(v6)) => {
                assert!(!v6.is_loopback() && !v6.is_unicast_link_local(), "{v6}")
            }
        }
    }

    /// Positive control for the fetch deciding nothing: loopback is listed
    /// (every Linux host has `lo`), left for the domain rule to skip.
    #[cfg(target_os = "linux")]
    #[test]
    fn the_listing_includes_loopback() {
        let addresses = interface_addresses().unwrap();
        assert!(addresses.iter().any(IpAddr::is_loopback), "{addresses:?}");
    }
}
