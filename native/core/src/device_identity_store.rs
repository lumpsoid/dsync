//! This installation's identity on disk: `identity.crt` and `identity.key`
//! in the state directory (SPEC §4.4, §8.3), both PEM.
//!
//! Generate once, reuse after. The key is written owner-only (0600 on
//! unix) from the moment its temp file is created, so it never sits on
//! disk at a looser mode; the certificate is public (a peer pins the key,
//! not the secrecy of these bytes). Renewal rewrites the certificate only.
//! What finally gates the key is still every directory above it, which
//! this store does not create with any particular mode.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::atomic_write::{FileAccess, write_atomically, write_atomically_with};
use crate::device_identity::{DeviceIdentity, IdentityIssueError, IdentityPairError};
use crate::state_dir::StateDir;

#[derive(Debug, thiserror::Error)]
pub enum IdentityError {
    #[error("Device identity {}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    /// Exactly one of the two files: a crash inside the first generation.
    /// Regenerating would silently mint a different device id than the
    /// half that survived, so this refuses instead.
    #[error(
        "Device identity is incomplete: {} exists but {} does not. \
         Delete {} to generate a fresh identity (every paired device must then pair again).",
        present.display(),
        missing.display(),
        present.display()
    )]
    Incomplete { present: PathBuf, missing: PathBuf },
    #[error("There is no device identity in {} to renew.", dir.display())]
    Missing { dir: PathBuf },
    #[error(
        "Device identity {} cannot be read ({detail}). Delete {} and {} to generate a \
         fresh identity (every paired device must then pair again).",
        certificate.display(),
        certificate.display(),
        key.display()
    )]
    Corrupt {
        certificate: PathBuf,
        key: PathBuf,
        detail: IdentityPairError,
    },
    #[error(transparent)]
    Issue(#[from] IdentityIssueError),
}

/// The identity files in one state directory. Holds no identity itself:
/// every call reads the files.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct DeviceIdentityStore {
    certificate: PathBuf,
    key: PathBuf,
}

impl DeviceIdentityStore {
    pub fn new(state: &StateDir) -> DeviceIdentityStore {
        DeviceIdentityStore {
            certificate: state.identity_certificate(),
            key: state.identity_key(),
        }
    }

    pub fn certificate_path(&self) -> &Path {
        &self.certificate
    }

    pub fn key_path(&self) -> &Path {
        &self.key
    }

    /// The stored identity, or `None` when neither file exists.
    pub fn load(&self) -> Result<Option<DeviceIdentity>, IdentityError> {
        let certificate = read(&self.certificate)?;
        let key = read(&self.key)?;
        match (certificate, key) {
            (None, None) => Ok(None),
            (Some(certificate), Some(key)) => self.parse(&certificate, &key).map(Some),
            (Some(_), None) => Err(incomplete(&self.certificate, &self.key)),
            (None, Some(_)) => Err(incomplete(&self.key, &self.certificate)),
        }
    }

    /// The stored identity, generated and written first when there is
    /// none. `common_name` names only that first generation; an existing
    /// identity is read back exactly as stored.
    pub fn load_or_create(
        &self,
        common_name: &str,
        now: SystemTime,
    ) -> Result<DeviceIdentity, IdentityError> {
        if let Some(identity) = self.load()? {
            return Ok(identity);
        }
        let identity = DeviceIdentity::generate(common_name, now)?;
        // Key first: a crash before the certificate lands is reported as
        // incomplete by the next load, never regenerated over.
        write_atomically_with(
            &self.key,
            identity.key_pem().as_bytes(),
            FileAccess::OwnerOnly,
        )
        .map_err(|source| io_error(&self.key, source))?;
        self.write_certificate(&identity)?;
        Ok(identity)
    }

    /// Re-issues the stored certificate under the stored key and writes it
    /// in place of the old one (SPEC §4.4): same device id, fresh dates.
    /// `common_name` renames this device; `None` keeps its name. The key
    /// file is not touched.
    pub fn renew(
        &self,
        common_name: Option<&str>,
        now: SystemTime,
    ) -> Result<DeviceIdentity, IdentityError> {
        let existing = self.load()?.ok_or_else(|| IdentityError::Missing {
            dir: self
                .certificate
                .parent()
                .map(Path::to_owned)
                .unwrap_or_default(),
        })?;
        let renewed = existing.renewed(common_name, now)?;
        self.write_certificate(&renewed)?;
        Ok(renewed)
    }

    fn write_certificate(&self, identity: &DeviceIdentity) -> Result<(), IdentityError> {
        write_atomically(
            &self.certificate,
            identity.certificate().to_pem().as_bytes(),
        )
        .map_err(|source| io_error(&self.certificate, source))?;
        Ok(())
    }

    fn parse(&self, certificate: &str, key: &str) -> Result<DeviceIdentity, IdentityError> {
        DeviceIdentity::from_pem(certificate, key).map_err(|detail| IdentityError::Corrupt {
            certificate: self.certificate.clone(),
            key: self.key.clone(),
            detail,
        })
    }
}

fn incomplete(present: &Path, missing: &Path) -> IdentityError {
    IdentityError::Incomplete {
        present: present.to_owned(),
        missing: missing.to_owned(),
    }
}

fn read(path: &Path) -> Result<Option<String>, IdentityError> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(source) => Err(io_error(path, source)),
    }
}

fn io_error(path: &Path, source: io::Error) -> IdentityError {
    IdentityError::Io {
        path: path.to_owned(),
        source,
    }
}
