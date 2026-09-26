//! The state directory and the names of the per-replica files in it
//! (SPEC §8.3): `<entryId>-<side>.jsonl` (archive), `<entryId>-<side>.lock`
//! and `<entryId>.run`; and the per-folder `folder-<hash>.lock`.

use std::path::{Path, PathBuf};

use dsync_domain::{DirError, EntryId, HostFacts, Side, StateDirChoice};

const ARCHIVE_SUFFIX: &str = ".jsonl";

/// A resolved state directory. Not required to exist: a host that has
/// never synced has none, and the stores create it on first write.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct StateDir(PathBuf);

impl StateDir {
    pub fn new(path: impl Into<PathBuf>) -> StateDir {
        StateDir(path.into())
    }

    /// The directory `choice` resolves to on `host` (see
    /// [`dsync_domain::state_dir`]).
    pub fn resolve(choice: &StateDirChoice, host: &HostFacts) -> Result<StateDir, DirError> {
        dsync_domain::state_dir(choice, host).map(StateDir)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }

    /// `<state>/identity.crt`: this installation's certificate (PEM).
    pub fn identity_certificate(&self) -> PathBuf {
        self.0.join("identity.crt")
    }

    /// `<state>/identity.key`: its private key (PKCS#8 PEM, owner-only).
    pub fn identity_key(&self) -> PathBuf {
        self.0.join("identity.key")
    }

    /// `<state>/paired-devices.json`.
    pub fn paired_devices(&self) -> PathBuf {
        self.0.join("paired-devices.json")
    }

    /// `<state>/<entryId>-<side>.jsonl`.
    pub fn archive_log(&self, entry_id: &EntryId, side: Side) -> PathBuf {
        self.0
            .join(format!("{}-{side}{ARCHIVE_SUFFIX}", entry_id.as_str()))
    }

    /// `<state>/<entryId>-<side>.lock`.
    pub fn lock(&self, entry_id: &EntryId, side: Side) -> PathBuf {
        self.0.join(format!("{}-{side}.lock", entry_id.as_str()))
    }

    /// `<state>/folder-<hash>.lock`: the lock on the folder at `canonical`
    /// (see [`crate::replica_lock::canonical_root`]), whatever profile
    /// syncs it. The hash is the first 16 bytes of the path's SHA-256, in
    /// hex, so any path gives a short, valid file name.
    pub fn folder_lock(&self, canonical: &Path) -> PathBuf {
        let digest = ring::digest::digest(
            &ring::digest::SHA256,
            canonical.as_os_str().as_encoded_bytes(),
        );
        let hash: String = digest.as_ref()[..16]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        self.0.join(format!("folder-{hash}.lock"))
    }

    /// `<state>/<entryId>.run`.
    pub fn run_marker(&self, entry_id: &EntryId) -> PathBuf {
        self.0.join(format!("{}.run", entry_id.as_str()))
    }
}

/// The replica an archive log's file name belongs to, or `None` for any
/// name [`StateDir::archive_log`] does not produce.
pub(crate) fn archive_log_owner(file_name: &str) -> Option<(EntryId, Side)> {
    let stem = file_name.strip_suffix(ARCHIVE_SUFFIX)?;
    let (entry_id, side) = stem.rsplit_once('-')?;
    Some((EntryId::parse(entry_id).ok()?, Side::from_key(side)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn names_the_per_replica_files() {
        let state = StateDir::new("/state");
        let entry_id = EntryId::parse(ID).unwrap();
        assert_eq!(
            state.archive_log(&entry_id, Side::A),
            PathBuf::from(format!("/state/{ID}-a.jsonl"))
        );
        assert_eq!(
            state.lock(&entry_id, Side::B),
            PathBuf::from(format!("/state/{ID}-b.lock"))
        );
        assert_eq!(
            state.run_marker(&entry_id),
            PathBuf::from(format!("/state/{ID}.run"))
        );
    }

    #[test]
    fn names_a_folders_lock_by_its_path_alone() {
        let state = StateDir::new("/state");
        let lock = state.folder_lock(Path::new("/home/me/Docs"));
        let name = lock.file_name().unwrap().to_str().unwrap();
        assert_eq!(lock.parent(), Some(Path::new("/state")));
        assert!(
            name.starts_with("folder-") && name.ends_with(".lock"),
            "{name}"
        );
        assert_eq!(name.len(), "folder-".len() + 32 + ".lock".len());
        assert_eq!(state.folder_lock(Path::new("/home/me/Docs")), lock);
        assert_ne!(state.folder_lock(Path::new("/home/me/Docs/Photos")), lock);
    }

    #[test]
    fn reads_the_owner_back_from_a_log_name_only() {
        let entry_id = EntryId::parse(ID).unwrap();
        assert_eq!(
            archive_log_owner(&format!("{ID}-b.jsonl")),
            Some((entry_id, Side::B))
        );
        for other in [
            format!("{ID}-a.lock"),
            format!("{ID}-c.jsonl"),
            format!("{ID}.jsonl"),
            format!("{ID}-a.jsonl.dsync-tmp.1.2"),
            "notes-a.jsonl".to_owned(),
            "paired-devices.json".to_owned(),
        ] {
            assert_eq!(archive_log_owner(&other), None, "{other}");
        }
    }
}
