//! What names a replica's filesystem can hold (SPEC §16): a plan's
//! creates are checked against the side they land on before either write
//! does.

use std::collections::HashSet;

use crate::case_folding::CaseFolding;
use crate::platform::Platform;
use crate::rel_path::RelPath;
use crate::scan_entry::ScanEntry;
use crate::skipped_path::{SkippedPath, SkippedReason};
use crate::unreadable_paths::UnreadablePaths;

/// A replica's filesystem as its names go: whether it folds case, probed
/// at scan time, and the platform it runs on, whose own rules refuse some
/// names outright. Each replica reports its own with its scan, so a far
/// end's rules are its own, not this host's.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct Naming {
    pub folding: CaseFolding,
    pub platform: Platform,
}

impl Naming {
    /// Every path the other side would create here that this filesystem
    /// cannot hold, as skipped on this side: a name Windows refuses, and
    /// every create in a group of two or more that fold to one name.
    /// `here` and `there` are the two sides' status lists; a create is a
    /// file `there` with no file `here`. A path `unreadable` covers is
    /// already left out of the plan, and is not reported again.
    ///
    /// The scan of a folding side catches spellings that are already on
    /// it; this catches two that are not yet, both of which would pass the
    /// write's "absent" check and land on one file.
    pub fn cannot_hold(
        self,
        here: &[ScanEntry],
        there: &[ScanEntry],
        unreadable: &UnreadablePaths,
    ) -> Vec<SkippedPath> {
        let files_here: HashSet<&RelPath> = here
            .iter()
            .filter(|entry| entry.status.is_present())
            .map(|entry| &entry.path)
            .collect();
        let creates = there
            .iter()
            .filter(|entry| entry.status.is_present())
            .map(|entry| &entry.path)
            .filter(|path| !unreadable.covers(path) && !files_here.contains(path));
        let mut skipped = Vec::new();
        let mut holdable = Vec::new();
        for path in creates {
            match self.refusal(path) {
                Some(detail) => skipped.push(SkippedPath::new(
                    path.clone(),
                    SkippedReason::UnrepresentableName,
                    detail,
                )),
                None => holdable.push(path.clone()),
            }
        }
        skipped.extend(self.folding.collisions(&holdable, &[]));
        skipped
    }

    /// Why this platform refuses `path`, naming the segment; `None` when it
    /// can hold it.
    fn refusal(self, path: &RelPath) -> Option<String> {
        match self.platform {
            Platform::Unix => None,
            Platform::Windows => path.segments().find_map(|segment| {
                windows_refusal(segment)
                    .map(|why| format!("Windows cannot hold the name \"{segment}\": {why}"))
            }),
        }
    }
}

/// Device names Windows reserves whatever the extension (`aux.txt` too).
const WINDOWS_RESERVED: [&str; 28] = [
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "COM¹", "COM²", "COM³", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8",
    "LPT9", "LPT¹", "LPT²", "LPT³",
];

/// Why Windows refuses one name, `None` when it holds it. `\` and `/` never
/// reach here: no [`RelPath`] segment holds either.
fn windows_refusal(segment: &str) -> Option<String> {
    if let Some(c) = segment.chars().find(|c| r#"<>:"|?*"#.contains(*c)) {
        return Some(format!("it contains \"{c}\""));
    }
    if segment.chars().any(char::is_control) {
        return Some("it contains a control character".to_owned());
    }
    if segment.ends_with(['.', ' ']) {
        return Some("it ends in a dot or a space".to_owned());
    }
    let stem = segment.split('.').next().unwrap_or(segment).trim_end();
    if WINDOWS_RESERVED
        .iter()
        .any(|reserved| reserved.eq_ignore_ascii_case(stem))
    {
        return Some(format!("\"{stem}\" is a device name"));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content_hash::ContentHash;
    use crate::scan_entry::{FileMeta, FileState, Status};

    const WINDOWS: Naming = Naming {
        folding: CaseFolding::Folds,
        platform: Platform::Windows,
    };
    const MAC: Naming = Naming {
        folding: CaseFolding::Folds,
        platform: Platform::Unix,
    };
    const LINUX: Naming = Naming {
        folding: CaseFolding::Distinct,
        platform: Platform::Unix,
    };

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap()
    }

    fn created(text: &str) -> ScanEntry {
        ScanEntry::new(
            path(text),
            Status::Created(FileState {
                meta: FileMeta {
                    size: 1,
                    mtime_us: 1,
                    mode: 0o644,
                    read_us: 0,
                },
                hash: ContentHash::from_digest([1; 32]),
            }),
        )
    }

    fn held(
        naming: Naming,
        here: &[ScanEntry],
        there: &[ScanEntry],
    ) -> Vec<(String, SkippedReason)> {
        naming
            .cannot_hold(here, there, &UnreadablePaths::default())
            .iter()
            .map(|s| (s.path().unwrap().to_string(), s.reason))
            .collect()
    }

    #[test]
    fn two_creates_differing_only_by_case_onto_a_folding_side_are_both_held() {
        let there = [created("a.txt"), created("A.txt"), created("b.txt")];
        assert_eq!(
            held(MAC, &[], &there),
            [
                ("a.txt".to_owned(), SkippedReason::CaseFoldCollision),
                ("A.txt".to_owned(), SkippedReason::CaseFoldCollision),
            ]
        );
    }

    #[test]
    fn two_unicode_forms_of_one_name_onto_a_folding_side_are_both_held() {
        let there = [created("caf\u{e9}.txt"), created("cafe\u{301}.txt")];
        assert_eq!(held(MAC, &[], &there).len(), 2);
    }

    #[test]
    fn a_distinct_side_holds_both_spellings() {
        let there = [created("a.txt"), created("A.txt")];
        assert!(held(LINUX, &[], &there).is_empty());
    }

    #[test]
    fn a_path_already_a_file_here_is_not_a_create() {
        let there = [created("a.txt"), created("A.txt")];
        assert!(held(MAC, &[created("a.txt")], &there).is_empty());
    }

    #[test]
    fn a_path_deleted_here_is_created_again() {
        let here = [ScanEntry::new(path("a.txt"), Status::Deleted)];
        let there = [created("a.txt"), created("A.txt")];
        assert_eq!(held(MAC, &here, &there).len(), 2);
    }

    #[test]
    fn a_path_already_skipped_is_not_reported_again() {
        let there = [created("a.txt"), created("A.txt")];
        let unreadable = UnreadablePaths::new([path("a.txt")]);
        assert!(MAC.cannot_hold(&[], &there, &unreadable).is_empty());
    }

    #[test]
    fn windows_refuses_its_names_and_only_windows_does() {
        let there = [
            created("log:old"),
            created("aux.txt"),
            created("CON"),
            created("com1.tar.gz"),
            created("dir./x"),
            created("trailing "),
            created("q?"),
            created("tab\there"),
            created("console.txt"),
            created("fine.txt"),
        ];
        let reported: Vec<String> = held(WINDOWS, &[], &there)
            .into_iter()
            .map(|(path, reason)| {
                assert_eq!(reason, SkippedReason::UnrepresentableName);
                path
            })
            .collect();
        assert_eq!(
            reported,
            [
                "log:old",
                "aux.txt",
                "CON",
                "com1.tar.gz",
                "dir./x",
                "trailing ",
                "q?",
                "tab\there"
            ]
        );
        assert!(held(MAC, &[], &there).is_empty());
    }

    #[test]
    fn the_detail_names_the_segment_and_why() {
        let skipped = WINDOWS.cannot_hold(
            &[],
            &[created("aux/notes.txt")],
            &UnreadablePaths::default(),
        );
        assert_eq!(
            skipped[0].detail,
            "Windows cannot hold the name \"aux\": \"aux\" is a device name"
        );
    }

    #[test]
    fn a_name_windows_refuses_does_not_also_count_toward_a_collision() {
        let there = [created("ab:c"), created("AB:C"), created("x"), created("X")];
        let reasons: Vec<SkippedReason> = held(WINDOWS, &[], &there)
            .into_iter()
            .map(|(_, r)| r)
            .collect();
        assert_eq!(
            reasons,
            [
                SkippedReason::UnrepresentableName,
                SkippedReason::UnrepresentableName,
                SkippedReason::CaseFoldCollision,
                SkippedReason::CaseFoldCollision,
            ]
        );
    }
}
