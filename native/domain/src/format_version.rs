//! A format's version, `major.minor` (SPEC §8.4): the rule every stored
//! file, the pairing code and the replica protocol answer "can I read
//! this?" with.

use std::fmt;

/// One version of one format. A minor bump is additive: a reader of the
/// same major reads it, ignoring what it does not know, and a newer reader
/// reads older data. A major bump is breaking: a reader of another major
/// refuses it rather than misreading it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct FormatVersion {
    major: u32,
    minor: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0:?} is not a version; expected major.minor, like 1.0")]
pub struct FormatVersionError(String);

/// Two versions of one format whose majors differ: neither side can read
/// the other.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct MajorMismatch {
    ours: FormatVersion,
    theirs: FormatVersion,
}

impl FormatVersion {
    pub const fn new(major: u32, minor: u32) -> FormatVersion {
        FormatVersion { major, minor }
    }

    /// `major.minor`, both plain decimal digits.
    pub fn parse(text: &str) -> Result<FormatVersion, FormatVersionError> {
        let number = |part: &str| {
            (!part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
                .then(|| part.parse::<u32>().ok())
                .flatten()
        };
        text.split_once('.')
            .and_then(|(major, minor)| Some(FormatVersion::new(number(major)?, number(minor)?)))
            .ok_or_else(|| FormatVersionError(text.to_owned()))
    }

    pub fn major(self) -> u32 {
        self.major
    }

    pub fn minor(self) -> u32 {
        self.minor
    }

    /// What this side, at `self`, can use with data or a peer at `theirs`:
    /// the same major at the lower of the two minors, or a refusal when
    /// the majors differ.
    pub fn agree(self, theirs: FormatVersion) -> Result<FormatVersion, MajorMismatch> {
        if self.major != theirs.major {
            return Err(MajorMismatch { ours: self, theirs });
        }
        Ok(FormatVersion::new(self.major, self.minor.min(theirs.minor)))
    }

    /// Whether `theirs` is a later minor of this major: written by a newer
    /// build, so what this one does not recognize in it is an addition to
    /// ignore rather than a mistake to refuse.
    pub fn is_older_minor_of(self, theirs: FormatVersion) -> bool {
        self.major == theirs.major && self.minor < theirs.minor
    }
}

impl fmt::Display for FormatVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}", self.major, self.minor)
    }
}

impl MajorMismatch {
    pub fn ours(self) -> FormatVersion {
        self.ours
    }

    pub fn theirs(self) -> FormatVersion {
        self.theirs
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const V1_0: FormatVersion = FormatVersion::new(1, 0);

    #[test]
    fn parses_major_dot_minor_and_spells_it_back() {
        for text in ["1.0", "2.13", "0.0"] {
            assert_eq!(FormatVersion::parse(text).unwrap().to_string(), text);
        }
        for bad in [
            "1", "1.", ".0", "1.0.0", "v1.0", "+1.0", "1.-1", "a.b", "", "1 .0",
        ] {
            assert!(FormatVersion::parse(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn the_same_major_agrees_on_the_lower_minor() {
        assert_eq!(V1_0.agree(V1_0), Ok(V1_0));
        assert_eq!(V1_0.agree(FormatVersion::new(1, 4)), Ok(V1_0));
        assert_eq!(FormatVersion::new(1, 4).agree(V1_0), Ok(V1_0));
        assert_eq!(
            FormatVersion::new(1, 3).agree(FormatVersion::new(1, 7)),
            Ok(FormatVersion::new(1, 3))
        );
    }

    #[test]
    fn a_different_major_either_way_is_refused_naming_both() {
        for theirs in [FormatVersion::new(2, 0), FormatVersion::new(0, 9)] {
            let mismatch = V1_0.agree(theirs).unwrap_err();
            assert_eq!((mismatch.ours(), mismatch.theirs()), (V1_0, theirs));
        }
    }

    #[test]
    fn only_a_later_minor_of_the_same_major_is_newer() {
        assert!(V1_0.is_older_minor_of(FormatVersion::new(1, 1)));
        assert!(!V1_0.is_older_minor_of(V1_0));
        assert!(!FormatVersion::new(1, 2).is_older_minor_of(FormatVersion::new(1, 1)));
        assert!(!V1_0.is_older_minor_of(FormatVersion::new(2, 5)));
    }
}
