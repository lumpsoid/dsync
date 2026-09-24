//! Profiles on disk (SPEC §12, plan D7): one TOML file per profile at
//! `<config>/profiles/<name>.toml`, the file name being the profile's
//! name. The CLI and the head share this one store.
//!
//! Every save replaces the whole file atomically, so a head and a CLI
//! editing profiles at once can lose one update but never tear a file.
//! Nothing is cached: every call reads the directory or the file.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use dsync_domain::{DirError, DirRule, HostFacts, Platform, Profile, ProfileError, ProfileName};

use crate::atomic_write::{sync_dir, write_atomically};

const PROFILES_DIR: &str = "profiles";
const EXTENSION: &str = ".toml";

#[derive(Debug, thiserror::Error)]
pub enum ProfileStoreError {
    #[error("No profile named \"{name}\" (looked for {})", path.display())]
    NotFound { name: ProfileName, path: PathBuf },
    #[error("A profile named \"{name}\" already exists ({})", path.display())]
    Exists { name: ProfileName, path: PathBuf },
    #[error("Profile {}: {source}", path.display())]
    Invalid {
        path: PathBuf,
        #[source]
        source: ProfileError,
    },
    #[error("Profile {}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

/// The `profiles` directory under one config directory. Need not exist:
/// listing it is then empty, and the first save creates it.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ProfileStore {
    dir: PathBuf,
}

impl ProfileStore {
    /// The store under `config_dir` (the dsync config directory itself,
    /// leaf included).
    pub fn new(config_dir: impl AsRef<Path>) -> ProfileStore {
        ProfileStore {
            dir: config_dir.as_ref().join(PROFILES_DIR),
        }
    }

    /// The store under the config directory `rule` resolves to on `host`
    /// (see [`dsync_domain::config_dir`]).
    pub fn resolve(rule: &DirRule, host: &HostFacts) -> Result<ProfileStore, DirError> {
        dsync_domain::config_dir(rule, host).map(ProfileStore::new)
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// `<config>/profiles/<name>.toml`.
    pub fn path(&self, name: &ProfileName) -> PathBuf {
        self.dir.join(format!("{name}{EXTENSION}"))
    }

    /// Every stored profile's name, sorted. A file whose name is not
    /// `<valid name>.toml` (a temp left by a crash, a backup, a note) is not
    /// a profile and is not listed.
    pub fn list(&self) -> Result<Vec<ProfileName>, ProfileStoreError> {
        let entries = match fs::read_dir(&self.dir) {
            Ok(entries) => entries,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(vec![]),
            Err(source) => return Err(io_error(&self.dir, source)),
        };
        let mut names = vec![];
        for entry in entries {
            let entry = entry.map_err(|source| io_error(&self.dir, source))?;
            let file_name = entry.file_name();
            let name = file_name
                .to_str()
                .and_then(|file_name| file_name.strip_suffix(EXTENSION))
                .and_then(|stem| ProfileName::parse(stem).ok());
            if let Some(name) = name
                && entry.path().is_file()
            {
                names.push(name);
            }
        }
        names.sort();
        Ok(names)
    }

    /// The profile `name`, its locations parsed by `platform`'s rules.
    pub fn load(
        &self,
        name: &ProfileName,
        platform: Platform,
    ) -> Result<Profile, ProfileStoreError> {
        let path = self.path(name);
        let text = match fs::read_to_string(&path) {
            Ok(text) => text,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                return Err(ProfileStoreError::NotFound {
                    name: name.clone(),
                    path,
                });
            }
            Err(source) => return Err(io_error(&path, source)),
        };
        Profile::parse(&text, platform)
            .map_err(|source| ProfileStoreError::Invalid { path, source })
    }

    /// Writes `profile` as `name`, replacing any profile by that name (an
    /// edit).
    pub fn save(&self, name: &ProfileName, profile: &Profile) -> Result<(), ProfileStoreError> {
        let path = self.path(name);
        write_atomically(&path, profile.to_toml().as_bytes())
            .map_err(|source| io_error(&path, source))?;
        Ok(())
    }

    /// Writes `profile` as a new profile `name`, refused when one exists.
    pub fn create(&self, name: &ProfileName, profile: &Profile) -> Result<(), ProfileStoreError> {
        self.refuse_existing(name)?;
        self.save(name, profile)
    }

    /// Renames profile `from` to `to`, refused when `from` does not exist
    /// or `to` does. The profile id does not change: it is derived from the
    /// replicas, not the name, so the archives stay with the profile.
    pub fn rename(&self, from: &ProfileName, to: &ProfileName) -> Result<(), ProfileStoreError> {
        let source = self.path(from);
        if !exists(&source)? {
            return Err(ProfileStoreError::NotFound {
                name: from.clone(),
                path: source,
            });
        }
        if from == to {
            return Ok(());
        }
        self.refuse_existing(to)?;
        fs::rename(&source, self.path(to)).map_err(|e| io_error(&source, e))?;
        sync_dir(&self.dir).map_err(|e| io_error(&self.dir, e))?;
        Ok(())
    }

    /// Deletes profile `name`. Its archives are not touched (they belong to
    /// the replica pair, which another profile or an ad-hoc run may share).
    pub fn delete(&self, name: &ProfileName) -> Result<(), ProfileStoreError> {
        let path = self.path(name);
        match fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                return Err(ProfileStoreError::NotFound {
                    name: name.clone(),
                    path,
                });
            }
            Err(source) => return Err(io_error(&path, source)),
        }
        sync_dir(&self.dir).map_err(|e| io_error(&self.dir, e))?;
        Ok(())
    }

    fn refuse_existing(&self, name: &ProfileName) -> Result<(), ProfileStoreError> {
        let path = self.path(name);
        if exists(&path)? {
            return Err(ProfileStoreError::Exists {
                name: name.clone(),
                path,
            });
        }
        Ok(())
    }
}

fn exists(path: &Path) -> Result<bool, ProfileStoreError> {
    path.try_exists().map_err(|e| io_error(path, e))
}

fn io_error(path: &Path, source: io::Error) -> ProfileStoreError {
    ProfileStoreError::Io {
        path: path.to_owned(),
        source,
    }
}
