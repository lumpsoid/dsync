//! What a review row sets against what: two sides of one path, and whether
//! they are worth reading (SPEC §6).

use crate::action::Action;
use crate::conflict::Conflict;
use crate::peek_limits::PeekLimits;
use crate::proposal::Proposal;
use crate::rel_path::RelPath;
use crate::scan_entry::Status;
use crate::side::Side;

/// Extensions of files that are not text to read, lowercase: images, audio,
/// video, archives, packages and office documents. Judged by name alone;
/// sniffing content would need a read.
const MEDIA_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "dng", "raw", "cr2",
    "nef", "arw", "mp3", "flac", "wav", "ogg", "m4a", "aac", "opus", "mp4", "mov", "mkv", "avi",
    "webm", "m4v", "3gp", "zip", "7z", "rar", "gz", "xz", "zst", "tar", "apk", "pdf", "docx",
    "xlsx", "pptx", "odt",
];

/// One replica's file of a compared path; `size` is `None` when no file is
/// there.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Sided {
    pub side: Side,
    pub size: Option<u64>,
}

/// Two sides of one path to set against each other: `old` is what is there
/// now / what would be replaced, `new` what would arrive.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Comparison {
    pub path: RelPath,
    pub old: Sided,
    pub new: Sided,
}

/// What is known about a comparison before a byte is read.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Offer {
    Readable,
    Media,
    TooLarge { side: Side, size: u64 },
}

impl Comparison {
    /// What a copy does to its destination: the destination's file (the
    /// loser, whose size is `reverse_bytes`) is `old`, the source's `new`.
    /// Without a destination file the whole new file shows as added. A
    /// delete, a commit-only and a copy aside compare nothing.
    pub fn of_proposal(p: &Proposal) -> Option<Comparison> {
        match &p.action {
            Action::Copy { path, from, bytes } => Some(Comparison {
                path: path.clone(),
                old: Sided {
                    side: from.other(),
                    size: p.reverse_bytes,
                },
                new: Sided {
                    side: *from,
                    size: Some(*bytes),
                },
            }),
            Action::Delete { .. } | Action::CommitOnly { .. } | Action::CopyAside { .. } => None,
        }
    }

    /// A conflict's sides as the row names them: A (this device) is `old`,
    /// B (the remote) `new`. `None` when neither side holds a file.
    pub fn of_conflict(c: &Conflict) -> Option<Comparison> {
        let size = |side| c.on(side).and_then(Status::file).map(|f| f.meta.size);
        let (a, b) = (size(Side::A), size(Side::B));
        if a.is_none() && b.is_none() {
            return None;
        }
        Some(Comparison {
            path: c.path.clone(),
            old: Sided {
                side: Side::A,
                size: a,
            },
            new: Sided {
                side: Side::B,
                size: b,
            },
        })
    }

    /// Media by extension first, then a present side over the cap (`old`
    /// is reported before `new`); exactly the cap is readable, and an
    /// absent side never trips it.
    pub fn offer(&self, limits: &PeekLimits) -> Offer {
        if is_media(&self.path) {
            return Offer::Media;
        }
        [self.old, self.new]
            .into_iter()
            .find_map(|s| match s.size {
                Some(size) if size > limits.max_bytes => {
                    Some(Offer::TooLarge { side: s.side, size })
                }
                _ => None,
            })
            .unwrap_or(Offer::Readable)
    }
}

/// A name's extension is the text after its last dot; a leading dot alone
/// (`.png`) names a dotfile, not an extension.
fn is_media(path: &RelPath) -> bool {
    match path.name().rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => {
            MEDIA_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str())
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content_hash::ContentHash;
    use crate::root_kind::RootKind;
    use crate::scan_entry::{FileMeta, FileState};
    use std::time::Duration;

    const LIMITS: PeekLimits = PeekLimits {
        max_bytes: 100,
        diff_deadline: Duration::from_millis(1),
    };

    fn rel(s: &str) -> RelPath {
        RelPath::parse(s).unwrap_or_else(|e| panic!("{e}"))
    }

    fn file(size: u64) -> Status {
        Status::Created(FileState {
            meta: FileMeta {
                size,
                mtime_us: 1,
                mode: 0o644,
            },
            hash: ContentHash::from_digest([1; 32]),
        })
    }

    fn copy(from: Side, bytes: u64, reverse_bytes: Option<u64>) -> Proposal {
        Proposal {
            action: Action::Copy {
                path: rel("d/x.txt"),
                from,
                bytes,
            },
            reverse_bytes,
        }
    }

    fn conflict(a: Option<Status>, b: Option<Status>) -> Conflict {
        Conflict {
            path: rel("d/x.txt"),
            a,
            b,
            root_kind: RootKind::Folder,
        }
    }

    fn sized(path: &str, old: Option<u64>, new: Option<u64>) -> Comparison {
        Comparison {
            path: rel(path),
            old: Sided {
                side: Side::A,
                size: old,
            },
            new: Sided {
                side: Side::B,
                size: new,
            },
        }
    }

    #[test]
    fn a_copy_sets_the_source_against_the_destinations_file() {
        for from in Side::BOTH {
            let got = Comparison::of_proposal(&copy(from, 3, Some(7)));
            assert_eq!(
                got,
                Some(Comparison {
                    path: rel("d/x.txt"),
                    old: Sided {
                        side: from.other(),
                        size: Some(7)
                    },
                    new: Sided {
                        side: from,
                        size: Some(3)
                    },
                })
            );
        }
    }

    #[test]
    fn a_copy_onto_nothing_has_no_old_file() {
        let got = Comparison::of_proposal(&copy(Side::A, 3, None));
        assert_eq!(
            got.map(|c| (c.old, c.new)),
            Some((
                Sided {
                    side: Side::B,
                    size: None
                },
                Sided {
                    side: Side::A,
                    size: Some(3)
                }
            ))
        );
    }

    #[test]
    fn a_delete_and_a_commit_only_compare_nothing() {
        let delete = Proposal {
            action: Action::Delete {
                path: rel("x"),
                on: Side::A,
            },
            reverse_bytes: Some(5),
        };
        let commit = Proposal {
            action: Action::CommitOnly { path: rel("x") },
            reverse_bytes: None,
        };
        assert_eq!(Comparison::of_proposal(&delete), None);
        assert_eq!(Comparison::of_proposal(&commit), None);
    }

    #[test]
    fn a_conflict_sets_this_device_against_the_remote() {
        let both = Comparison::of_conflict(&conflict(Some(file(3)), Some(file(5))));
        assert_eq!(both, Some(sized("d/x.txt", Some(3), Some(5))));
        let only_a = Comparison::of_conflict(&conflict(Some(file(3)), Some(Status::Deleted)));
        assert_eq!(only_a, Some(sized("d/x.txt", Some(3), None)));
        let only_b = Comparison::of_conflict(&conflict(None, Some(file(5))));
        assert_eq!(only_b, Some(sized("d/x.txt", None, Some(5))));
        let neither = conflict(Some(Status::Deleted), None);
        assert_eq!(Comparison::of_conflict(&neither), None);
        assert_eq!(Comparison::of_conflict(&conflict(None, None)), None);
    }

    #[test]
    fn media_is_judged_by_a_case_insensitive_extension() {
        assert_eq!(
            sized("photo.JPG", Some(1), Some(1)).offer(&LIMITS),
            Offer::Media
        );
        assert_eq!(
            sized("a/b.tar.gz", Some(1), Some(1)).offer(&LIMITS),
            Offer::Media
        );
        // Media wins over the cap.
        assert_eq!(
            sized("a.mp4", Some(1000), Some(1)).offer(&LIMITS),
            Offer::Media
        );
    }

    #[test]
    fn text_without_a_media_extension_is_readable() {
        for name in [
            "notes.txt",
            "Makefile",
            ".png",
            "d/.png",
            "png",
            "a.png.txt",
        ] {
            assert_eq!(
                sized(name, Some(1), Some(1)).offer(&LIMITS),
                Offer::Readable,
                "{name}"
            );
        }
    }

    #[test]
    fn exactly_the_cap_is_readable_and_one_more_is_too_large() {
        assert_eq!(
            sized("a.txt", Some(100), Some(100)).offer(&LIMITS),
            Offer::Readable
        );
        assert_eq!(
            sized("a.txt", Some(101), Some(1)).offer(&LIMITS),
            Offer::TooLarge {
                side: Side::A,
                size: 101
            }
        );
        assert_eq!(
            sized("a.txt", Some(1), Some(101)).offer(&LIMITS),
            Offer::TooLarge {
                side: Side::B,
                size: 101
            }
        );
    }

    #[test]
    fn with_both_sides_over_the_cap_the_old_one_is_named() {
        assert_eq!(
            sized("a.txt", Some(200), Some(300)).offer(&LIMITS),
            Offer::TooLarge {
                side: Side::A,
                size: 200
            }
        );
    }

    #[test]
    fn an_absent_side_never_trips_the_cap() {
        let none = PeekLimits {
            max_bytes: 0,
            ..LIMITS
        };
        assert_eq!(sized("a.txt", None, Some(0)).offer(&none), Offer::Readable);
        assert_eq!(sized("a.txt", None, None).offer(&none), Offer::Readable);
        // Positive control: a present side over that cap does trip it.
        assert_eq!(
            sized("a.txt", None, Some(1)).offer(&none),
            Offer::TooLarge {
                side: Side::B,
                size: 1
            }
        );
    }
}
