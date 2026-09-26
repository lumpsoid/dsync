//! `paired-devices.json` in the state directory (SPEC §4.4, §8.3): the
//! devices this host has paired with, as JSON a human can read.
//!
//! No caching: [`PairedDeviceStore::load`] reads the file every time, so a
//! pairing, a revocation or a grant made by another process (the CLI while
//! the head listens, or the reverse) applies on the very next connection.
//! Every change is one read-modify-write of the whole file through the
//! atomic helper, so two concurrent writers can lose one update but never
//! leave a torn file.
//!
//! Versioned `major.minor` (SPEC §8.4): a document of another major is
//! refused, naming the file, rather than read as damage or as "no
//! devices"; fields a later minor added are ignored.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use dsync_domain::host_port::PeerAddress;
use dsync_domain::{DeviceId, FormatVersion, PeerName};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::atomic_write::write_atomically;
use crate::certificate::Certificate;
use crate::paired_device::PairedDevice;
use crate::paired_devices::{PairedDevices, PairingError};
use crate::state_dir::StateDir;

/// The document's format: a new field is a minor bump, any change to what
/// an existing one means a major one.
pub const PAIRED_DEVICES_FORMAT_VERSION: FormatVersion = FormatVersion::new(1, 0);

#[derive(Debug, thiserror::Error)]
pub enum PairedDeviceStoreError {
    #[error("Paired devices {}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error(
        "Paired devices at {} is format {found}, which this build (format \
         {PAIRED_DEVICES_FORMAT_VERSION}) cannot read. Use a dsync that reads format {}.x, \
         or delete {} and pair every device again.",
        path.display(),
        found.major(),
        path.display()
    )]
    ForeignVersion { path: PathBuf, found: FormatVersion },
    #[error(
        "Paired devices at {} is corrupt and cannot be trusted as either the paired set or \
         an empty one: {detail}. Restore it from a backup, or delete it and pair every \
         device again.",
        path.display()
    )]
    Corrupt { path: PathBuf, detail: String },
    #[error(transparent)]
    Pairing(#[from] PairingError),
}

/// The paired-device file. Holds no devices itself.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct PairedDeviceStore {
    path: PathBuf,
}

impl PairedDeviceStore {
    pub fn new(state: &StateDir) -> PairedDeviceStore {
        PairedDeviceStore {
            path: state.paired_devices(),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The paired set as it is on disk now. A missing file is no devices;
    /// an empty, truncated, foreign or otherwise unreadable one is an
    /// error, never read as no devices (that would silently unpair all).
    pub fn load(&self) -> Result<PairedDevices, PairedDeviceStoreError> {
        let text = match fs::read_to_string(&self.path) {
            Ok(text) => text,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(PairedDevices::default()),
            Err(source) => {
                return Err(PairedDeviceStoreError::Io {
                    path: self.path.clone(),
                    source,
                });
            }
        };
        decode(&text).map_err(|failure| match failure {
            DecodeFailure::Foreign(found) => PairedDeviceStoreError::ForeignVersion {
                path: self.path.clone(),
                found,
            },
            DecodeFailure::Corrupt(detail) => PairedDeviceStoreError::Corrupt {
                path: self.path.clone(),
                detail,
            },
        })
    }

    /// Reads the paired set, applies `change` to it and writes it back -
    /// or writes nothing when `change` refuses. Call sites name the change:
    /// `store.update(|devices| devices.grant(&id, root))`.
    pub fn update<T>(
        &self,
        change: impl FnOnce(&mut PairedDevices) -> Result<T, PairingError>,
    ) -> Result<T, PairedDeviceStoreError> {
        let mut devices = self.load()?;
        let outcome = change(&mut devices)?;
        encode(&devices)
            .and_then(|text| write_atomically(&self.path, text.as_bytes()))
            .map_err(|source| PairedDeviceStoreError::Io {
                path: self.path.clone(),
                source,
            })?;
        Ok(outcome)
    }
}

/// Unknown fields are ignored, not refused: a later minor may add them.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DocumentJson {
    version: String,
    devices: BTreeMap<String, DeviceJson>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceJson {
    name: String,
    certificate_pem: String,
    granted_roots: BTreeSet<String>,
    paired_at: String,
    last_known_address: AddressJson,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    verified_at: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct AddressJson {
    host: String,
    port: u16,
}

enum DecodeFailure {
    Foreign(FormatVersion),
    Corrupt(String),
}

fn decode(text: &str) -> Result<PairedDevices, DecodeFailure> {
    let corrupt = DecodeFailure::Corrupt;
    let value: Value = serde_json::from_str(text).map_err(|e| corrupt(e.to_string()))?;
    let version = value
        .as_object()
        .ok_or_else(|| corrupt("the document is not a JSON object".to_owned()))?
        .get("version")
        .ok_or_else(|| corrupt("no version".to_owned()))?;
    let version = version
        .as_str()
        .ok_or_else(|| corrupt(format!("version is {version}")))
        .and_then(|text| FormatVersion::parse(text).map_err(|e| corrupt(e.to_string())))?;
    PAIRED_DEVICES_FORMAT_VERSION
        .agree(version)
        .map_err(|mismatch| DecodeFailure::Foreign(mismatch.theirs()))?;
    let document: DocumentJson =
        serde_json::from_value(value).map_err(|e| corrupt(e.to_string()))?;
    let mut devices = PairedDevices::default();
    for (key, entry) in document.devices {
        let device =
            device_from_json(&key, entry).map_err(|e| corrupt(format!("device {key}: {e}")))?;
        devices
            .add(device)
            .map_err(|e| corrupt(format!("device {key}: {e}")))?;
    }
    Ok(devices)
}

fn device_from_json(key: &str, entry: DeviceJson) -> Result<PairedDevice, String> {
    let id = DeviceId::parse(key).map_err(|e| e.to_string())?;
    let certificate = Certificate::from_pem(&entry.certificate_pem).map_err(|e| e.to_string())?;
    if certificate.device_id() != id {
        return Err(format!(
            "its certificate is device {}",
            certificate.device_id()
        ));
    }
    Ok(PairedDevice::restore(
        certificate,
        PeerName::parse(&entry.name).map_err(|e| e.to_string())?,
        entry.granted_roots,
        parse_time(&entry.paired_at)?,
        PeerAddress::new(
            &entry.last_known_address.host,
            entry.last_known_address.port,
        )
        .map_err(|e| format!("lastKnownAddress: {e}"))?,
        entry.verified_at.as_deref().map(parse_time).transpose()?,
    ))
}

/// The document for `devices`. Fails only for a time with no RFC 3339
/// spelling (outside years 0-9999), which no real clock produces.
fn encode(devices: &PairedDevices) -> io::Result<String> {
    let entries = devices
        .iter()
        .map(|device| Ok((device.device_id().to_string(), device_to_json(device)?)))
        .collect::<io::Result<_>>()?;
    let document = DocumentJson {
        version: PAIRED_DEVICES_FORMAT_VERSION.to_string(),
        devices: entries,
    };
    let mut text = serde_json::to_string_pretty(&document)?;
    text.push('\n');
    Ok(text)
}

fn device_to_json(device: &PairedDevice) -> io::Result<DeviceJson> {
    Ok(DeviceJson {
        name: device.name().to_string(),
        certificate_pem: device.certificate().to_pem(),
        granted_roots: device.granted_roots().clone(),
        paired_at: format_time(device.paired_at())?,
        last_known_address: AddressJson {
            host: device.last_known_address().host().to_owned(),
            port: device.last_known_address().port(),
        },
        verified_at: device.verified_at().map(format_time).transpose()?,
    })
}

fn parse_time(text: &str) -> Result<SystemTime, String> {
    OffsetDateTime::parse(text, &Rfc3339)
        .map(SystemTime::from)
        .map_err(|e| format!("{text:?} is not an RFC 3339 time: {e}"))
}

fn format_time(time: SystemTime) -> io::Result<String> {
    OffsetDateTime::from(time)
        .format(&Rfc3339)
        .map_err(io::Error::other)
}
