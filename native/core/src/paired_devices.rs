//! The set of paired devices as one value, with the rules that need to see
//! every device at once (a unique name, one entry per key).

use std::collections::BTreeMap;
use std::time::SystemTime;

use dsync_domain::host_port::PeerAddress;
use dsync_domain::{DeviceId, PeerName};

use crate::certificate::Certificate;
use crate::paired_device::{DifferentKey, PairedDevice};

/// Every device this host has paired with, keyed by device id. Names are
/// unique too (exact, case-sensitive - `peer://<name>:` resolves by it).
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct PairedDevices(BTreeMap<DeviceId, PairedDevice>);

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PairingError {
    #[error("a device named \"{0}\" is already paired")]
    NameTaken(PeerName),
    #[error("device {id} is already paired, as \"{name}\"")]
    AlreadyPaired { id: DeviceId, name: PeerName },
    #[error("no paired device with id {0}")]
    NotPaired(DeviceId),
    #[error(transparent)]
    DifferentKey(#[from] DifferentKey),
}

impl PairedDevices {
    pub fn get(&self, id: &DeviceId) -> Option<&PairedDevice> {
        self.0.get(id)
    }

    /// The device this host calls `name` (what `peer://<name>:` resolves).
    pub fn by_name(&self, name: &PeerName) -> Option<&PairedDevice> {
        self.0.values().find(|device| device.name() == name)
    }

    /// In device-id order.
    pub fn iter(&self) -> impl Iterator<Item = &PairedDevice> {
        self.0.values()
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Pairs `device`, refused when its name or its key is already paired
    /// (re-pairing a key is a revoke first, so a stale grant or
    /// confirmation is never carried over by accident).
    pub fn add(&mut self, device: PairedDevice) -> Result<(), PairingError> {
        if let Some(existing) = self.get(&device.device_id()) {
            return Err(PairingError::AlreadyPaired {
                id: device.device_id(),
                name: existing.name().clone(),
            });
        }
        self.check_name_free(device.name(), None)?;
        self.0.insert(device.device_id(), device);
        Ok(())
    }

    pub fn revoke(&mut self, id: &DeviceId) -> Result<PairedDevice, PairingError> {
        self.0.remove(id).ok_or(PairingError::NotPaired(*id))
    }

    /// Relabels a device; a name another device holds is refused, its own
    /// name is not.
    pub fn rename(&mut self, id: &DeviceId, name: PeerName) -> Result<(), PairingError> {
        if !self.0.contains_key(id) {
            return Err(PairingError::NotPaired(*id));
        }
        self.check_name_free(&name, Some(id))?;
        self.device_mut(id)?.rename(name);
        Ok(())
    }

    pub fn grant(&mut self, id: &DeviceId, expanded_root: String) -> Result<(), PairingError> {
        self.device_mut(id)?.grant(expanded_root);
        Ok(())
    }

    pub fn withdraw_grant(
        &mut self,
        id: &DeviceId,
        expanded_root: &str,
    ) -> Result<(), PairingError> {
        self.device_mut(id)?.withdraw_grant(expanded_root);
        Ok(())
    }

    pub fn record_connection(
        &mut self,
        id: &DeviceId,
        address: PeerAddress,
        presented: Certificate,
    ) -> Result<(), PairingError> {
        Ok(self.device_mut(id)?.record_connection(address, presented)?)
    }

    pub fn verify(&mut self, id: &DeviceId, at: SystemTime) -> Result<(), PairingError> {
        self.device_mut(id)?.verify(at);
        Ok(())
    }

    pub fn clear_verification(&mut self, id: &DeviceId) -> Result<(), PairingError> {
        self.device_mut(id)?.clear_verification();
        Ok(())
    }

    fn device_mut(&mut self, id: &DeviceId) -> Result<&mut PairedDevice, PairingError> {
        self.0.get_mut(id).ok_or(PairingError::NotPaired(*id))
    }

    fn check_name_free(
        &self,
        name: &PeerName,
        owner: Option<&DeviceId>,
    ) -> Result<(), PairingError> {
        match self.by_name(name) {
            Some(holder) if Some(&holder.device_id()) != owner => {
                Err(PairingError::NameTaken(name.clone()))
            }
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    //! The cases of `test/dsync_core/models/paired_device_test.dart`, and
    //! the set-wide rules of `paired_device_store_test.dart` as plain values.
    //! The `PeerAddress` and empty-name cases are the domain's
    //! (`host_port`, `peer_name`).

    use std::time::Duration;

    use dsync_domain::{Jobs, ProfileId, ReplicaSpec, Side};

    use super::*;
    use crate::device_identity::DeviceIdentity;

    fn at(seconds: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(seconds)
    }

    fn identity() -> DeviceIdentity {
        DeviceIdentity::generate("peer", at(1_790_000_000)).unwrap()
    }

    fn name(text: &str) -> PeerName {
        PeerName::parse(text).unwrap()
    }

    fn address(host: &str) -> PeerAddress {
        PeerAddress::with_default_port(host).unwrap()
    }

    fn device(identity: &DeviceIdentity, label: &str) -> PairedDevice {
        PairedDevice::new(
            identity.certificate().clone(),
            name(label),
            address("192.168.1.5"),
            at(1_790_000_000),
        )
    }

    #[test]
    fn the_device_id_is_the_certificates() {
        let identity = identity();
        assert_eq!(device(&identity, "phone").device_id(), identity.device_id());
        assert_eq!(
            device(&identity, "phone").device_id(),
            device(&identity, "other").device_id()
        );
    }

    #[test]
    fn serves_only_a_granted_root_by_exact_string() {
        let mut phone = device(&identity(), "phone");
        assert!(!phone.serves_root("/home/me/notes"));
        phone.grant("/home/me/notes".to_owned());
        assert!(phone.serves_root("/home/me/notes"));
        for near_miss in [
            "/home/me/notes/",
            "/home/me",
            "/home/me/notes/sub",
            "~/notes",
        ] {
            assert!(!phone.serves_root(near_miss), "{near_miss}");
        }
    }

    #[test]
    fn serves_a_spec_whose_expanded_root_is_granted() {
        let spec = |root: &str| ReplicaSpec {
            root: root.to_owned(),
            profile: ProfileId::parse("0123456789abcdef0123456789abcdef").unwrap(),
            side: Side::B,
            jobs: Jobs::DEFAULT,
        };
        let mut phone = device(&identity(), "phone");
        phone.grant("/home/me/notes".to_owned());
        assert!(phone.serves_spec(&spec("~/notes"), Some("/home/me")));
        assert!(phone.serves_spec(&spec("/home/me/notes"), None));
        assert!(!phone.serves_spec(&spec("~/notes"), Some("/home/you")));
        // No home to expand against: refused, never guessed at.
        assert!(!phone.serves_spec(&spec("~/notes"), None));
        assert!(!phone.serves_spec(&spec("/home/me/notes/"), Some("/home/me")));
    }

    #[test]
    fn granting_is_idempotent_and_additive_and_withdrawing_takes_one_back() {
        let mut phone = device(&identity(), "phone");
        phone.grant("/a".to_owned());
        phone.grant("/b".to_owned());
        phone.grant("/a".to_owned());
        assert_eq!(phone.granted_roots().len(), 2);
        phone.withdraw_grant("/a");
        phone.withdraw_grant("/never");
        assert!(!phone.serves_root("/a"));
        assert!(phone.serves_root("/b"));
    }

    #[test]
    fn recording_a_connection_replaces_the_address_and_a_renewed_certificate_only() {
        let identity = identity();
        let mut phone = device(&identity, "phone");
        phone.grant("/a".to_owned());
        phone.verify(at(5));
        let renewed = identity.renewed(None, at(1_800_000_000)).unwrap();

        phone
            .record_connection(address("10.0.0.9"), renewed.certificate().clone())
            .unwrap();

        assert_eq!(phone.last_known_address(), &address("10.0.0.9"));
        assert_eq!(phone.certificate(), renewed.certificate());
        assert_eq!(phone.device_id(), identity.device_id());
        assert_eq!(phone.name(), &name("phone"));
        assert!(phone.serves_root("/a"));
        assert_eq!(phone.paired_at(), at(1_790_000_000));
        // A renewal is the same key: the confirmation stands.
        assert_eq!(phone.verified_at(), Some(at(5)));
    }

    #[test]
    fn a_certificate_over_another_key_is_refused_and_changes_nothing() {
        let identity = identity();
        let stranger = self::identity();
        let mut phone = device(&identity, "phone");
        let before = phone.clone();
        assert_eq!(
            phone.record_connection(address("10.0.0.9"), stranger.certificate().clone()),
            Err(DifferentKey {
                expected: identity.device_id(),
                presented: stranger.device_id(),
            })
        );
        assert_eq!(phone, before);
    }

    #[test]
    fn verification_is_absent_until_made_and_can_be_taken_back() {
        let mut phone = device(&identity(), "phone");
        assert_eq!(phone.verified_at(), None);
        let before = phone.clone();
        phone.verify(at(7));
        assert_eq!(phone.verified_at(), Some(at(7)));
        phone.clear_verification();
        assert_eq!(phone, before);
    }

    #[test]
    fn renaming_granting_and_moving_carry_the_confirmation() {
        let identity = identity();
        let mut devices = PairedDevices::default();
        devices.add(device(&identity, "phone")).unwrap();
        let id = identity.device_id();
        devices.verify(&id, at(7)).unwrap();
        devices.rename(&id, name("tablet")).unwrap();
        devices.grant(&id, "/a".to_owned()).unwrap();
        devices
            .record_connection(&id, address("10.0.0.2"), identity.certificate().clone())
            .unwrap();
        assert_eq!(devices.get(&id).unwrap().verified_at(), Some(at(7)));
    }

    #[test]
    fn a_name_or_a_key_already_paired_is_refused() {
        let (a, b) = (identity(), identity());
        let mut devices = PairedDevices::default();
        devices.add(device(&a, "phone")).unwrap();
        assert_eq!(
            devices.add(device(&b, "phone")),
            Err(PairingError::NameTaken(name("phone")))
        );
        assert_eq!(
            devices.add(device(&a, "laptop")),
            Err(PairingError::AlreadyPaired {
                id: a.device_id(),
                name: name("phone"),
            })
        );
        // Positive control: a new key under a new name pairs.
        devices.add(device(&b, "laptop")).unwrap();
        assert_eq!(devices.len(), 2);
        assert_eq!(
            devices
                .by_name(&name("laptop"))
                .map(PairedDevice::device_id),
            Some(b.device_id())
        );
    }

    #[test]
    fn rename_refuses_another_devices_name_but_not_its_own() {
        let (a, b) = (identity(), identity());
        let mut devices = PairedDevices::default();
        devices.add(device(&a, "phone")).unwrap();
        devices.add(device(&b, "laptop")).unwrap();
        assert_eq!(
            devices.rename(&a.device_id(), name("laptop")),
            Err(PairingError::NameTaken(name("laptop")))
        );
        devices.rename(&a.device_id(), name("phone")).unwrap();
        devices.rename(&a.device_id(), name("tablet")).unwrap();
        assert_eq!(devices.by_name(&name("phone")), None);
        assert!(devices.by_name(&name("tablet")).is_some());
    }

    #[test]
    fn every_change_to_an_unpaired_id_is_refused() {
        let stranger = identity().device_id();
        let mut devices = PairedDevices::default();
        let not_paired = Err(PairingError::NotPaired(stranger));
        assert_eq!(devices.revoke(&stranger).map(|_| ()), not_paired);
        assert_eq!(devices.rename(&stranger, name("x")), not_paired);
        assert_eq!(devices.grant(&stranger, "/a".to_owned()), not_paired);
        assert_eq!(devices.withdraw_grant(&stranger, "/a"), not_paired);
        assert_eq!(devices.verify(&stranger, at(1)), not_paired);
        assert_eq!(devices.clear_verification(&stranger), not_paired);
    }
}
