//! What a replica's ignore rules keep out of a sync, counted (the filter
//! preview). The core lists the tree; this counts it.
//!
//! Unlike a scan, the listing descends into excluded folders: the number
//! the user is deciding on is how much a rule removes, which a pruned walk
//! never sees. Only regular files are counted; a symlink or other entry is
//! carried by no run, so it counts against no rule.

use std::collections::BTreeMap;

use crate::glob::Glob;
use crate::rel_path::RelPath;
use crate::rule_set::RuleSet;

/// What a listed directory entry is, as read without following links.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EntryKind {
    File {
        size: u64,
    },
    Folder,
    /// A symlink, socket, device: no run carries it.
    Other,
}

/// One entry of a tree listing.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ListedEntry {
    pub path: RelPath,
    pub kind: EntryKind,
}

/// The counted tree.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct FilterPreviewReport {
    pub root: FilterPreviewFolder,
    /// Every ignore rule in written order with the files it keeps out.
    /// A file excluded by several is counted against the one
    /// [`RuleSet::ignore_rule_for`] names, so the counts sum to
    /// `excluded_files`.
    pub excluded_by_rule: Vec<(Glob, u64)>,
    /// Folders whose listing failed, in the order the core met them.
    pub unreadable_folders: Vec<RelPath>,
}

/// One folder and its whole subtree's totals.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct FilterPreviewFolder {
    /// `None` for the replica root.
    pub path: Option<RelPath>,
    /// The rule keeping this folder out, if one does.
    pub excluded_by: Option<Glob>,
    pub included_files: u64,
    pub included_bytes: u64,
    pub excluded_files: u64,
    pub excluded_bytes: u64,
    /// Subfolders by case-insensitive name.
    pub folders: Vec<FilterPreviewFolder>,
}

/// One row of a single folder's listing, for browsing the tree.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct FilterFolderRow {
    pub path: RelPath,
    pub kind: EntryKind,
    /// Always `None` for [`EntryKind::Other`], which no rule applies to.
    pub excluded_by: Option<Glob>,
}

impl FilterFolderRow {
    pub fn name(&self) -> &str {
        self.path.name()
    }

    /// Whether a run would carry it.
    pub fn syncs(&self) -> bool {
        self.excluded_by.is_none() && self.kind != EntryKind::Other
    }
}

impl FilterPreviewReport {
    pub fn included_files(&self) -> u64 {
        self.root.included_files
    }

    pub fn included_bytes(&self) -> u64 {
        self.root.included_bytes
    }

    pub fn excluded_files(&self) -> u64 {
        self.root.excluded_files
    }

    pub fn excluded_bytes(&self) -> u64 {
        self.root.excluded_bytes
    }

    /// The node for `path` (`None` is the root), or `None` if the listing
    /// had no such folder.
    pub fn folder_at(&self, path: Option<&RelPath>) -> Option<&FilterPreviewFolder> {
        let Some(path) = path else {
            return Some(&self.root);
        };
        let mut folder = &self.root;
        for segment in path.segments() {
            folder = folder
                .folders
                .iter()
                .find(|child| child.name() == segment)?;
        }
        Some(folder)
    }
}

impl FilterPreviewFolder {
    /// The folder's own name; empty for the root.
    pub fn name(&self) -> &str {
        self.path.as_ref().map_or("", RelPath::name)
    }
}

/// Counts `listing` (a whole tree, excluded folders included) under
/// `rules`. A folder appears as a node when it was listed, or when any
/// entry lies beneath it.
pub fn preview_filters(
    listing: &[ListedEntry],
    unreadable_folders: Vec<RelPath>,
    rules: &RuleSet,
) -> FilterPreviewReport {
    let mut excluded_by_rule: Vec<(Glob, u64)> = Vec::new();
    for rule in rules.ignore() {
        if !excluded_by_rule.iter().any(|(seen, _)| seen == rule) {
            excluded_by_rule.push((rule.clone(), 0));
        }
    }

    // Totals per folder, keyed by path ("" is the root).
    let mut folders: BTreeMap<String, Totals> = BTreeMap::new();
    folders.insert(String::new(), Totals::default());
    for entry in listing {
        for ancestor in ancestors(&entry.path) {
            folders.entry(ancestor.to_owned()).or_default();
        }
        match entry.kind {
            EntryKind::Folder => {
                folders.entry(entry.path.as_str().to_owned()).or_default();
            }
            EntryKind::Other => {}
            EntryKind::File { size } => {
                let rule = rules.ignore_rule_for(&entry.path);
                if let Some(rule) = rule
                    && let Some((_, count)) = excluded_by_rule.iter_mut().find(|(g, _)| g == rule)
                {
                    *count += 1;
                }
                for ancestor in std::iter::once("").chain(ancestors(&entry.path)) {
                    let totals = folders.entry(ancestor.to_owned()).or_default();
                    totals.add(size, rule.is_some());
                }
            }
        }
    }

    // Every key but the root is a prefix of a listed path, so it parses.
    let mut children: BTreeMap<&str, Vec<RelPath>> = BTreeMap::new();
    for key in folders.keys().filter(|key| !key.is_empty()) {
        if let Ok(folder) = RelPath::parse(key) {
            let parent = key.rsplit_once('/').map_or("", |(parent, _)| parent);
            children.entry(parent).or_default().push(folder);
        }
    }

    FilterPreviewReport {
        root: build(None, &folders, &children, rules),
        excluded_by_rule,
        unreadable_folders,
    }
}

/// The rows of one folder's listing, folders first, then files and the
/// rest, each by case-insensitive name.
pub fn filter_folder_rows(listing: Vec<ListedEntry>, rules: &RuleSet) -> Vec<FilterFolderRow> {
    let mut rows: Vec<FilterFolderRow> = listing
        .into_iter()
        .map(|entry| FilterFolderRow {
            excluded_by: match entry.kind {
                EntryKind::Other => None,
                EntryKind::File { .. } | EntryKind::Folder => {
                    rules.ignore_rule_for(&entry.path).cloned()
                }
            },
            path: entry.path,
            kind: entry.kind,
        })
        .collect();
    rows.sort_by_cached_key(|row| (row.kind != EntryKind::Folder, row.name().to_lowercase()));
    rows
}

#[derive(Clone, Copy, Default)]
struct Totals {
    included_files: u64,
    included_bytes: u64,
    excluded_files: u64,
    excluded_bytes: u64,
}

impl Totals {
    fn add(&mut self, size: u64, excluded: bool) {
        if excluded {
            self.excluded_files += 1;
            self.excluded_bytes += size;
        } else {
            self.included_files += 1;
            self.included_bytes += size;
        }
    }
}

/// Strict ancestors of `path`, shallowest first.
fn ancestors(path: &RelPath) -> impl Iterator<Item = &str> {
    let text = path.as_str();
    text.match_indices('/').map(move |(end, _)| &text[..end])
}

/// Assembles the node for `path` from the per-folder totals and the
/// parent-to-children index.
fn build(
    path: Option<RelPath>,
    totals: &BTreeMap<String, Totals>,
    children: &BTreeMap<&str, Vec<RelPath>>,
    rules: &RuleSet,
) -> FilterPreviewFolder {
    let key = path.as_ref().map_or("", RelPath::as_str);
    let own = totals.get(key).copied().unwrap_or_default();
    let mut subfolders = children.get(key).cloned().unwrap_or_default();
    subfolders.sort_by_cached_key(|child| child.name().to_lowercase());
    FilterPreviewFolder {
        excluded_by: path
            .as_ref()
            .and_then(|p| rules.ignore_rule_for(p))
            .cloned(),
        included_files: own.included_files,
        included_bytes: own.included_bytes,
        excluded_files: own.excluded_files,
        excluded_bytes: own.excluded_bytes,
        folders: subfolders
            .into_iter()
            .map(|child| build(Some(child), totals, children, rules))
            .collect(),
        path,
    }
}

#[cfg(test)]
mod tests {
    //! Every case of `test/dsync_core/scan/filter_preview_test.dart` that is
    //! about counting; listing a real directory (a root that cannot be
    //! listed, a folder that is not there) is the core's.

    use super::*;

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap_or_else(|e| panic!("{e}"))
    }

    fn file(p: &str, size: u64) -> ListedEntry {
        ListedEntry {
            path: path(p),
            kind: EntryKind::File { size },
        }
    }

    fn folder(p: &str) -> ListedEntry {
        ListedEntry {
            path: path(p),
            kind: EntryKind::Folder,
        }
    }

    fn other(p: &str) -> ListedEntry {
        ListedEntry {
            path: path(p),
            kind: EntryKind::Other,
        }
    }

    /// The Dart fixture: 6 files, 107 bytes.
    fn tree() -> Vec<ListedEntry> {
        vec![
            file("notes.txt", 12),
            file("photo.jpg", 40),
            folder("cache"),
            file("cache/a.tmp", 10),
            file("cache/b.tmp", 10),
            folder("DCIM"),
            file("DCIM/one.jpg", 30),
            folder("DCIM/.thumbnails"),
            file("DCIM/.thumbnails/t", 5),
        ]
    }

    fn rules(ignore: &[&str]) -> RuleSet {
        RuleSet::new(
            ignore.iter().map(|p| Glob::new(p).unwrap()).collect(),
            vec![],
        )
    }

    fn preview(ignore: &[&str]) -> FilterPreviewReport {
        preview_filters(&tree(), vec![], &rules(ignore))
    }

    fn counts(report: &FilterPreviewReport) -> Vec<(&str, u64)> {
        report
            .excluded_by_rule
            .iter()
            .map(|(glob, count)| (glob.as_str(), *count))
            .collect()
    }

    #[test]
    fn with_no_rules_everything_is_in_the_sync() {
        let report = preview(&[]);
        assert_eq!(report.included_files(), 6);
        assert_eq!(report.included_bytes(), 107);
        assert_eq!(report.excluded_files(), 0);
        assert_eq!(report.excluded_bytes(), 0);
    }

    #[test]
    fn a_rule_moves_files_from_one_total_to_the_other() {
        let report = preview(&["**/*.tmp"]);
        assert_eq!(report.included_files(), 4);
        assert_eq!(report.included_bytes(), 87);
        assert_eq!(report.excluded_files(), 2);
        assert_eq!(report.excluded_bytes(), 20);
    }

    #[test]
    fn an_excluded_folder_is_counted_not_pruned() {
        let report = preview(&["**/.thumbnails"]);
        assert_eq!(report.excluded_files(), 1);
        assert_eq!(report.excluded_bytes(), 5);
        assert_eq!(counts(&report), [("**/.thumbnails", 1)]);
    }

    #[test]
    fn every_rule_is_counted_and_one_that_matches_nothing_says_0() {
        let report = preview(&["**/*.tmp", "**/*.raw"]);
        assert_eq!(counts(&report), [("**/*.tmp", 2), ("**/*.raw", 0)]);
    }

    #[test]
    fn a_file_excluded_twice_is_counted_against_one_rule_only() {
        let report = preview(&["cache", "**/*.tmp"]);
        assert_eq!(report.excluded_files(), 2);
        assert_eq!(counts(&report), [("cache", 2), ("**/*.tmp", 0)]);
    }

    #[test]
    fn a_folder_node_carries_its_whole_subtree_and_why_it_is_out() {
        let report = preview(&["DCIM/.thumbnails"]);
        let dcim = report.folder_at(Some(&path("DCIM"))).unwrap();
        assert_eq!(dcim.included_files, 1);
        assert_eq!(dcim.excluded_files, 1);
        assert_eq!(dcim.excluded_by, None);
        let thumbnails = report.folder_at(Some(&path("DCIM/.thumbnails"))).unwrap();
        assert_eq!(
            thumbnails.excluded_by.as_ref().map(Glob::as_str),
            Some("DCIM/.thumbnails")
        );
        assert_eq!(report.folder_at(None).map(|f| f.included_files), Some(5));
    }

    #[test]
    fn a_folder_the_listing_never_saw_has_no_node() {
        assert_eq!(preview(&[]).folder_at(Some(&path("nope"))), None);
    }

    #[test]
    fn folders_are_ordered_by_case_insensitive_name() {
        let names: Vec<_> = preview(&[])
            .root
            .folders
            .iter()
            .map(|f| f.name().to_owned())
            .collect();
        assert_eq!(names, ["cache", "DCIM"]);
    }

    #[test]
    fn an_empty_folder_still_has_a_node() {
        let report = preview_filters(&[folder("empty")], vec![], &RuleSet::default());
        assert_eq!(
            report
                .folder_at(Some(&path("empty")))
                .map(|f| f.included_files),
            Some(0)
        );
    }

    #[test]
    fn a_symlink_is_in_neither_total() {
        let mut listing = tree();
        listing.push(other("link.jpg"));
        let report = preview_filters(&listing, vec![], &RuleSet::default());
        assert_eq!(report.included_files(), 6);
        assert_eq!(report.included_bytes(), 107);
    }

    #[test]
    fn unreadable_folders_are_reported_as_given() {
        let report = preview_filters(&tree(), vec![path("locked")], &RuleSet::default());
        assert_eq!(report.unreadable_folders, [path("locked")]);
        assert_eq!(report.folder_at(Some(&path("locked"))), None);
    }

    // -- one folder's rows --

    fn root_listing() -> Vec<ListedEntry> {
        vec![
            file("notes.txt", 12),
            folder("DCIM"),
            file("photo.jpg", 40),
            folder("cache"),
        ]
    }

    #[test]
    fn rows_are_folders_first_then_files_each_by_name() {
        let rows = filter_folder_rows(root_listing(), &RuleSet::default());
        let names: Vec<_> = rows.iter().map(FilterFolderRow::name).collect();
        assert_eq!(names, ["cache", "DCIM", "notes.txt", "photo.jpg"]);
    }

    #[test]
    fn a_row_carries_its_size_and_the_rule_that_excludes_it() {
        let rows = filter_folder_rows(
            vec![file("cache/b.tmp", 10), file("cache/a.tmp", 10)],
            &rules(&["**/*.tmp"]),
        );
        let names: Vec<_> = rows.iter().map(FilterFolderRow::name).collect();
        assert_eq!(names, ["a.tmp", "b.tmp"]);
        assert_eq!(rows[0].kind, EntryKind::File { size: 10 });
        assert_eq!(
            rows[0].excluded_by.as_ref().map(Glob::as_str),
            Some("**/*.tmp")
        );
        assert!(!rows[0].syncs());
    }

    #[test]
    fn rows_under_an_excluded_folder_name_the_folder_rule() {
        let rows = filter_folder_rows(
            vec![file("cache/a.tmp", 10), file("cache/b.tmp", 10)],
            &rules(&["cache", "**/*.tmp"]),
        );
        let rules: Vec<_> = rows
            .iter()
            .map(|r| r.excluded_by.as_ref().map(Glob::as_str))
            .collect();
        assert_eq!(rules, [Some("cache"), Some("cache")]);
        assert!(rows.iter().all(|r| !r.syncs()));
    }

    #[test]
    fn a_symlink_row_is_listed_and_carried_by_nothing() {
        let rows = filter_folder_rows(
            vec![other("link.jpg"), file("photo.jpg", 40)],
            &rules(&["**"]),
        );
        let link = rows.iter().find(|r| r.name() == "link.jpg").unwrap();
        assert_eq!(link.kind, EntryKind::Other);
        assert_eq!(link.excluded_by, None);
        assert!(!link.syncs());
        // Control: a plain file with no rule does sync.
        let plain = filter_folder_rows(vec![file("photo.jpg", 40)], &RuleSet::default());
        assert!(plain[0].syncs());
    }
}
