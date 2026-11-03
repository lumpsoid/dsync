//! The slots both listeners (SPEC §4.4) hand a connection at accept and
//! take back once it has authenticated or been turned away: at most
//! [`Tuning::unauthenticated_connections`] at once, and at most
//! [`Tuning::unauthenticated_per_address`] of them from one address, so
//! one host on the network cannot hold every slot.
//!
//! The table holds only addresses with a slot taken - never more entries
//! than the global cap - so it remembers no past peer and cannot grow.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex, PoisonError};

use dsync_domain::Tuning;

/// Why a connection got no slot. Neither cap's refusal takes a slot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SlotRefusal {
    /// `limit` connections, from anywhere, already hold one.
    OverCapacity { limit: usize },
    /// `limit` connections from this one address already hold one.
    OverAddressCapacity { limit: usize },
}

/// One listener's slots, shared by its accept loop and every connection
/// holding one.
#[derive(Clone)]
pub(crate) struct UnauthenticatedSlots {
    shared: Arc<Shared>,
}

struct Shared {
    limit: usize,
    per_address: usize,
    taken: Mutex<Taken>,
}

#[derive(Default)]
struct Taken {
    total: usize,
    by_address: HashMap<IpAddr, usize>,
}

/// A slot held: given back on drop.
pub(crate) struct UnauthenticatedSlot {
    shared: Arc<Shared>,
    address: IpAddr,
}

impl UnauthenticatedSlots {
    pub(crate) fn new(tuning: &Tuning) -> UnauthenticatedSlots {
        UnauthenticatedSlots {
            shared: Arc::new(Shared {
                limit: tuning.unauthenticated_connections,
                per_address: tuning.unauthenticated_per_address,
                taken: Mutex::default(),
            }),
        }
    }

    /// A slot for a connection from `address`, unless either cap is met.
    pub(crate) fn admit(&self, address: IpAddr) -> Result<UnauthenticatedSlot, SlotRefusal> {
        // An IPv4 peer reaching a dual-stack socket is the same peer as
        // over IPv4.
        let address = address.to_canonical();
        let mut taken = self.shared.taken();
        let from_address = taken.by_address.get(&address).copied().unwrap_or(0);
        if from_address >= self.shared.per_address {
            return Err(SlotRefusal::OverAddressCapacity {
                limit: self.shared.per_address,
            });
        }
        if taken.total >= self.shared.limit {
            return Err(SlotRefusal::OverCapacity {
                limit: self.shared.limit,
            });
        }
        taken.total += 1;
        taken.by_address.insert(address, from_address + 1);
        Ok(UnauthenticatedSlot {
            shared: self.shared.clone(),
            address,
        })
    }
}

impl Shared {
    fn taken(&self) -> std::sync::MutexGuard<'_, Taken> {
        self.taken.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Drop for UnauthenticatedSlot {
    fn drop(&mut self) {
        let mut taken = self.shared.taken();
        taken.total -= 1;
        if let Some(held) = taken.by_address.get_mut(&self.address) {
            *held -= 1;
            if *held == 0 {
                taken.by_address.remove(&self.address);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, Ipv6Addr};

    use super::*;

    const A: IpAddr = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 10));
    const B: IpAddr = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 11));

    fn slots(limit: usize, per_address: usize) -> UnauthenticatedSlots {
        UnauthenticatedSlots::new(&Tuning {
            unauthenticated_connections: limit,
            unauthenticated_per_address: per_address,
            ..Tuning::DEFAULT
        })
    }

    #[test]
    fn an_address_at_its_cap_is_refused_while_another_still_gets_a_slot() {
        let slots = slots(16, 2);
        let _held = [slots.admit(A).unwrap(), slots.admit(A).unwrap()];
        assert_eq!(
            slots.admit(A).err(),
            Some(SlotRefusal::OverAddressCapacity { limit: 2 })
        );
        assert!(slots.admit(B).is_ok());
    }

    /// A refusal over the address's cap takes no slot: with one global
    /// slot left, repeated refusals from `A` still leave it for `B`.
    #[test]
    fn a_refusal_over_the_address_cap_takes_no_global_slot() {
        let slots = slots(3, 2);
        let _held = [slots.admit(A).unwrap(), slots.admit(A).unwrap()];
        for _ in 0..10 {
            assert!(slots.admit(A).is_err());
        }
        let _b = slots.admit(B).unwrap();
        assert_eq!(
            slots.admit(B).err(),
            Some(SlotRefusal::OverCapacity { limit: 3 })
        );
    }

    #[test]
    fn a_dropped_slot_comes_back_to_its_address_and_to_the_total() {
        let slots = slots(2, 1);
        let held = slots.admit(A).unwrap();
        let _b = slots.admit(B).unwrap();
        assert!(slots.admit(A).is_err());
        drop(held);
        assert!(slots.admit(A).is_ok());
    }

    #[test]
    fn an_ipv4_peer_over_a_dual_stack_socket_counts_as_itself() {
        let slots = slots(16, 1);
        let mapped = IpAddr::V6(Ipv4Addr::new(192, 168, 1, 10).to_ipv6_mapped());
        let _held = slots.admit(A).unwrap();
        assert!(slots.admit(mapped).is_err());
        assert!(slots.admit(IpAddr::V6(Ipv6Addr::LOCALHOST)).is_ok());
    }

    #[test]
    fn the_table_forgets_an_address_once_its_last_slot_is_back() {
        let slots = slots(16, 4);
        drop(slots.admit(A).unwrap());
        assert!(slots.shared.taken().by_address.is_empty());
        assert_eq!(slots.shared.taken().total, 0);
    }
}
