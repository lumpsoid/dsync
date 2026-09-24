//! Which peer a side will talk to: one device id, or (for the spike only)
//! any peer that proves it holds the key of the certificate it presents.

use std::fmt;
use std::str::FromStr;

use crate::device_id::DeviceId;

/// The text that stands for [PeerPin::Any].
pub const ANY: &str = "ANY";

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum PeerPin {
    Any,
    Device(DeviceId),
}

impl PeerPin {
    pub fn admits(&self, peer: &DeviceId) -> bool {
        match self {
            PeerPin::Any => true,
            PeerPin::Device(pinned) => pinned == peer,
        }
    }
}

impl FromStr for PeerPin {
    type Err = anyhow::Error;

    fn from_str(text: &str) -> anyhow::Result<Self> {
        if text.trim() == ANY {
            Ok(PeerPin::Any)
        } else {
            Ok(PeerPin::Device(text.parse()?))
        }
    }
}

impl fmt::Display for PeerPin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PeerPin::Any => f.write_str(ANY),
            PeerPin::Device(id) => id.fmt(f),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    #[test]
    fn a_device_pin_admits_that_device_only() {
        let a = Identity::generate().unwrap().device_id();
        let b = Identity::generate().unwrap().device_id();
        let pin: PeerPin = a.to_string().parse().unwrap();
        assert!(pin.admits(&a));
        assert!(!pin.admits(&b));
    }

    #[test]
    fn any_admits_every_device() {
        let pin: PeerPin = "ANY".parse().unwrap();
        assert_eq!(pin, PeerPin::Any);
        assert!(pin.admits(&Identity::generate().unwrap().device_id()));
    }

    #[test]
    fn junk_is_neither() {
        assert!("any".parse::<PeerPin>().is_err());
        assert!("".parse::<PeerPin>().is_err());
    }
}
