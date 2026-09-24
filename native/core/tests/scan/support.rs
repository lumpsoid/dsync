//! Fixtures for the scan tests: a temp tree, archives, and lookups.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use dsync_core::Scanner;
use dsync_domain::{
    Archive, ArchiveCommit, CaseFolding, ContentHash, FileMeta, FileState, Glob, Jobs, RelPath,
    RuleSet, ScanEntry, ScanResult, SkippedReason, Status,
};
use tempfile::TempDir;

pub struct Tree {
    pub dir: TempDir,
}

impl Tree {
    pub fn new() -> Tree {
        Tree {
            dir: tempfile::tempdir().unwrap(),
        }
    }

    pub fn root(&self) -> &Path {
        self.dir.path()
    }

    pub fn at(&self, relative: &str) -> PathBuf {
        self.root().join(relative)
    }

    /// Writes `content` at `relative`, creating its folders.
    pub fn write(&self, relative: &str, content: impl AsRef<[u8]>) -> PathBuf {
        let path = self.at(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, content).unwrap();
        path
    }

    /// Sets `relative`'s mtime to exactly `mtime_us` after the epoch.
    pub fn set_mtime_us(&self, relative: &str, mtime_us: i64) {
        let file = fs::File::options()
            .write(true)
            .open(self.at(relative))
            .unwrap();
        let at = UNIX_EPOCH + Duration::from_micros(u64::try_from(mtime_us).unwrap());
        file.set_modified(at).unwrap();
    }

    pub fn scan(&self, archive: &Archive, rules: &RuleSet) -> ScanResult {
        scanner(4).scan(self.root(), archive, rules).unwrap()
    }

    /// A scan with an empty archive and no rules.
    pub fn scan_fresh(&self) -> ScanResult {
        self.scan(&Archive::default(), &RuleSet::default())
    }
}

#[cfg(unix)]
pub fn symlink(target: &Path, link: &Path) {
    std::os::unix::fs::symlink(target, link).unwrap();
}

pub fn scanner(jobs: i64) -> Scanner {
    Scanner::new(Jobs::new(jobs).unwrap(), CaseFolding::Distinct)
}

pub fn path(text: &str) -> RelPath {
    RelPath::parse(text).unwrap()
}

pub fn hash_of(content: impl AsRef<[u8]>) -> ContentHash {
    let digest = ring::digest::digest(&ring::digest::SHA256, content.as_ref());
    ContentHash::from_digest(digest.as_ref().try_into().unwrap())
}

pub fn rules(ignore: &[&str], follow: &[&str]) -> RuleSet {
    let globs = |patterns: &[&str]| patterns.iter().map(|p| Glob::new(p).unwrap()).collect();
    RuleSet::new(globs(ignore), globs(follow))
}

/// An archive entry with arbitrary metadata.
pub fn archived(size: u64, mtime_us: i64, hash: ContentHash) -> FileState {
    FileState {
        meta: FileMeta {
            size,
            mtime_us,
            mode: 0o644,
        },
        hash,
    }
}

pub fn archive_of(entries: &[(&str, FileState)], marked: &[&str]) -> Archive {
    Archive::replay(
        entries
            .iter()
            .map(|(p, file)| ArchiveCommit::Upsert {
                path: path(p),
                file: *file,
            })
            .chain(marked.iter().map(|p| ArchiveCommit::Intent(path(p)))),
    )
}

pub fn entry<'a>(result: &'a ScanResult, relative: &str) -> &'a ScanEntry {
    result
        .entries
        .iter()
        .find(|e| e.path.as_str() == relative)
        .unwrap_or_else(|| panic!("no entry for {relative} in {:?}", result.entries))
}

pub fn paths(result: &ScanResult) -> Vec<&str> {
    result.entries.iter().map(|e| e.path.as_str()).collect()
}

/// Each skipped entry's path (or `?name` for an unrepresentable one) and
/// reason, in order.
pub fn skipped(result: &ScanResult) -> Vec<(String, SkippedReason)> {
    result
        .skipped
        .iter()
        .map(|s| {
            let at = s
                .path()
                .map_or_else(|| format!("?{s:?}"), |p| p.as_str().to_owned());
            (at, s.reason)
        })
        .collect()
}

pub fn hash(status: &Status) -> ContentHash {
    status.file().expect("a present file").hash
}

/// Whether `relative` can still be read by this user after its permission
/// bits were dropped: true when running as root, where they do not bind.
#[cfg(unix)]
pub fn permissions_bind(tree: &Tree, relative: &str) -> bool {
    let path = tree.at(relative);
    let readable = if path.is_dir() {
        fs::read_dir(&path).is_ok()
    } else {
        fs::read(&path).is_ok()
    };
    if readable {
        eprintln!("skipped: permission bits do not bind for this user (root?)");
    }
    !readable
}

/// Sets `relative`'s mode, and puts `restore` back on drop, so the temp
/// tree can still be removed.
#[cfg(unix)]
pub struct Locked {
    path: PathBuf,
    restore: u32,
}

#[cfg(unix)]
impl Locked {
    pub fn new(tree: &Tree, relative: &str, mode: u32, restore: u32) -> Locked {
        use std::os::unix::fs::PermissionsExt;
        let path = tree.at(relative);
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        Locked { path, restore }
    }
}

#[cfg(unix)]
impl Drop for Locked {
    fn drop(&mut self) {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&self.path, fs::Permissions::from_mode(self.restore));
    }
}
