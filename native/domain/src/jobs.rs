//! The scan's thread count.

use std::fmt;

/// How many scan threads stat and hash in parallel (`[options] jobs`,
/// `--jobs`). At least 1 - zero threads never finish a scan - and at most
/// [`Jobs::MAX`]: past the core count more threads only contend for the
/// disk, and a typo like `jobs = 4000` should be an error, not 4000
/// threads.
#[derive(
    Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, serde::Serialize, serde::Deserialize,
)]
#[serde(try_from = "u16", into = "u16")]
pub struct Jobs(u16);

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("{0} is out of range; jobs must be 1 to {max}", max = Jobs::MAX)]
pub struct JobsError(i64);

impl Jobs {
    pub const MAX: u16 = 256;
    pub const DEFAULT: Jobs = Jobs(4);

    pub fn new(count: i64) -> Result<Jobs, JobsError> {
        u16::try_from(count)
            .ok()
            .filter(|n| (1..=Self::MAX).contains(n))
            .map(Jobs)
            .ok_or(JobsError(count))
    }

    pub fn get(self) -> usize {
        usize::from(self.0)
    }
}

impl TryFrom<u16> for Jobs {
    type Error = JobsError;

    fn try_from(count: u16) -> Result<Self, Self::Error> {
        Jobs::new(i64::from(count))
    }
}

impl From<Jobs> for u16 {
    fn from(jobs: Jobs) -> u16 {
        jobs.0
    }
}

impl fmt::Display for Jobs {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_one_through_max_and_refuses_the_rest() {
        for good in [1, 4, 256] {
            assert_eq!(Jobs::new(good).map(Jobs::get), Ok(good as usize));
        }
        for bad in [0, -1, 257, i64::MAX] {
            assert_eq!(Jobs::new(bad), Err(JobsError(bad)));
        }
    }
}
