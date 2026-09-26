//! Whether one path is the other or lies inside it, compared lexically.

/// How a path string is spelled: which separators split it and whether
/// case tells two names apart. A string's style is that of the machine
/// that will open it, which need not be this one, so the rule reads plain
/// strings rather than `std::path`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PathStyle {
    /// `/`-separated, case-sensitive: Unix, Android, and every far side's
    /// path (ssh, unix socket, peer).
    Posix,
    /// `\` or `/`-separated, case-insensitive.
    Windows,
}

/// Whether `a` and `b` name the same path or one lies inside the other,
/// component by component: `/a/b` nests `/a/b/c` and `/a/b/`, never
/// `/a/bc`. Empty components (a trailing or doubled separator) are
/// insignificant; a rooted path never nests a relative one.
pub fn nests(a: &str, b: &str, style: PathStyle) -> bool {
    let (a, b) = (Components::of(a, style), Components::of(b, style));
    a.rooted == b.rooted && {
        let shorter = a.names.len().min(b.names.len());
        a.names[..shorter] == b.names[..shorter]
    }
}

struct Components {
    rooted: bool,
    names: Vec<String>,
}

impl Components {
    fn of(path: &str, style: PathStyle) -> Components {
        let is_separator = |c: char| c == '/' || (style == PathStyle::Windows && c == '\\');
        let names = path
            .split(is_separator)
            .filter(|name| !name.is_empty())
            .map(|name| match style {
                PathStyle::Posix => name.to_owned(),
                PathStyle::Windows => name.to_lowercase(),
            })
            .collect();
        Components {
            rooted: path.starts_with(is_separator),
            names,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn posix(a: &str, b: &str) -> bool {
        let forward = nests(a, b, PathStyle::Posix);
        assert_eq!(forward, nests(b, a, PathStyle::Posix), "{a} vs {b}");
        forward
    }

    fn windows(a: &str, b: &str) -> bool {
        let forward = nests(a, b, PathStyle::Windows);
        assert_eq!(forward, nests(b, a, PathStyle::Windows), "{a} vs {b}");
        forward
    }

    #[test]
    fn equal_inside_and_containing_paths_nest() {
        assert!(posix("/a/b", "/a/b"));
        assert!(posix("/a/b", "/a/b/c/d"));
        assert!(posix("/", "/a"));
        // Positive control: siblings do not.
        assert!(!posix("/a/b", "/a/c"));
    }

    #[test]
    fn a_name_that_merely_starts_with_another_does_not_nest() {
        assert!(!posix("/a/b", "/a/bc"));
        assert!(!posix("/a/bc", "/a/b/c"));
    }

    #[test]
    fn a_trailing_separator_is_insignificant() {
        assert!(posix("/a/b/", "/a/b"));
        assert!(posix("/a/b/", "/a/b/c"));
        assert!(!posix("/a/b/", "/a/bc"));
    }

    #[test]
    fn a_rooted_path_never_nests_a_relative_one() {
        assert!(!posix("/notes", "notes"));
        assert!(posix("~/notes", "~/notes/x"));
        assert!(!posix("~/notes", "~/other"));
    }

    #[test]
    fn posix_is_case_sensitive_and_backslash_is_a_name_character() {
        assert!(!posix("/a/B", "/a/b"));
        assert!(!posix("/a\\b", "/a/b"));
        assert!(posix("/a\\b", "/a\\b/c"));
    }

    #[test]
    fn windows_folds_case_and_splits_on_both_separators() {
        assert!(windows("C:\\Users\\Me", "c:/users/me/Documents"));
        assert!(windows("C:\\Users\\Me\\", "C:\\USERS\\me"));
        assert!(!windows("C:\\Users\\Me", "C:\\Users\\Mel"));
        assert!(!windows("C:\\Users", "D:\\Users"));
        // The same strings under Posix rules are unrelated.
        assert!(!posix("C:\\Users\\Me", "c:/users/me/Documents"));
    }
}
