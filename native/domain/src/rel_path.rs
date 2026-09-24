//! A path relative to a replica root, confined to it by construction.

use std::fmt;
use std::path::{Path, PathBuf};
use std::str::FromStr;

/// A replica-root-relative path as it travels on the wire and sits in the
/// archive: `/`-separated on every platform (SPEC §3), every segment a
/// plain name.
///
/// Parsing is the only way to get one, so a `RelPath` is joinable under a
/// root without a runtime escape check: it replaces Dart's
/// `resolveWithinRoot`. Refused, with the reason:
///
/// - empty, a leading `/` (absolute), a trailing `/` or `a//b` (an empty
///   segment has no name to stand for);
/// - a `.` or `..` segment (`..` escapes; `.` is a second spelling of the
///   same path, which would give one file two archive keys);
/// - `\` anywhere: on Windows it is a separator, so `a\..\b` would escape
///   after the join, and a unix file named `a\b` would land on Windows as a
///   directory `a`. Such a file cannot be represented portably, so it is
///   refused rather than silently reshaped;
/// - a segment starting with a drive (`C:` - an ASCII letter then `:`):
///   pushed onto a Windows path it replaces the root. Checked in every
///   segment, not only the first, because the join is per segment. A `:`
///   elsewhere (`log:old`) is an ordinary unix name and is kept;
/// - NUL, which no filesystem accepts in a name.
#[derive(
    Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Debug, serde::Serialize, serde::Deserialize,
)]
#[serde(try_from = "String", into = "String")]
pub struct RelPath(String);

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RelPathError {
    #[error("empty path")]
    Empty,
    #[error("{0:?} is absolute; a replica path is relative to its root")]
    Absolute(String),
    #[error("{0:?} has an empty segment")]
    EmptySegment(String),
    #[error("{0:?} has a \".\" or \"..\" segment")]
    DotSegment(String),
    #[error("{0:?} contains a backslash, which is a separator on Windows")]
    Backslash(String),
    #[error("{0:?} has a segment starting with a drive letter")]
    Drive(String),
    #[error("{0:?} contains a NUL byte")]
    Nul(String),
}

impl RelPath {
    pub fn parse(text: &str) -> Result<Self, RelPathError> {
        let owned = || text.to_owned();
        if text.is_empty() {
            return Err(RelPathError::Empty);
        }
        if text.starts_with('/') {
            return Err(RelPathError::Absolute(owned()));
        }
        if text.contains('\0') {
            return Err(RelPathError::Nul(owned()));
        }
        if text.contains('\\') {
            return Err(RelPathError::Backslash(owned()));
        }
        for segment in text.split('/') {
            if segment.is_empty() {
                return Err(RelPathError::EmptySegment(owned()));
            }
            if segment == "." || segment == ".." {
                return Err(RelPathError::DotSegment(owned()));
            }
            if starts_with_drive(segment) {
                return Err(RelPathError::Drive(owned()));
            }
        }
        Ok(RelPath(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The `/`-separated segments, root first.
    pub fn segments(&self) -> impl Iterator<Item = &str> {
        self.0.split('/')
    }

    /// The last segment: the file or directory's own name.
    pub fn name(&self) -> &str {
        self.0.rsplit_once('/').map_or(&self.0, |(_, name)| name)
    }

    /// The containing directory, or `None` for an entry at the root.
    pub fn parent(&self) -> Option<RelPath> {
        self.0
            .rsplit_once('/')
            .map(|(parent, _)| RelPath(parent.to_owned()))
    }

    /// This path and every ancestor, as `/`-joined prefixes, shallowest
    /// first: `a`, `a/b`, `a/b/c` for `a/b/c`. Borrowed, not allocated -
    /// rule matching runs this once per scanned path.
    pub fn prefixes(&self) -> impl Iterator<Item = &str> {
        let text = self.0.as_str();
        text.match_indices('/')
            .map(move |(end, _)| &text[..end])
            .chain(std::iter::once(text))
    }

    /// `self` is `other` or lies beneath it. `sub` does not contain
    /// `submarine.txt`: the separator is what makes it "beneath".
    pub fn is_within(&self, other: &RelPath) -> bool {
        self.0 == other.0
            || (self.0.starts_with(&other.0) && self.0.as_bytes().get(other.0.len()) == Some(&b'/'))
    }

    /// `self` beneath `name`, a single segment. Fails for anything
    /// [`RelPath::parse`] would refuse as a segment (including a `/`).
    pub fn child(&self, name: &str) -> Result<RelPath, RelPathError> {
        if name.contains('/') || name.is_empty() {
            return Err(RelPathError::EmptySegment(format!("{}/{name}", self.0)));
        }
        RelPath::parse(&format!("{}/{name}", self.0))
    }

    /// Where this path lands under `root`, joined segment by segment in the
    /// host's own separator. Pure path arithmetic, no filesystem access; the
    /// result is always `root` followed by one normal component per segment.
    pub fn join_under(&self, root: &Path) -> PathBuf {
        let mut path = root.to_path_buf();
        path.extend(self.segments());
        path
    }
}

fn starts_with_drive(segment: &str) -> bool {
    let bytes = segment.as_bytes();
    bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':'
}

/// The wire's way in: a path decoded off a connection is parsed like any
/// other, so a remote peer cannot name a path outside the root.
impl TryFrom<String> for RelPath {
    type Error = RelPathError;

    fn try_from(text: String) -> Result<Self, Self::Error> {
        RelPath::parse(&text)
    }
}

impl From<RelPath> for String {
    fn from(path: RelPath) -> String {
        path.0
    }
}

impl FromStr for RelPath {
    type Err = RelPathError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        RelPath::parse(text)
    }
}

impl fmt::Display for RelPath {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use std::path::Component;

    use super::*;

    const VALID: [&str; 8] = [
        "a",
        "notes.txt",
        "a/b/c.txt",
        ".git/config",
        "..hidden/x",
        "log:old",
        "dir/ab:c",
        "sp ace/ünïcode.md",
    ];

    #[test]
    fn accepts_nested_forward_slash_paths() {
        for text in VALID {
            let path = RelPath::parse(text).unwrap_or_else(|e| panic!("{text:?}: {e}"));
            assert_eq!(path.as_str(), text);
        }
    }

    type Expect = fn(&RelPathError) -> bool;

    #[test]
    fn rejects_everything_that_could_escape_or_alias() {
        let cases: [(&str, Expect); 16] = [
            ("", |e| matches!(e, RelPathError::Empty)),
            ("/abs", |e| matches!(e, RelPathError::Absolute(_))),
            ("/", |e| matches!(e, RelPathError::Absolute(_))),
            ("a/../b", |e| matches!(e, RelPathError::DotSegment(_))),
            ("..", |e| matches!(e, RelPathError::DotSegment(_))),
            ("../x", |e| matches!(e, RelPathError::DotSegment(_))),
            ("./a", |e| matches!(e, RelPathError::DotSegment(_))),
            ("a/.", |e| matches!(e, RelPathError::DotSegment(_))),
            ("a//b", |e| matches!(e, RelPathError::EmptySegment(_))),
            ("a/", |e| matches!(e, RelPathError::EmptySegment(_))),
            ("a\\..\\b", |e| matches!(e, RelPathError::Backslash(_))),
            ("..\\x", |e| matches!(e, RelPathError::Backslash(_))),
            ("C:", |e| matches!(e, RelPathError::Drive(_))),
            ("C:/Windows", |e| matches!(e, RelPathError::Drive(_))),
            ("a/c:evil", |e| matches!(e, RelPathError::Drive(_))),
            ("a\0b", |e| matches!(e, RelPathError::Nul(_))),
        ];
        for (text, expected) in cases {
            match RelPath::parse(text) {
                Ok(path) => panic!("{text:?} parsed as {path}"),
                Err(error) => assert!(expected(&error), "{text:?}: {error:?}"),
            }
        }
    }

    #[test]
    fn joining_any_valid_path_stays_under_the_root() {
        let roots = [Path::new("/r"), Path::new("r"), Path::new("/deep/root/")];
        for root in roots {
            for text in VALID {
                let path = RelPath::parse(text).unwrap_or_else(|e| panic!("{e}"));
                let joined = path.join_under(root);
                let rest = joined
                    .strip_prefix(root)
                    .unwrap_or_else(|_| panic!("{joined:?} escaped {root:?}"));
                let components: Vec<Component<'_>> = rest.components().collect();
                assert_eq!(components.len(), path.segments().count(), "{joined:?}");
                assert!(
                    components.iter().all(|c| matches!(c, Component::Normal(_))),
                    "{joined:?}"
                );
            }
        }
    }

    #[test]
    fn prefixes_run_shallowest_first_and_end_with_the_path() {
        let path = RelPath::parse("a/b/c").unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(path.prefixes().collect::<Vec<_>>(), ["a", "a/b", "a/b/c"]);
        let top = RelPath::parse("a").unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(top.prefixes().collect::<Vec<_>>(), ["a"]);
    }

    #[test]
    fn parent_name_child_and_within() {
        let parse = |text: &str| RelPath::parse(text).unwrap_or_else(|e| panic!("{e}"));
        let path = parse("a/b/c.txt");
        assert_eq!(path.name(), "c.txt");
        assert_eq!(path.parent(), Some(parse("a/b")));
        assert_eq!(parse("top").parent(), None);
        assert_eq!(parse("a").child("b"), Ok(parse("a/b")));
        assert!(parse("a").child("..").is_err());
        assert!(parse("a").child("b/c").is_err());
        assert!(parse("sub/x").is_within(&parse("sub")));
        assert!(parse("sub").is_within(&parse("sub")));
        assert!(!parse("submarine.txt").is_within(&parse("sub")));
    }
}
