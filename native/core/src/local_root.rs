//! Where a local replica's paths land (SPEC §4.1): under a folder, or -
//! for a single-file entry - at exactly one file.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use dsync_domain::{Archive, RelPath, ReplicaRoot, RootKind, RuleSet, ScanResult};

use crate::scanner::{Scanner, UnreadableRoot};

/// A replica's root: the one holder of its path on disk. Every synced
/// path reaches the filesystem through [`Root::locate`], so a single-file
/// root cannot be made to touch anything but its file: a served replica
/// acts on whatever path the dialer sends, and a device granted one file
/// is granted that file only.
#[derive(Clone, Debug)]
pub struct Root {
    /// As the location names it: the archive header's root, and messages'.
    text: String,
    shape: Shape,
}

#[derive(Clone, Debug)]
enum Shape {
    Folder(PathBuf),
    /// The file `name` in `dir`, synced as `as_path` (side A's file name,
    /// which this side's may differ from).
    File {
        dir: PathBuf,
        name: RelPath,
        as_path: RelPath,
    },
}

/// A synced path as it lands on this replica: `path` on disk, and `rel`,
/// the same place relative to [`Root::base`] - what the symlink
/// confinement walks and folder bookkeeping is keyed by.
pub(crate) struct Located {
    pub(crate) path: PathBuf,
    pub(crate) rel: RelPath,
}

/// A root that cannot be opened as the spec asks.
#[derive(Debug, thiserror::Error)]
#[error("cannot open {root} as a {kind} root: {reason}")]
pub struct RootError {
    pub root: String,
    pub kind: RootKind,
    pub reason: &'static str,
}

impl Root {
    /// The folder root at `text`.
    pub fn folder(text: String) -> Root {
        Root {
            shape: Shape::Folder(PathBuf::from(&text)),
            text,
        }
    }

    /// The root at `text` of `kind`; a file root syncs its file as
    /// `as_path`, which a folder root has none of.
    pub fn new(text: String, kind: RootKind, as_path: Option<RelPath>) -> Result<Root, RootError> {
        let refused = |reason| RootError {
            root: text.clone(),
            kind,
            reason,
        };
        match (kind, as_path) {
            (RootKind::Folder, None) => Ok(Root::folder(text)),
            (RootKind::Folder, Some(_)) => Err(refused("a folder root has no synced file name")),
            (RootKind::File, None) => Err(refused("a single-file root needs its synced name")),
            (RootKind::File, Some(as_path)) => {
                let path = Path::new(&text);
                let name = path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .and_then(|name| RelPath::parse(name).ok())
                    .ok_or_else(|| refused("the path does not end in a file name"))?;
                // A bare `notes.md` has the empty parent: the folder it
                // is in is the current one.
                let dir = match path.parent() {
                    Some(dir) if !dir.as_os_str().is_empty() => dir.to_path_buf(),
                    _ => PathBuf::from("."),
                };
                Ok(Root {
                    shape: Shape::File { dir, name, as_path },
                    text,
                })
            }
        }
    }

    /// As the location names it.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// The root itself: the folder, or the file.
    pub fn path(&self) -> &Path {
        Path::new(&self.text)
    }

    /// The folder this root is or sits in: where probes run and the
    /// symlink confinement starts. Never join a synced path onto it;
    /// [`Root::locate`] does that.
    pub(crate) fn base(&self) -> &Path {
        match &self.shape {
            Shape::Folder(folder) => folder,
            Shape::File { dir, .. } => dir,
        }
    }

    /// Where the synced `path` lands. A single-file root takes exactly its
    /// synced name and refuses every other path - a sibling, or one below
    /// or above the file.
    pub(crate) fn locate(&self, path: &RelPath) -> io::Result<Located> {
        match &self.shape {
            Shape::Folder(folder) => Ok(Located {
                path: path.join_under(folder),
                rel: path.clone(),
            }),
            Shape::File { dir, name, as_path } if path == as_path => Ok(Located {
                path: name.join_under(dir),
                rel: name.clone(),
            }),
            Shape::File { as_path, .. } => Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("{path} is outside this replica, which syncs the one file {as_path}"),
            )),
        }
    }

    /// Whether the root is there to sync, as `hello` reports it (SPEC
    /// §4.5). `archived_files` counts the archive, asked only for a
    /// missing folder root. A file root whose folder is there is present
    /// with or without its file.
    pub(crate) fn state(&self, archived_files: impl FnOnce() -> u64) -> ReplicaRoot {
        match &self.shape {
            Shape::Folder(folder) => match fs::metadata(folder) {
                Ok(meta) if meta.is_dir() => ReplicaRoot::Present,
                Ok(_) => ReplicaRoot::WrongKind {
                    root_path: self.text.clone(),
                    expected: RootKind::Folder,
                },
                Err(_) => ReplicaRoot::Missing {
                    root_path: self.text.clone(),
                    archived_files: archived_files(),
                },
            },
            Shape::File { dir, .. } if !dir.is_dir() => ReplicaRoot::ParentMissing {
                root_path: self.text.clone(),
                folder: dir.display().to_string(),
            },
            Shape::File { .. } if self.path().is_dir() => ReplicaRoot::WrongKind {
                root_path: self.text.clone(),
                expected: RootKind::File,
            },
            Shape::File { .. } => ReplicaRoot::Present,
        }
    }

    /// Creates a folder root. A file root is never created, nor the
    /// folder it sits in.
    pub(crate) fn create(&self) -> io::Result<()> {
        match &self.shape {
            Shape::Folder(folder) => fs::create_dir_all(folder),
            Shape::File { .. } => Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "a single-file root is never created",
            )),
        }
    }

    /// Scans the root with `scanner`: a folder walked under `rules`, or the
    /// one file, which no rule applies to - the entry named it.
    pub(crate) fn scan(
        &self,
        scanner: &Scanner,
        archive: &Archive,
        rules: &RuleSet,
    ) -> Result<ScanResult, UnreadableRoot> {
        match &self.shape {
            Shape::Folder(folder) => scanner.scan(folder, archive, rules),
            Shape::File { dir, name, as_path } => {
                scanner.scan_file(dir, &name.join_under(dir), as_path, archive)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rel(text: &str) -> RelPath {
        RelPath::parse(text).unwrap()
    }

    fn file_root(text: &str, as_path: &str) -> Root {
        Root::new(text.to_owned(), RootKind::File, Some(rel(as_path))).unwrap()
    }

    #[test]
    fn a_file_root_locates_only_its_synced_name_at_its_own_name() {
        let root = file_root("/x/mine.md", "notes.md");
        let located = root.locate(&rel("notes.md")).unwrap();
        assert_eq!(located.path, Path::new("/x/mine.md"));
        assert_eq!(located.rel, rel("mine.md"));
        for other in ["mine.md", "other.md", "notes.md/x", "sub/notes.md"] {
            let refused = root.locate(&rel(other)).err();
            assert_eq!(
                refused.map(|e| e.kind()),
                Some(io::ErrorKind::PermissionDenied),
                "{other}"
            );
        }
    }

    #[test]
    fn a_folder_root_locates_every_path_under_it() {
        let root = Root::folder("/x".to_owned());
        let located = root.locate(&rel("a/b.md")).unwrap();
        assert_eq!(located.path, Path::new("/x/a/b.md"));
        assert_eq!(located.rel, rel("a/b.md"));
    }

    #[test]
    fn a_bare_file_name_sits_in_the_current_folder() {
        let root = file_root("notes.md", "notes.md");
        assert_eq!(root.base(), Path::new("."));
        assert_eq!(
            root.locate(&rel("notes.md")).unwrap().path,
            Path::new("./notes.md")
        );
    }

    #[test]
    fn a_root_the_kind_and_name_disagree_on_is_refused() {
        assert!(Root::new("/x".into(), RootKind::Folder, Some(rel("x"))).is_err());
        assert!(Root::new("/x/n.md".into(), RootKind::File, None).is_err());
        assert!(Root::new("/".into(), RootKind::File, Some(rel("n.md"))).is_err());
        assert!(Root::new("/x/n.md".into(), RootKind::File, Some(rel("n.md"))).is_ok());
    }
}
