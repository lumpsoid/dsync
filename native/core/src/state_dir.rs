//! The state directory and the names of the per-replica files in it
//! (SPEC §8.3): `<profileId>-<side>.jsonl` (archive), `<profileId>-<side>.lock`
//! and `<profileId>.run`.

use std::path::{Path, PathBuf};

use dsync_domain::{DirError, HostFacts, ProfileId, Side, StateDirChoice};

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

    /// `<state>/<profileId>-<side>.jsonl`.
    pub fn archive_log(&self, profile: &ProfileId, side: Side) -> PathBuf {
        self.0
            .join(format!("{}-{side}{ARCHIVE_SUFFIX}", profile.as_str()))
    }

    /// `<state>/<profileId>-<side>.lock`.
    pub fn lock(&self, profile: &ProfileId, side: Side) -> PathBuf {
        self.0.join(format!("{}-{side}.lock", profile.as_str()))
    }

    /// `<state>/<profileId>.run`.
    pub fn run_marker(&self, profile: &ProfileId) -> PathBuf {
        self.0.join(format!("{}.run", profile.as_str()))
    }
}

/// The replica an archive log's file name belongs to, or `None` for any
/// name [`StateDir::archive_log`] does not produce.
pub(crate) fn archive_log_owner(file_name: &str) -> Option<(ProfileId, Side)> {
    let stem = file_name.strip_suffix(ARCHIVE_SUFFIX)?;
    let (profile, side) = stem.rsplit_once('-')?;
    Some((ProfileId::parse(profile).ok()?, Side::from_key(side)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn names_the_per_replica_files() {
        let state = StateDir::new("/state");
        let profile = ProfileId::parse(ID).unwrap();
        assert_eq!(
            state.archive_log(&profile, Side::A),
            PathBuf::from(format!("/state/{ID}-a.jsonl"))
        );
        assert_eq!(
            state.lock(&profile, Side::B),
            PathBuf::from(format!("/state/{ID}-b.lock"))
        );
        assert_eq!(
            state.run_marker(&profile),
            PathBuf::from(format!("/state/{ID}.run"))
        );
    }

    #[test]
    fn reads_the_owner_back_from_a_log_name_only() {
        let profile = ProfileId::parse(ID).unwrap();
        assert_eq!(
            archive_log_owner(&format!("{ID}-b.jsonl")),
            Some((profile, Side::B))
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
