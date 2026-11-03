//! SPEC §10's overwrite guard: whether the actions a run is about to apply
//! overwrite so much of one side - or empty so many of its files - that a
//! person has to say "proceed" first. The delete guard's sibling
//! ([`crate::MassDeletePolicy`]): ransomware encrypting a folder, or a tool
//! truncating its files, looks to the scan like the user editing them all,
//! and the run would faithfully copy the damage over the other side.

use std::collections::HashMap;

use crate::action::Action;
use crate::rel_path::RelPath;
use crate::scan_entry::ScanEntry;
use crate::side::Side;

/// When overwrites need an explicit confirmation before the apply. A side
/// trips it either way:
///
/// - the run overwrites at least `min_files` files there *and* more than
///   `percent` of the files that side's archive holds - the delete guard's
///   two halves, for the same reasons;
/// - the run empties at least `min_truncated` of its files: copies a
///   0-byte file over one that is not. No share is asked here: a few
///   emptied files at once is rare enough on its own, and a share would
///   let hundreds through in a big folder. One emptied file - a cleared
///   log - is routine, hence a count above one.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct MassOverwritePolicy {
    min_files: usize,
    percent: usize,
    min_truncated: usize,
}

impl MassOverwritePolicy {
    /// Ten files and over half of the side, or five files emptied.
    pub const DEFAULT: MassOverwritePolicy = MassOverwritePolicy {
        min_files: 10,
        percent: 50,
        min_truncated: 5,
    };

    /// Paths of each tripped side carried for a head to show.
    pub const SAMPLE_PATHS: usize = 5;

    /// The verdict on `kept`, the actions about to be applied, given each
    /// side's scanned entries (`entries`, A then B: what is on disk at a
    /// path a copy writes) and how many files each side's archive holds
    /// (`archived`). A copy overwrites when its target side's entry at that
    /// path is present; a copy aside writes a new name and overwrites
    /// nothing. `None` when no side trips.
    pub fn judge(
        &self,
        kept: &[Action],
        entries: [&[ScanEntry]; 2],
        archived: [usize; 2],
    ) -> Option<MassOverwrite> {
        let sides: Vec<SideOverwrites> = Side::BOTH
            .into_iter()
            .zip(entries)
            .zip(archived)
            .filter_map(|((side, entries), archived)| {
                self.judge_side(kept, side, entries, archived)
            })
            .collect();
        (!sides.is_empty()).then_some(MassOverwrite { sides })
    }

    fn judge_side(
        &self,
        kept: &[Action],
        side: Side,
        entries: &[ScanEntry],
        archived: usize,
    ) -> Option<SideOverwrites> {
        let on_disk: HashMap<&RelPath, u64> = entries
            .iter()
            .filter_map(|entry| Some((&entry.path, entry.status.file()?.meta.size)))
            .collect();
        let mut truncated = Vec::new();
        let mut rest = Vec::new();
        for action in kept {
            let Action::Copy { path, from, bytes } = action else {
                continue;
            };
            if from.other() != side {
                continue;
            }
            let Some(&size) = on_disk.get(path) else {
                continue;
            };
            if *bytes == 0 && size > 0 {
                truncated.push(path);
            } else {
                rest.push(path);
            }
        }
        let overwrites = truncated.len() + rest.len();
        let trips = (overwrites >= self.min_files
            && overwrites.saturating_mul(100) > archived.saturating_mul(self.percent))
            || truncated.len() >= self.min_truncated;
        trips.then(|| SideOverwrites {
            side,
            overwrites,
            truncated: truncated.len(),
            archived,
            sample: truncated
                .into_iter()
                .chain(rest)
                .take(Self::SAMPLE_PATHS)
                .cloned()
                .collect(),
        })
    }
}

/// A run's overwrites that tripped [`MassOverwritePolicy`]: one entry per
/// side that did, A first, never empty.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct MassOverwrite {
    sides: Vec<SideOverwrites>,
}

/// One side's share of a [`MassOverwrite`]: how many files the run
/// overwrites there, how many of those it empties, out of how many its
/// archive holds, and the first few paths - emptied ones first.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SideOverwrites {
    pub side: Side,
    pub overwrites: usize,
    /// Of `overwrites`, those a 0-byte file replaces a non-empty one.
    pub truncated: usize,
    pub archived: usize,
    pub sample: Vec<RelPath>,
}

impl MassOverwrite {
    pub fn sides(&self) -> &[SideOverwrites] {
        &self.sides
    }

    /// The side's entry, if that side tripped.
    pub fn side(&self, side: Side) -> Option<&SideOverwrites> {
        self.sides.iter().find(|overwrites| overwrites.side == side)
    }

    /// Whether a person who confirmed `confirmed` has already said yes to
    /// this: every side tripped here tripped there too, with at least as
    /// many overwrites and as many emptied. A side newly tripped, or a
    /// count that rose, is news.
    pub fn within(&self, confirmed: &MassOverwrite) -> bool {
        self.sides.iter().all(|now| {
            confirmed.side(now.side).is_some_and(|then| {
                now.overwrites <= then.overwrites && now.truncated <= then.truncated
            })
        })
    }

    /// The refusal, as the run reports it when the overwrites were not
    /// confirmed.
    pub fn describe(&self) -> String {
        let counts: Vec<String> = self
            .sides
            .iter()
            .map(|overwrites| {
                format!(
                    "{} of the {} files replica {} last synced ({} of them emptied to 0 bytes)",
                    overwrites.overwrites,
                    overwrites.archived,
                    overwrites.side.key().to_uppercase(),
                    overwrites.truncated
                )
            })
            .collect();
        format!(
            "not applied: this run would overwrite {}, and that was not confirmed (SPEC §10). \
             Nothing was changed.",
            counts.join(" and ")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content_hash::ContentHash;
    use crate::scan_entry::{FileMeta, FileState, Status, Unchanged};

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap_or_else(|error| panic!("{error}"))
    }

    fn name(index: usize) -> String {
        format!("f{index:02}")
    }

    /// `count` files of `size` bytes, unchanged on their side.
    fn on_disk(count: usize, size: u64) -> Vec<ScanEntry> {
        (0..count)
            .map(|index| {
                let file = FileState {
                    meta: FileMeta {
                        size,
                        mtime_us: 0,
                        mode: 0o644,
                        read_us: 0,
                    },
                    hash: ContentHash::from_digest([1; 32]),
                };
                ScanEntry::new(
                    path(&name(index)),
                    Status::Unchanged {
                        file,
                        by: Unchanged::MetadataMatched,
                    },
                )
            })
            .collect()
    }

    /// `count` copies from `from`, each `bytes` long, onto `f00`...
    fn copies(from: Side, count: usize, bytes: u64) -> Vec<Action> {
        (0..count)
            .map(|index| Action::Copy {
                path: path(&name(index)),
                from,
                bytes,
            })
            .collect()
    }

    /// The default's verdict on `kept` against B holding `b` (A empty).
    fn judge_b(kept: &[Action], b: &[ScanEntry], archived_b: usize) -> Option<MassOverwrite> {
        MassOverwritePolicy::DEFAULT.judge(kept, [&[], b], [0, archived_b])
    }

    #[test]
    fn ten_overwrites_over_half_of_the_side_trip_it() {
        let b = on_disk(19, 100);
        let verdict = judge_b(&copies(Side::A, 10, 100), &b, 19);
        let Some(verdict) = verdict else {
            panic!("10 of 19 is over half");
        };
        let side = verdict.side(Side::B).unwrap_or_else(|| panic!("B tripped"));
        assert_eq!(
            (side.overwrites, side.truncated, side.archived),
            (10, 0, 19)
        );
        assert_eq!(side.sample.len(), MassOverwritePolicy::SAMPLE_PATHS);
        assert_eq!(side.sample[0], path("f00"));
        assert!(verdict.side(Side::A).is_none());
    }

    #[test]
    fn under_the_threshold_passes() {
        let b = on_disk(20, 100);
        assert_eq!(judge_b(&copies(Side::A, 10, 100), &b, 20), None);
        assert_eq!(judge_b(&copies(Side::A, 9, 100), &on_disk(9, 100), 9), None);
        let big = on_disk(1000, 100);
        assert_eq!(judge_b(&copies(Side::A, 400, 100), &big, 1000), None);
    }

    #[test]
    fn a_copy_onto_nothing_creates_and_is_not_counted() {
        assert_eq!(judge_b(&copies(Side::A, 12, 100), &[], 0), None);
        let deleted: Vec<ScanEntry> = (0..12)
            .map(|index| ScanEntry::new(path(&name(index)), Status::Deleted))
            .collect();
        assert_eq!(judge_b(&copies(Side::A, 12, 100), &deleted, 12), None);
    }

    #[test]
    fn only_copies_onto_the_side_count() {
        let b = on_disk(12, 100);
        let mut kept = copies(Side::B, 12, 100);
        kept.extend((0..12).map(|index| Action::CopyAside {
            path: path(&name(index)),
            from: Side::A,
            to: path(&format!("{}.conflict", name(index))),
            bytes: 0,
        }));
        kept.push(Action::Delete {
            path: path("f00"),
            on: Side::B,
        });
        assert_eq!(judge_b(&kept, &b, 12), None);
    }

    #[test]
    fn truncate_to_zero_is_counted_and_trips_on_its_own_count() {
        let b = on_disk(1000, 100);
        let verdict = judge_b(&copies(Side::A, 5, 0), &b, 1000)
            .unwrap_or_else(|| panic!("five emptied files trip it"));
        let side = verdict.side(Side::B).unwrap_or_else(|| panic!("B tripped"));
        assert_eq!((side.overwrites, side.truncated), (5, 5));
        assert_eq!(judge_b(&copies(Side::A, 4, 0), &b, 1000), None);
    }

    #[test]
    fn an_empty_file_copied_over_an_empty_one_is_not_a_truncation() {
        let b = on_disk(1000, 0);
        assert_eq!(judge_b(&copies(Side::A, 6, 0), &b, 1000), None);
    }

    #[test]
    fn emptied_paths_lead_the_sample() {
        let b = on_disk(12, 100);
        let mut kept = copies(Side::A, 11, 100);
        kept.push(Action::Copy {
            path: path("f11"),
            from: Side::A,
            bytes: 0,
        });
        let verdict = judge_b(&kept, &b, 12).unwrap_or_else(|| panic!("tripped"));
        let side = verdict.side(Side::B).unwrap_or_else(|| panic!("B tripped"));
        assert_eq!((side.overwrites, side.truncated), (12, 1));
        assert_eq!(side.sample[0], path("f11"));
    }

    #[test]
    fn each_side_is_judged_against_its_own_entries() {
        let disk = on_disk(12, 100);
        let mut kept = copies(Side::A, 12, 100);
        kept.extend(copies(Side::B, 12, 100));
        let only_b = MassOverwritePolicy::DEFAULT
            .judge(&kept, [&disk, &disk], [100, 12])
            .unwrap_or_else(|| panic!("B tripped"));
        assert_eq!(
            only_b.sides().iter().map(|s| s.side).collect::<Vec<_>>(),
            [Side::B]
        );
        let both = MassOverwritePolicy::DEFAULT
            .judge(&kept, [&disk, &disk], [12, 12])
            .unwrap_or_else(|| panic!("both tripped"));
        assert_eq!(
            both.sides().iter().map(|s| s.side).collect::<Vec<_>>(),
            [Side::A, Side::B]
        );
    }

    #[test]
    fn a_verdict_is_within_a_confirmed_one_until_a_count_rises_or_a_side_appears() {
        let disk = on_disk(20, 100);
        let tripped = |a: usize, b: usize, emptied: usize| {
            let mut kept = copies(Side::B, a, 100);
            kept.extend(copies(Side::A, b, 100));
            kept.extend((0..emptied).map(|index| Action::Copy {
                path: path(&name(19 - index)),
                from: Side::A,
                bytes: 0,
            }));
            MassOverwritePolicy::DEFAULT
                .judge(&kept, [&disk, &disk], [20, 20])
                .unwrap_or_else(|| panic!("tripped"))
        };
        let confirmed = tripped(0, 15, 0);
        assert!(tripped(0, 15, 0).within(&confirmed));
        assert!(tripped(0, 11, 0).within(&confirmed));
        assert!(!tripped(0, 16, 0).within(&confirmed));
        assert!(!tripped(11, 15, 0).within(&confirmed));
        assert!(!tripped(0, 10, 1).within(&confirmed));
    }

    #[test]
    fn the_refusal_names_the_counts_per_side() {
        let b = on_disk(12, 100);
        let mut kept = copies(Side::A, 9, 100);
        kept.push(Action::Copy {
            path: path("f09"),
            from: Side::A,
            bytes: 0,
        });
        let verdict = judge_b(&kept, &b, 12).unwrap_or_else(|| panic!("tripped"));
        assert_eq!(
            verdict.describe(),
            "not applied: this run would overwrite 10 of the 12 files replica B last synced \
             (1 of them emptied to 0 bytes), and that was not confirmed (SPEC §10). \
             Nothing was changed."
        );
    }
}
