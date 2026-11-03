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

/// Says in plain words, inside the sibling name, why the file is there.
const CONFLICT_COPY_MARKER: &str = "dsync-copy-from";

/// What an empty device label (there was nothing to sanitise) falls back to.
const FALLBACK_DEVICE_LABEL: &str = "unknown-device";

impl RelPath {
    /// Sibling path for a "keep both" conflict copy (Design B): same
    /// folder, `<stem>.dsync-copy-from-<device>-<YYYY-MM-DD-HHMM>.<ext>` -
    /// e.g. `notes.dsync-copy-from-Phone-2026-09-25-1403.md`. The extension
    /// stays last so the merge app still recognises the file type. A
    /// dotfile (`.bashrc`) or an extensionless name (`Makefile`) simply has
    /// nothing after the timestamp; `archive.tar.gz` keeps `tar` in the
    /// stem and `gz` as the extension.
    ///
    /// `device` is sanitised to what a `RelPath` segment allows and Windows
    /// can hold: `/`, `\`, `<>:"|?*` and control characters (including
    /// NUL) become `_`; spaces are left alone, since `RelPath::parse`
    /// already accepts them inside a segment and the timestamp follows.
    /// An empty label falls back to a fixed name, so the result always
    /// re-parses as a valid `RelPath`.
    ///
    /// `at` is the *peer's* file's own `FileMeta::mtime_us` (SPEC §5.2,
    /// microseconds since the Unix epoch), formatted in UTC - the hub
    /// cannot read the local offset soundly, and both name parts must come
    /// from data the conflict already carries, never a clock. That makes
    /// the name identify the *version*: a repeat keep-both of the same peer
    /// version yields the same name (idempotent); a changed peer file gets
    /// a new one. No collision handling - decided by the user: on a
    /// filesystem that folds case, a sibling that differs from a file
    /// already there only by case is caught by the write's "absent"
    /// precondition, which the filesystem answers folded (SPEC §16).
    pub fn conflict_copy(&self, device: &str, at: i64) -> RelPath {
        let (stem, ext) = split_stem_and_ext(self.name());
        let device = sanitize_device_label(device);
        let timestamp = format_utc_minute(at);
        let mut sibling_name = format!("{stem}.{CONFLICT_COPY_MARKER}-{device}-{timestamp}");
        if let Some(ext) = ext {
            sibling_name.push('.');
            sibling_name.push_str(ext);
        }
        let sibling_path = match self.parent() {
            Some(parent) => format!("{}/{sibling_name}", parent.as_str()),
            None => sibling_name,
        };
        RelPath::parse(&sibling_path)
            .expect("a sanitised conflict-copy name is always a valid RelPath")
    }
}

/// Splits `name` (a path's own last segment) into its stem and extension:
/// the extension is what comes after the *last* `.`, so `archive.tar.gz`
/// keeps `tar` in the stem. A leading dot (`.bashrc`) is not a separator -
/// there is nothing before it to be a stem - and a trailing dot (`file.`)
/// leaves nothing after it to be an extension; both read as "no extension",
/// the whole name becoming the stem.
fn split_stem_and_ext(name: &str) -> (&str, Option<&str>) {
    match name.rfind('.') {
        Some(dot) if dot > 0 && dot + 1 < name.len() => (&name[..dot], Some(&name[dot + 1..])),
        _ => (name, None),
    }
}

/// A device label safe to embed inside one `RelPath` segment (see
/// [`RelPath::conflict_copy`]).
fn sanitize_device_label(device: &str) -> String {
    if device.is_empty() {
        return FALLBACK_DEVICE_LABEL.to_owned();
    }
    device
        .chars()
        .map(|c| {
            if matches!(c, '/' | '\\' | '<' | '>' | ':' | '"' | '|' | '?' | '*') || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .collect()
}

/// `mtime_us` (microseconds since the Unix epoch) as `YYYY-MM-DD-HHMM`, in
/// UTC, to the minute - a conflict copy's name need not tell seconds apart.
/// A timestamp outside what `time` can represent (an implausible mtime)
/// falls back to the Unix epoch itself rather than panicking.
fn format_utc_minute(mtime_us: i64) -> String {
    let seconds = mtime_us.div_euclid(1_000_000);
    let at = time::OffsetDateTime::from_unix_timestamp(seconds)
        .unwrap_or(time::OffsetDateTime::UNIX_EPOCH);
    format!(
        "{:04}-{:02}-{:02}-{:02}{:02}",
        at.year(),
        u8::from(at.month()),
        at.day(),
        at.hour(),
        at.minute(),
    )
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

    /// 2026-09-25 14:03:00.5 UTC, as microseconds since the epoch (checked
    /// against `date -u -d '2026-09-25 14:03:00' +%s000000`).
    const MTIME_2026_09_25_1403: i64 = 1_790_344_980_500_000;

    #[test]
    fn conflict_copy_names_the_peers_version_next_to_the_original() {
        let notes = RelPath::parse("a/b/notes.md").unwrap_or_else(|e| panic!("{e}"));
        let sibling = notes.conflict_copy("Phone", MTIME_2026_09_25_1403);
        assert_eq!(
            sibling.as_str(),
            "a/b/notes.dsync-copy-from-Phone-2026-09-25-1403.md"
        );
        assert!(RelPath::parse(sibling.as_str()).is_ok());

        // Idempotent: the same peer version yields the same name again.
        assert_eq!(sibling, notes.conflict_copy("Phone", MTIME_2026_09_25_1403));
        // A changed peer file (a different mtime) gets a new name.
        assert_ne!(
            sibling,
            notes.conflict_copy("Phone", MTIME_2026_09_25_1403 + 60_000_000)
        );
    }

    #[test]
    fn conflict_copy_handles_dotfiles_and_missing_or_double_extensions() {
        let at = MTIME_2026_09_25_1403;
        let copy_of = |text: &str| {
            RelPath::parse(text)
                .unwrap_or_else(|e| panic!("{e}"))
                .conflict_copy("host", at)
        };
        assert_eq!(
            copy_of(".bashrc").as_str(),
            ".bashrc.dsync-copy-from-host-2026-09-25-1403"
        );
        assert_eq!(
            copy_of("Makefile").as_str(),
            "Makefile.dsync-copy-from-host-2026-09-25-1403"
        );
        assert_eq!(
            copy_of("archive.tar.gz").as_str(),
            "archive.tar.dsync-copy-from-host-2026-09-25-1403.gz"
        );
        for text in [".bashrc", "Makefile", "archive.tar.gz"] {
            assert!(RelPath::parse(copy_of(text).as_str()).is_ok());
        }
    }

    #[test]
    fn conflict_copy_sanitises_a_device_label_that_would_break_the_segment() {
        let notes = RelPath::parse("notes.md").unwrap_or_else(|e| panic!("{e}"));

        // A `/` would split the segment, so it - and a plain space, which
        // is legal in a segment - are treated differently.
        let sibling = notes.conflict_copy("My Phone/2", MTIME_2026_09_25_1403);
        assert_eq!(
            sibling.as_str(),
            "notes.dsync-copy-from-My Phone_2-2026-09-25-1403.md"
        );
        assert!(RelPath::parse(sibling.as_str()).is_ok());

        // Nor does Windows hold any of these in a name.
        let sibling = notes.conflict_copy("Pixel: \"work\"?", MTIME_2026_09_25_1403);
        assert_eq!(
            sibling.as_str(),
            "notes.dsync-copy-from-Pixel_ _work__-2026-09-25-1403.md"
        );

        // An empty label falls back rather than producing a broken name.
        let fallback = notes.conflict_copy("", MTIME_2026_09_25_1403);
        assert_eq!(
            fallback.as_str(),
            "notes.dsync-copy-from-unknown-device-2026-09-25-1403.md"
        );
    }

    #[test]
    fn conflict_copy_does_not_panic_on_a_pre_1970_mtime() {
        let notes = RelPath::parse("notes.md").unwrap_or_else(|e| panic!("{e}"));
        // One day before the epoch: 1969-12-31 00:00:00 UTC.
        let sibling = notes.conflict_copy("host", -86_400_000_000);
        assert_eq!(
            sibling.as_str(),
            "notes.dsync-copy-from-host-1969-12-31-0000.md"
        );
        assert!(RelPath::parse(sibling.as_str()).is_ok());
    }
}
