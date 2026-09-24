//! A device's TLS identity: a self-signed ECDSA P-256 end-entity certificate
//! and its key. End entity, not CA: webpki (which rustls uses to check a
//! handshake signature against the certificate) refuses a CA-flagged
//! certificate as a peer's leaf.

use std::fs;
use std::path::Path;

use anyhow::{Context, anyhow};
use rcgen::{CertificateParams, DistinguishedName, DnType, IsCa, KeyPair};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

use crate::device_id::DeviceId;

const CERTIFICATE_FILE: &str = "cert.pem";
const KEY_FILE: &str = "key.pem";

pub struct Identity {
    certificate: CertificateDer<'static>,
    key: PrivatePkcs8KeyDer<'static>,
    device_id: DeviceId,
}

impl Identity {
    /// A fresh identity, held in memory only.
    pub fn generate() -> anyhow::Result<Self> {
        Ok(Self::generate_with_pem()?.0)
    }

    /// A fresh identity and its certificate and key as PEM.
    fn generate_with_pem() -> anyhow::Result<(Self, String, String)> {
        let key = KeyPair::generate()?;
        let mut params = CertificateParams::new(vec!["dsync".to_string()])?;
        params.is_ca = IsCa::ExplicitNoCa;
        let mut name = DistinguishedName::new();
        name.push(DnType::CommonName, "dsync device");
        params.distinguished_name = name;
        let certificate = params.self_signed(&key)?;
        let identity = Self::new(
            certificate.der().clone(),
            PrivatePkcs8KeyDer::from(key.serialize_der()),
        )?;
        Ok((identity, certificate.pem(), key.serialize_pem()))
    }

    /// The identity stored in [dir], created there first if there is none.
    pub fn load_or_create(dir: &Path) -> anyhow::Result<Self> {
        let certificate_path = dir.join(CERTIFICATE_FILE);
        let key_path = dir.join(KEY_FILE);
        if certificate_path.exists() && key_path.exists() {
            let certificate = CertificateDer::from_pem_file(&certificate_path)
                .with_context(|| format!("reading {}", certificate_path.display()))?;
            let key = match PrivateKeyDer::from_pem_file(&key_path)
                .with_context(|| format!("reading {}", key_path.display()))?
            {
                PrivateKeyDer::Pkcs8(key) => key,
                _ => return Err(anyhow!("{} is not a PKCS#8 key", key_path.display())),
            };
            return Self::new(certificate, key);
        }
        let (identity, certificate_pem, key_pem) = Self::generate_with_pem()?;
        fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        fs::write(&certificate_path, certificate_pem)?;
        write_private(&key_path, key_pem.as_bytes())?;
        Ok(identity)
    }

    fn new(
        certificate: CertificateDer<'static>,
        key: PrivatePkcs8KeyDer<'static>,
    ) -> anyhow::Result<Self> {
        let device_id = DeviceId::from_certificate_der(&certificate)?;
        Ok(Identity {
            certificate,
            key,
            device_id,
        })
    }

    pub fn device_id(&self) -> DeviceId {
        self.device_id.clone()
    }

    pub fn certificate_der(&self) -> &[u8] {
        self.certificate.as_ref()
    }

    pub(crate) fn certificate(&self) -> CertificateDer<'static> {
        self.certificate.clone()
    }

    pub(crate) fn key(&self) -> PrivateKeyDer<'static> {
        PrivateKeyDer::Pkcs8(self.key.clone_key())
    }
}

#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("writing {}", path.display()))?;
    file.write_all(bytes)?;
    Ok(())
}

#[cfg(not(unix))]
fn write_private(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    fs::write(path, bytes).with_context(|| format!("writing {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stored_identity_loads_back_with_the_same_id() {
        let dir = tempfile::tempdir().unwrap();
        let created = Identity::load_or_create(dir.path()).unwrap();
        let loaded = Identity::load_or_create(dir.path()).unwrap();
        assert_eq!(created.device_id(), loaded.device_id());
        assert_eq!(created.certificate_der(), loaded.certificate_der());
    }
}
