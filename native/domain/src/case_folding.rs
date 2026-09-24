//! Case-fold collisions (SPEC §16): two paths a folding filesystem cannot
//! tell apart.

use std::collections::HashMap;

use crate::rel_path::RelPath;
use crate::skipped_path::{SkippedPath, SkippedReason};

/// Whether the filesystem under a replica root folds case: a property of
/// the mounted filesystem, not the OS (a case-sensitive APFS volume, a
/// case-insensitive Linux mount). The core probes it once per replica and
/// passes it in as this value.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CaseFolding {
    /// Two spellings are two files; nothing collides.
    Distinct,
    /// `Notes.txt` and `notes.txt` are one file.
    Folds,
}

impl CaseFolding {
    /// Every path that folds onto another, at least one of each group live
    /// on disk, as skipped: the scan cannot say which spelling a plan should
    /// trust on a filesystem that holds only one file for them. A group of
    /// archived paths alone is left out - nothing will write to them, so no
    /// two writes can land on one file.
    ///
    /// In order of first appearance, `live` then `archived`.
    pub fn collisions(self, live: &[RelPath], archived: &[RelPath]) -> Vec<SkippedPath> {
        if self == CaseFolding::Distinct {
            return Vec::new();
        }
        let mut groups: Vec<(Vec<&RelPath>, bool)> = Vec::new();
        let mut by_key: HashMap<String, usize> = HashMap::new();
        let tagged = live
            .iter()
            .map(|path| (path, true))
            .chain(archived.iter().map(|path| (path, false)));
        for (path, is_live) in tagged {
            let slot = *by_key
                .entry(path.as_str().to_lowercase())
                .or_insert_with(|| {
                    groups.push((Vec::new(), false));
                    groups.len() - 1
                });
            let (members, any_live) = &mut groups[slot];
            if !members.contains(&path) {
                members.push(path);
            }
            *any_live |= is_live;
        }
        groups
            .into_iter()
            .filter(|(members, any_live)| *any_live && members.len() > 1)
            .flat_map(|(members, _)| {
                members
                    .iter()
                    .map(|path| {
                        SkippedPath::new(
                            (*path).clone(),
                            SkippedReason::CaseFoldCollision,
                            detail(path, &members),
                        )
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
    }
}

/// Names the other spellings, so the reader knows what to look at.
fn detail(path: &RelPath, group: &[&RelPath]) -> String {
    let mut others: Vec<&str> = group
        .iter()
        .filter(|other| **other != path)
        .map(|other| other.as_str())
        .collect();
    others.sort_unstable();
    let quoted: Vec<String> = others.iter().map(|o| format!("\"{o}\"")).collect();
    format!("folds to the same path as {}", quoted.join(", "))
}

#[cfg(test)]
mod tests {
    //! The pure half of `scanner_test.dart`'s case-folding group; the
    //! scanner's own tests run the same cases on disk.

    use super::*;

    fn paths(texts: &[&str]) -> Vec<RelPath> {
        texts.iter().map(|t| RelPath::parse(t).unwrap()).collect()
    }

    fn reported(skipped: &[SkippedPath]) -> Vec<&str> {
        skipped.iter().map(|s| s.path().unwrap().as_str()).collect()
    }

    #[test]
    fn two_live_spellings_are_both_reported() {
        let skipped = CaseFolding::Folds.collisions(&paths(&["notes.txt", "Notes.txt"]), &[]);
        assert_eq!(reported(&skipped), ["notes.txt", "Notes.txt"]);
        assert!(
            skipped
                .iter()
                .all(|s| s.reason == SkippedReason::CaseFoldCollision)
        );
        assert_eq!(skipped[0].detail, "folds to the same path as \"Notes.txt\"");
        assert_eq!(skipped[1].detail, "folds to the same path as \"notes.txt\"");
    }

    #[test]
    fn a_distinct_filesystem_reports_nothing() {
        let live = paths(&["notes.txt", "Notes.txt"]);
        assert!(CaseFolding::Distinct.collisions(&live, &[]).is_empty());
    }

    #[test]
    fn a_live_path_and_an_archived_one_collide() {
        let skipped = CaseFolding::Folds.collisions(&paths(&["notes.txt"]), &paths(&["Notes.txt"]));
        assert_eq!(reported(&skipped), ["notes.txt", "Notes.txt"]);
    }

    #[test]
    fn archived_paths_alone_do_not_collide() {
        let archived = paths(&["notes.txt", "Notes.txt"]);
        assert!(CaseFolding::Folds.collisions(&[], &archived).is_empty());
    }

    #[test]
    fn a_group_of_three_is_reported_whole() {
        let skipped = CaseFolding::Folds.collisions(
            &paths(&["notes.txt", "Notes.txt", "other.txt"]),
            &paths(&["NOTES.txt"]),
        );
        assert_eq!(reported(&skipped), ["notes.txt", "Notes.txt", "NOTES.txt"]);
        assert_eq!(
            skipped[2].detail,
            "folds to the same path as \"Notes.txt\", \"notes.txt\""
        );
    }

    #[test]
    fn folding_applies_to_every_segment() {
        let skipped = CaseFolding::Folds.collisions(&paths(&["Dir/a", "dir/a"]), &[]);
        assert_eq!(reported(&skipped), ["Dir/a", "dir/a"]);
    }
}
