//! The filter preview's listing (the counting is the domain's
//! [`preview_filters`] and [`filter_folder_rows`]).
//!
//! Unlike a scan, this descends into ignored folders: the number the user
//! is deciding on is how much a rule removes, which a pruned walk never
//! sees. Links are listed, never followed. A name that cannot be a
//! [`RelPath`] is left out: no run carries it, and the scan reports it.

use std::fs::{self, FileType};
use std::io;
use std::path::{Path, PathBuf};

use dsync_domain::{
    EntryKind, FilterFolderRow, FilterPreviewReport, ListedEntry, RelPath, RuleSet,
    filter_folder_rows, preview_filters,
};

use crate::scanner::{child_path, describe};

/// The folder asked for could not be listed: the whole answer, since there
/// is nothing under it to count.
#[derive(Debug, thiserror::Error)]
#[error("cannot list {}: {}", folder.display(), describe(source))]
pub struct UnlistableFolder {
    pub folder: PathBuf,
    #[source]
    pub source: io::Error,
}

/// The whole tree under `root` counted against `rules`. A subfolder that
/// cannot be listed is reported in the result, not failed on.
pub fn preview_filters_at(
    root: &Path,
    rules: &RuleSet,
) -> Result<FilterPreviewReport, UnlistableFolder> {
    let mut listing = Vec::new();
    let mut unreadable = Vec::new();
    let children = list(root)?;
    list_tree(None, children, &mut listing, &mut unreadable);
    Ok(preview_filters(&listing, unreadable, rules))
}

/// One folder's rows (`None`: the root), for browsing the tree.
pub fn list_filter_folder(
    root: &Path,
    folder: Option<&RelPath>,
    rules: &RuleSet,
) -> Result<Vec<FilterFolderRow>, UnlistableFolder> {
    let dir = folder.map_or_else(|| root.to_path_buf(), |f| f.join_under(root));
    let listing = list(&dir)?
        .into_iter()
        .filter_map(|(path, source, kind)| listed(child_path(folder, &path).ok()?, &source, kind))
        .collect();
    Ok(filter_folder_rows(listing, rules))
}

/// `dir`'s entries: name, full path and type as listed. An entry whose
/// type cannot be read, or whose name is not UTF-8, is left out.
fn list(dir: &Path) -> Result<Vec<(String, PathBuf, FileType)>, UnlistableFolder> {
    let unlistable = |source| UnlistableFolder {
        folder: dir.to_path_buf(),
        source,
    };
    let mut children = Vec::new();
    for entry in fs::read_dir(dir).map_err(unlistable)? {
        let entry = entry.map_err(unlistable)?;
        let (Ok(kind), Ok(name)) = (entry.file_type(), entry.file_name().into_string()) else {
            continue;
        };
        children.push((name, entry.path(), kind));
    }
    Ok(children)
}

/// A listed entry, or `None` for a file that vanished before its size was
/// read.
fn listed(path: RelPath, source: &Path, kind: FileType) -> Option<ListedEntry> {
    let kind = if kind.is_dir() {
        EntryKind::Folder
    } else if kind.is_file() {
        EntryKind::File {
            size: fs::symlink_metadata(source).ok()?.len(),
        }
    } else {
        EntryKind::Other
    };
    Some(ListedEntry { path, kind })
}

fn list_tree(
    parent: Option<&RelPath>,
    children: Vec<(String, PathBuf, FileType)>,
    listing: &mut Vec<ListedEntry>,
    unreadable: &mut Vec<RelPath>,
) {
    for (name, source, kind) in children {
        let Ok(path) = child_path(parent, &name) else {
            continue;
        };
        if kind.is_dir() {
            // A folder that cannot be listed gets no node, only a mention.
            match list(&source) {
                Ok(grandchildren) => {
                    listing.push(ListedEntry {
                        path: path.clone(),
                        kind: EntryKind::Folder,
                    });
                    list_tree(Some(&path), grandchildren, listing, unreadable);
                }
                Err(_) => unreadable.push(path),
            }
        } else if let Some(entry) = listed(path, &source, kind) {
            listing.push(entry);
        }
    }
}
