//! This device's identity, and the paired devices and their grants
//! (SPEC §4.4): every change one [`PairedDeviceStore::update`], answered
//! with the list as it now stands.

use std::str::FromStr;
use std::time::SystemTime;

use dsync_core::{DeviceIdentityStore, PairedDeviceStore, PairedDevices, PairingError, PeerDialer};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{DeviceId, Location, PeerName};

use crate::dispatch::{Handled, Hub, text};
use crate::signals::ReplyResult;
use crate::views::{DeviceView, IdentityView, ProbeOutcome};

impl Hub {
    pub(crate) fn identities(&self) -> DeviceIdentityStore {
        DeviceIdentityStore::new(&self.state)
    }

    pub(crate) fn paired(&self) -> PairedDeviceStore {
        PairedDeviceStore::new(&self.state)
    }

    /// Created on first use, named after this device.
    pub(crate) fn show_identity(&self) -> Handled {
        let now = SystemTime::now();
        let identity = self
            .identities()
            .load_or_create(&self.device_name, now)
            .map_err(text)?;
        Ok(ReplyResult::Identity(IdentityView::of(&identity, now)))
    }

    /// The same key and device id, a fresh certificate. Peers pick it up
    /// the next time they connect here.
    pub(crate) fn renew_identity(&self, common_name: Option<String>) -> Handled {
        let now = SystemTime::now();
        let renewed = self
            .identities()
            .renew(common_name.as_deref(), now)
            .map_err(text)?;
        Ok(ReplyResult::Identity(IdentityView::of(&renewed, now)))
    }

    pub(crate) fn list_devices(&self) -> Handled {
        let devices = self.paired().load().map_err(text)?;
        Ok(devices_reply(&devices))
    }

    pub(crate) fn rename_device(&self, device_id: &str, name: &str) -> Handled {
        let id = device(device_id)?;
        let name = PeerName::parse(name).map_err(text)?;
        self.change_devices(|devices| devices.rename(&id, name))
    }

    /// Local only: nothing is sent to the device.
    pub(crate) fn revoke_device(&self, device_id: &str) -> Handled {
        let id = device(device_id)?;
        self.change_devices(|devices| devices.revoke(&id).map(drop))
    }

    /// The root stored expanded, as the peer listener expands a requested
    /// root before checking it, so the two compare byte for byte (the
    /// CLI's `pair grant`).
    pub(crate) fn grant_root(&self, device_id: &str, path: &str) -> Handled {
        let id = device(device_id)?;
        let root = Location::parse(path, self.facts.platform())
            .map_err(text)?
            .expanded_path(self.facts.home())
            .map_err(text)?;
        self.change_devices(|devices| devices.grant(&id, root))
    }

    pub(crate) fn withdraw_grant(&self, device_id: &str, root: &str) -> Handled {
        let id = device(device_id)?;
        self.change_devices(|devices| devices.withdraw_grant(&id, root))
    }

    /// The dial's own handshake, then closed: nothing opened or recorded.
    pub(crate) async fn probe_peer(&self, device_id: &str, address: Option<String>) -> Handled {
        let id = device(device_id)?;
        let address = address
            .map(|typed| PeerAddress::parse(&typed))
            .transpose()
            .map_err(text)?;
        let identity = self
            .identities()
            .load_or_create(&self.device_name, SystemTime::now())
            .map_err(text)?;
        let dialer = PeerDialer::new(identity, self.paired(), self.tuning);
        Ok(ReplyResult::PeerProbed(
            match dialer.probe(&id, address).await {
                Ok(reached) => ProbeOutcome::Reachable {
                    address: reached.to_string(),
                },
                Err(error) if error.is_unreachable() => ProbeOutcome::Unreachable {
                    message: error.to_string(),
                },
                Err(error) => ProbeOutcome::Refused {
                    message: error.to_string(),
                },
            },
        ))
    }

    fn change_devices(
        &self,
        change: impl FnOnce(&mut PairedDevices) -> Result<(), PairingError>,
    ) -> Handled {
        let store = self.paired();
        store.update(change).map_err(text)?;
        let devices = store.load().map_err(text)?;
        Ok(devices_reply(&devices))
    }
}

/// A device id as the head sends it.
pub(crate) fn device(text_form: &str) -> Result<DeviceId, String> {
    DeviceId::from_str(text_form).map_err(text)
}

fn devices_reply(devices: &PairedDevices) -> ReplyResult {
    let now = SystemTime::now();
    ReplyResult::Devices(
        devices
            .iter()
            .map(|device| DeviceView::of(device, now))
            .collect(),
    )
}
