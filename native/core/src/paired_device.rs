//! One device this installation has paired with (SPEC §4.4).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use dsync_domain::host_port::PeerAddress;
use dsync_domain::{DeviceId, PathStyle, PeerName, Platform, ReplicaSpec, first_nesting, nests};

use crate::certificate::Certificate;
use crate::replica_lock::canonical_root;

/// How this host's own paths compare when grants are judged for nesting.
const HOST_STYLE: PathStyle = match Platform::HOST {
    Platform::Unix => PathStyle::Posix,
    Platform::Windows => PathStyle::Windows,
};

/// A paired device: the certificate pinned for it (its device id is the
/// certificate's key hash, never stored beside it, so the two cannot
/// drift), this host's own name for it, the replica roots it may reach,
/// where it was last reached, and whether the user has confirmed its id
/// out of band.
///
/// The key cannot change within one pairing - [`Self::record_connection`]
/// refuses a certificate over another key - so a confirmation is about
/// this entry's key for as long as the entry exists; a re-pairing is a new
/// entry with none.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct PairedDevice {
    certificate: Certificate,
    name: PeerName,
    granted_roots: BTreeSet<String>,
    paired_at: SystemTime,
    last_known_address: PeerAddress,
    verified_at: Option<SystemTime>,
}

/// A grant refused because, resolved on this host, it would lie inside
/// `existing`, contain it, or name the same place under another spelling.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error(
    "cannot grant {new}: it overlaps {existing}, already granted to this device (grants never nest)"
)]
pub struct GrantNests {
    pub new: String,
    pub existing: String,
}

/// `expanded_root` as this host resolves it for grant checks
/// ([`canonical_root`]); a root that cannot be resolved is taken as
/// spelled.
pub fn resolve_grant(expanded_root: &str) -> PathBuf {
    canonical_root(Path::new(expanded_root)).unwrap_or_else(|_| PathBuf::from(expanded_root))
}

/// A certificate offered for a device carries a different key: not a
/// renewal of that device but another device.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("the certificate offered for device {expected} carries a different key ({presented})")]
pub struct DifferentKey {
    pub expected: DeviceId,
    pub presented: DeviceId,
}

impl PairedDevice {
    /// A new pairing with no granted roots and no confirmation, reached at
    /// `address` (seeded from the pairing payload).
    pub fn new(
        certificate: Certificate,
        name: PeerName,
        address: PeerAddress,
        paired_at: SystemTime,
    ) -> PairedDevice {
        PairedDevice {
            certificate,
            name,
            granted_roots: BTreeSet::new(),
            paired_at,
            last_known_address: address,
            verified_at: None,
        }
    }

    /// Every field, for the store reading one back.
    pub(crate) fn restore(
        certificate: Certificate,
        name: PeerName,
        granted_roots: BTreeSet<String>,
        paired_at: SystemTime,
        last_known_address: PeerAddress,
        verified_at: Option<SystemTime>,
    ) -> PairedDevice {
        PairedDevice {
            certificate,
            name,
            granted_roots,
            paired_at,
            last_known_address,
            verified_at,
        }
    }

    pub fn device_id(&self) -> DeviceId {
        self.certificate.device_id()
    }

    pub fn certificate(&self) -> &Certificate {
        &self.certificate
    }

    pub fn name(&self) -> &PeerName {
        &self.name
    }

    /// The expanded replica roots this device may reach.
    pub fn granted_roots(&self) -> &BTreeSet<String> {
        &self.granted_roots
    }

    pub fn paired_at(&self) -> SystemTime {
        self.paired_at
    }

    pub fn last_known_address(&self) -> &PeerAddress {
        &self.last_known_address
    }

    /// When the user confirmed this device's id, if they have.
    pub fn verified_at(&self) -> Option<SystemTime> {
        self.verified_at
    }

    /// Whether this device may reach `expanded_root` - the check a `hello`
    /// is held to: exact-string membership of the root already expanded
    /// (`Location::expanded_path`), no normalization, no prefix match.
    pub fn serves_root(&self, expanded_root: &str) -> bool {
        self.granted_roots.contains(expanded_root)
    }

    /// Whether this device may open the replica `spec` names, its root
    /// expanded against this host's `home` ([`ReplicaSpec::expanded_root`],
    /// the expansion the replica factory uses too). A root that cannot be
    /// expanded is not served. Pure: nothing here asks the filesystem, so
    /// a missing, unreadable and ungranted root are refused alike.
    pub fn serves_spec(&self, spec: &ReplicaSpec, home: Option<&str>) -> bool {
        spec.expanded_root(home)
            .is_ok_and(|root| self.serves_root(&root))
    }

    /// Lets this device reach `expanded_root` - a folder or a single file.
    /// Refused when, as `resolve` resolves them on this host, it lies
    /// inside one of this device's grants, contains one, or names the same
    /// place as one spelled differently: a device's grants never nest.
    /// Re-granting the identical string is a no-op. The typed string is
    /// what is stored, since [`Self::serves_root`] matches it exactly.
    pub fn grant(
        &mut self,
        expanded_root: String,
        resolve: impl Fn(&str) -> PathBuf,
    ) -> Result<(), GrantNests> {
        if self.granted_roots.contains(&expanded_root) {
            return Ok(());
        }
        let new = resolve(&expanded_root);
        let new = new.to_string_lossy();
        let clash = self
            .granted_roots
            .iter()
            .find(|existing| nests(&new, &resolve(existing).to_string_lossy(), HOST_STYLE));
        if let Some(existing) = clash {
            return Err(GrantNests {
                new: expanded_root,
                existing: existing.clone(),
            });
        }
        self.granted_roots.insert(expanded_root);
        Ok(())
    }

    /// Two of this device's grants that nest as `resolve` resolves them
    /// now - paths can move after granting - if any do.
    pub fn nesting_grants(&self, resolve: impl Fn(&str) -> PathBuf) -> Option<(&str, &str)> {
        let roots: Vec<&str> = self.granted_roots.iter().map(String::as_str).collect();
        // A name that is not UTF-8 compares by its lossy spelling: at worst
        // two such names read as one and the grants are refused.
        let resolved: Vec<String> = roots
            .iter()
            .map(|root| resolve(root).to_string_lossy().into_owned())
            .collect();
        let resolved: Vec<&str> = resolved.iter().map(String::as_str).collect();
        first_nesting(&resolved, HOST_STYLE).map(|(first, second)| (roots[first], roots[second]))
    }

    /// Takes a grant back. A root never granted is not an error: the
    /// caller wants "this device does not reach it" either way.
    pub fn withdraw_grant(&mut self, expanded_root: &str) {
        self.granted_roots.remove(expanded_root);
    }

    /// Relabels the device. Uniqueness among paired names is the paired
    /// set's rule ([`crate::PairedDevices::rename`]), which sees them all.
    pub(crate) fn rename(&mut self, name: PeerName) {
        self.name = name;
    }

    /// A successful connection: where it reached the device, and the
    /// certificate it presented - the pinned one, or a renewal of it under
    /// the same key, which replaces it. A certificate over another key is
    /// refused and nothing changes.
    pub fn record_connection(
        &mut self,
        address: PeerAddress,
        presented: Certificate,
    ) -> Result<(), DifferentKey> {
        if presented.device_id() != self.device_id() {
            return Err(DifferentKey {
                expected: self.device_id(),
                presented: presented.device_id(),
            });
        }
        self.last_known_address = address;
        self.certificate = presented;
        Ok(())
    }

    /// The user compared this device's id against the one it shows
    /// itself, at `at`, and said they matched.
    pub fn verify(&mut self, at: SystemTime) {
        self.verified_at = Some(at);
    }

    /// Takes a confirmation back (made in haste, or against the wrong
    /// screen). The pairing is exactly as trusted as before: the
    /// confirmation was never what made it trusted.
    pub fn clear_verification(&mut self) {
        self.verified_at = None;
    }
}
