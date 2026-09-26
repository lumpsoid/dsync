//! Keeping a replica's reads, writes and deletes off the links it may not
//! go through ([`Symlinks`], SPEC §4.4). The filesystem side: resolving
//! the grants and each link on a path; whether a resolved target is
//! allowed is [`Symlinks::refuses`]'.

use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, PoisonError};

use dsync_domain::RelPath;

use crate::symlinks::Symlinks;

/// One replica's check that a path goes through no link it may not,
/// shared for the session by the replica and its writers.
pub(crate) struct Confinement {
    root: PathBuf,
    symlinks: Symlinks,
    /// Folders this session found to be real folders or allowed links, so
    /// a folder is looked at once, not once per file under it.
    folders: Mutex<HashSet<String>>,
}

impl Confinement {
    /// The check for the replica at `root`. Each granted root is resolved
    /// here, so a grant reached through a link (`/sdcard` on Android)
    /// compares with the resolved targets; one that does not resolve yet
    /// stays as granted. Blocks.
    pub(crate) fn new(root: PathBuf, symlinks: Symlinks) -> Confinement {
        let symlinks = match symlinks {
            Symlinks::AsRuled => Symlinks::AsRuled,
            Symlinks::WithinGrants(grants) => Symlinks::WithinGrants(
                grants.map_roots(|root| fs::canonicalize(&root).unwrap_or(root)),
            ),
        };
        Confinement {
            root,
            symlinks,
            folders: Mutex::new(HashSet::new()),
        }
    }

    /// The bound, its grants resolved: what the scan follows by.
    pub(crate) fn symlinks(&self) -> &Symlinks {
        &self.symlinks
    }

    fn folders(&self) -> MutexGuard<'_, HashSet<String>> {
        self.folders.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Refuses `path` when it, or a folder above it inside the root, is a
    /// link whose resolved target this replica may not reach, or one that
    /// does not resolve. Whatever does not exist yet passes: nothing under
    /// it can be a link, and a write creates real folders.
    pub(crate) fn check(&self, path: &RelPath) -> io::Result<()> {
        if self.symlinks == Symlinks::AsRuled {
            return Ok(());
        }
        let mut at = self.root.clone();
        let mut steps = path.prefixes().zip(path.segments()).peekable();
        while let Some((prefix, segment)) = steps.next() {
            at.push(segment);
            let folder = steps.peek().is_some();
            if folder && self.folders().contains(prefix) {
                continue;
            }
            let meta = match fs::symlink_metadata(&at) {
                Ok(meta) => meta,
                Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
                Err(error) => return Err(error),
            };
            if meta.file_type().is_symlink() {
                let Ok(target) = fs::canonicalize(&at) else {
                    return Err(refused(format!(
                        "{prefix} is a symlink whose target cannot be resolved"
                    )));
                };
                if let Some(why) = self.symlinks.refuses(&target) {
                    return Err(refused(format!("{prefix} is a symlink with its {why}")));
                }
            } else if !meta.is_dir() {
                continue;
            }
            if folder {
                self.folders().insert(prefix.to_owned());
            }
        }
        Ok(())
    }

    /// Forgets `folder`: it was removed, so whatever takes its place is
    /// looked at again.
    pub(crate) fn forget(&self, folder: &RelPath) {
        self.folders().remove(folder.as_str());
    }
}

fn refused(why: String) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, why)
}
