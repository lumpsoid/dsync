//! SPEC §10's delete guard: whether the actions a run is about to apply
//! delete so much of one side that a person has to say "proceed" first.

use crate::action::Action;
use crate::rel_path::RelPath;
use crate::side::Side;

/// When deletions need an explicit confirmation before the apply. A side
/// trips it when the run deletes at least `min_files` files
/// there *and* more than `percent` of the files
/// that side's archive holds (Unison's `confirmbigdeletes` is the
/// precedent). Both halves are needed: the count alone would stop every
/// tidy-up of a big folder, and the share alone every delete of two files
/// out of three.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct MassDeletePolicy {
    min_files: usize,
    percent: usize,
}

/// Thresholds no guard can use: fewer than one file, or a percent outside
/// 1 to 100 (0 would trip on any `min_files` deletes, over 100 never).
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error(
    "the mass-delete guard needs at least 1 file and a percent of 1 to 100, \
     got {min_files} file(s) and {percent}%"
)]
pub struct MassDeletePolicyError {
    min_files: u64,
    percent: u64,
}

impl MassDeletePolicy {
    /// Ten files, and over half of the side.
    pub const DEFAULT: MassDeletePolicy = MassDeletePolicy {
        min_files: 10,
        percent: 50,
    };

    /// A guard tripping at `min_files` deletes on a side (at least 1) and
    /// more than `percent` (1 to 100) of that side's archived files.
    pub fn new(min_files: u64, percent: u64) -> Result<MassDeletePolicy, MassDeletePolicyError> {
        let error = MassDeletePolicyError { min_files, percent };
        if min_files == 0 || !(1..=100).contains(&percent) {
            return Err(error);
        }
        Ok(MassDeletePolicy {
            min_files: usize::try_from(min_files).map_err(|_| error)?,
            percent: usize::try_from(percent).map_err(|_| error)?,
        })
    }

    /// Paths of each tripped side carried for a head to show.
    pub const SAMPLE_PATHS: usize = 5;

    /// The verdict on `kept`, the actions about to be applied, given how
    /// many files each side's archive holds (`archived`, A then B). `None`
    /// when no side trips.
    pub fn judge(&self, kept: &[Action], archived: [usize; 2]) -> Option<MassDelete> {
        let sides: Vec<SideDeletes> = Side::BOTH
            .into_iter()
            .zip(archived)
            .filter_map(|(side, archived)| {
                let paths: Vec<&RelPath> = kept
                    .iter()
                    .filter_map(|action| match action {
                        Action::Delete { path, on } if *on == side => Some(path),
                        _ => None,
                    })
                    .collect();
                self.trips(paths.len(), archived).then(|| SideDeletes {
                    side,
                    deletes: paths.len(),
                    archived,
                    sample: paths
                        .into_iter()
                        .take(Self::SAMPLE_PATHS)
                        .cloned()
                        .collect(),
                })
            })
            .collect();
        (!sides.is_empty()).then_some(MassDelete { sides })
    }

    fn trips(&self, deletes: usize, archived: usize) -> bool {
        deletes >= self.min_files
            && deletes.saturating_mul(100) > archived.saturating_mul(self.percent)
    }
}

/// A run's deletions that tripped [`MassDeletePolicy`]: one entry per side
/// that did, A first, never empty.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct MassDelete {
    sides: Vec<SideDeletes>,
}

/// One side's share of a [`MassDelete`]: how many files the run deletes
/// there, out of how many its archive holds, and the first few paths.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SideDeletes {
    pub side: Side,
    pub deletes: usize,
    pub archived: usize,
    pub sample: Vec<RelPath>,
}

impl MassDelete {
    pub fn sides(&self) -> &[SideDeletes] {
        &self.sides
    }

    /// The side's entry, if that side tripped.
    pub fn side(&self, side: Side) -> Option<&SideDeletes> {
        self.sides.iter().find(|deletes| deletes.side == side)
    }

    /// Whether a person who confirmed `confirmed` has already said yes to
    /// this: every side tripped here tripped there too, with at least as
    /// many deletes. A side newly tripped, or a count that rose, is news.
    pub fn within(&self, confirmed: &MassDelete) -> bool {
        self.sides.iter().all(|now| {
            confirmed
                .side(now.side)
                .is_some_and(|then| now.deletes <= then.deletes)
        })
    }

    /// The refusal, as the run reports it when the deletions were not
    /// confirmed.
    pub fn describe(&self) -> String {
        let counts: Vec<String> = self
            .sides
            .iter()
            .map(|deletes| {
                format!(
                    "{} of the {} files replica {} last synced",
                    deletes.deletes,
                    deletes.archived,
                    deletes.side.key().to_uppercase()
                )
            })
            .collect();
        format!(
            "not applied: this run would delete {}, and that was not confirmed (SPEC §10). \
             Nothing was changed.",
            counts.join(" and ")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap_or_else(|error| panic!("{error}"))
    }

    fn deletes(on: Side, count: usize) -> Vec<Action> {
        (0..count)
            .map(|index| Action::Delete {
                path: path(&format!("f{index:02}")),
                on,
            })
            .collect()
    }

    fn judge(kept: &[Action], archived: [usize; 2]) -> Option<MassDelete> {
        MassDeletePolicy::DEFAULT.judge(kept, archived)
    }

    #[test]
    fn ten_deletes_over_half_of_the_side_trip_it() {
        let verdict = judge(&deletes(Side::B, 10), [0, 19]);
        let Some(verdict) = verdict else {
            panic!("10 of 19 is over half");
        };
        assert_eq!(verdict.sides().len(), 1);
        let b = verdict.side(Side::B).unwrap_or_else(|| panic!("B tripped"));
        assert_eq!((b.deletes, b.archived), (10, 19));
        assert_eq!(b.sample.len(), MassDeletePolicy::SAMPLE_PATHS);
        assert_eq!(b.sample[0], path("f00"));
        assert!(verdict.side(Side::A).is_none());
    }

    #[test]
    fn exactly_half_does_not_trip() {
        assert_eq!(judge(&deletes(Side::B, 10), [0, 20]), None);
        assert!(judge(&deletes(Side::B, 11), [0, 21]).is_some());
    }

    #[test]
    fn fewer_than_ten_never_trip_even_a_whole_side() {
        assert_eq!(judge(&deletes(Side::A, 9), [9, 0]), None);
        assert!(judge(&deletes(Side::A, 10), [10, 0]).is_some());
    }

    #[test]
    fn many_deletes_in_a_big_side_do_not_trip() {
        assert_eq!(judge(&deletes(Side::A, 400), [1000, 1000]), None);
    }

    #[test]
    fn each_side_is_judged_against_its_own_archive() {
        let mut kept = deletes(Side::A, 12);
        kept.extend(deletes(Side::B, 12));
        let verdict = judge(&kept, [100, 12]).unwrap_or_else(|| panic!("B tripped"));
        assert_eq!(
            verdict.sides().iter().map(|s| s.side).collect::<Vec<_>>(),
            [Side::B]
        );
        let both = judge(&kept, [12, 12]).unwrap_or_else(|| panic!("both tripped"));
        assert_eq!(
            both.sides().iter().map(|s| s.side).collect::<Vec<_>>(),
            [Side::A, Side::B]
        );
    }

    #[test]
    fn a_verdict_is_within_a_confirmed_one_until_a_side_rises_or_appears() {
        let tripped = |a: usize, b: usize| {
            let mut kept = deletes(Side::A, a);
            kept.extend(deletes(Side::B, b));
            judge(&kept, [20, 20]).unwrap_or_else(|| panic!("tripped"))
        };
        let confirmed = tripped(0, 15);
        assert!(tripped(0, 15).within(&confirmed));
        assert!(tripped(0, 11).within(&confirmed));
        assert!(!tripped(0, 16).within(&confirmed));
        assert!(!tripped(11, 15).within(&confirmed));
        assert!(tripped(0, 12).within(&tripped(11, 15)));
    }

    #[test]
    fn only_deletions_count() {
        let mut kept = deletes(Side::B, 9);
        kept.push(Action::Copy {
            path: path("c"),
            from: Side::A,
            bytes: 1,
        });
        kept.push(Action::CommitOnly { path: path("d") });
        assert_eq!(judge(&kept, [0, 10]), None);
    }

    #[test]
    fn new_takes_at_least_one_file_and_a_percent_of_1_to_100() {
        assert_eq!(MassDeletePolicy::new(10, 50), Ok(MassDeletePolicy::DEFAULT));
        assert!(MassDeletePolicy::new(1, 1).is_ok());
        assert!(MassDeletePolicy::new(1, 100).is_ok());
        assert_eq!(
            MassDeletePolicy::new(0, 50),
            Err(MassDeletePolicyError {
                min_files: 0,
                percent: 50
            })
        );
        assert!(MassDeletePolicy::new(10, 0).is_err());
        assert!(MassDeletePolicy::new(10, 101).is_err());
    }

    #[test]
    fn a_lower_minimum_trips_where_the_default_would_not() {
        let three = MassDeletePolicy::new(3, 50).unwrap_or_else(|error| panic!("{error}"));
        assert!(three.judge(&deletes(Side::B, 3), [0, 4]).is_some());
        assert_eq!(judge(&deletes(Side::B, 3), [0, 4]), None);
    }

    #[test]
    fn a_higher_percent_needs_more_of_the_side() {
        let ninety = MassDeletePolicy::new(10, 90).unwrap_or_else(|error| panic!("{error}"));
        assert_eq!(ninety.judge(&deletes(Side::A, 18), [20, 0]), None);
        assert!(ninety.judge(&deletes(Side::A, 19), [20, 0]).is_some());
    }

    #[test]
    fn the_refusal_names_the_counts_per_side() {
        let verdict = judge(&deletes(Side::B, 10), [0, 12]).unwrap_or_else(|| panic!("tripped"));
        assert_eq!(
            verdict.describe(),
            "not applied: this run would delete 10 of the 12 files replica B last synced, \
             and that was not confirmed (SPEC §10). Nothing was changed."
        );
    }
}
