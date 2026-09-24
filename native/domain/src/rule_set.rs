//! The ignore and follow rules of a run (SPEC §5.1, §9).

use crate::glob::Glob;
use crate::rel_path::RelPath;

/// A run's `ignore` and `follow` globs.
///
/// `ignore` covers ancestors: a path is out when it or any directory above
/// it matches, because the scan prunes an ignored directory instead of
/// descending into it (`**/.git` matches `.git`, not `.git/config`).
/// Anything deciding what is in the sync has to agree with the walk, or a
/// pruned subtree reads as a tree of deletions and is propagated as one.
///
/// `follow` matches a link's own path only.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct RuleSet {
    ignore: Vec<Glob>,
    follow: Vec<Glob>,
}

impl RuleSet {
    pub fn new(ignore: Vec<Glob>, follow: Vec<Glob>) -> RuleSet {
        RuleSet { ignore, follow }
    }

    /// This set's rules followed by `other`'s. Profile rules and CLI
    /// `--ignore` flags add up rather than one replacing the other (§9).
    pub fn merged_with(&self, other: &RuleSet) -> RuleSet {
        RuleSet {
            ignore: [self.ignore.as_slice(), other.ignore.as_slice()].concat(),
            follow: [self.follow.as_slice(), other.follow.as_slice()].concat(),
        }
    }

    pub fn ignore(&self) -> &[Glob] {
        &self.ignore
    }

    pub fn follow(&self) -> &[Glob] {
        &self.follow
    }

    /// Whether `path` is excluded, itself or through an ancestor.
    pub fn ignores(&self, path: &RelPath) -> bool {
        self.ignore_rule_for(path).is_some()
    }

    /// The rule that excludes `path`, as written, so a user can be told
    /// which one to change. Several may apply: the one excluding the
    /// shallowest ancestor wins - removing a deeper one changes nothing
    /// while the ancestor is still pruned - and among rules matching that
    /// ancestor, the one written first.
    pub fn ignore_rule_for(&self, path: &RelPath) -> Option<&Glob> {
        if self.ignore.is_empty() {
            return None;
        }
        path.prefixes()
            .find_map(|prefix| self.ignore.iter().find(|glob| glob.is_match(prefix)))
    }

    /// Whether the link at `path` is to be followed (SPEC §5.1).
    pub fn follows(&self, path: &RelPath) -> bool {
        self.follow.iter().any(|glob| glob.is_match(path.as_str()))
    }
}

#[cfg(test)]
mod tests {
    //! Every case of `test/dsync_core/models/rule_set_test.dart`.

    use super::*;

    fn globs(patterns: &[&str]) -> Vec<Glob> {
        patterns
            .iter()
            .map(|p| Glob::new(p).unwrap_or_else(|e| panic!("{e}")))
            .collect()
    }

    fn ignoring(patterns: &[&str]) -> RuleSet {
        RuleSet::new(globs(patterns), vec![])
    }

    fn following(patterns: &[&str]) -> RuleSet {
        RuleSet::new(vec![], globs(patterns))
    }

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap_or_else(|e| panic!("{e}"))
    }

    /// Asserts which paths `rules` ignores, positive and negative together.
    fn assert_ignores(rules: &RuleSet, yes: &[&str], no: &[&str]) {
        for text in yes {
            assert!(rules.ignores(&path(text)), "should ignore {text}");
        }
        for text in no {
            assert!(!rules.ignores(&path(text)), "should keep {text}");
        }
    }

    #[test]
    fn no_patterns_ignores_and_follows_nothing() {
        let rules = RuleSet::default();
        assert!(!rules.ignores(&path("anything")));
        assert!(!rules.follows(&path("anything")));
    }

    #[test]
    fn literal_pattern_matches_only_that_exact_path() {
        assert_ignores(
            &ignoring(&["notes.txt"]),
            &["notes.txt"],
            &["sub/notes.txt", "notes.txt.bak"],
        );
    }

    #[test]
    fn star_matches_within_a_single_segment() {
        assert_ignores(&ignoring(&["*.tmp"]), &["a.tmp", ".tmp"], &["sub/a.tmp"]);
    }

    #[test]
    fn question_mark_matches_exactly_one_character() {
        assert_ignores(
            &ignoring(&["file?.txt"]),
            &["file1.txt"],
            &["file12.txt", "file.txt"],
        );
    }

    #[test]
    fn leading_double_star_matches_zero_or_more_directories() {
        assert_ignores(
            &ignoring(&["**/.git"]),
            &[".git", "sub/.git", "a/b/.git"],
            &["gitstuff"],
        );
    }

    #[test]
    fn trailing_double_star_matches_everything_beneath() {
        assert_ignores(
            &ignoring(&["node_modules/**"]),
            &["node_modules/x.js", "node_modules/sub/x.js"],
            &["node_modules"],
        );
    }

    #[test]
    fn character_class_matches_any_listed_character() {
        assert_ignores(
            &ignoring(&["file[12].txt"]),
            &["file1.txt", "file2.txt"],
            &["file3.txt"],
        );
    }

    #[test]
    fn character_class_negation_with_bang() {
        assert_ignores(
            &ignoring(&["file[!12].txt"]),
            &["file3.txt"],
            &["file1.txt"],
        );
    }

    #[test]
    fn regex_special_characters_are_literal() {
        assert_ignores(&ignoring(&["a.b"]), &["a.b"], &["aXb"]);
    }

    #[test]
    fn character_class_range() {
        assert_ignores(
            &ignoring(&["file[a-c].txt"]),
            &["fileb.txt"],
            &["filed.txt"],
        );
    }

    #[test]
    fn a_leading_close_bracket_is_a_class_member() {
        assert_ignores(
            &ignoring(&["file[]a].txt"]),
            &["file].txt", "filea.txt"],
            &["fileb.txt"],
        );
    }

    #[test]
    fn a_leading_close_bracket_after_negation_is_a_member() {
        assert_ignores(
            &ignoring(&["file[!]a].txt"]),
            &["fileb.txt"],
            &["file].txt", "filea.txt"],
        );
    }

    #[test]
    fn regex_syntax_inside_a_class_is_literal() {
        // The `\` half of this case is in glob.rs: a RelPath cannot hold one.
        assert_ignores(
            &ignoring(&["file[\\d].txt"]),
            &["filed.txt"],
            &["file5.txt"],
        );
    }

    #[test]
    fn a_caret_that_is_not_leading_is_a_class_member() {
        assert_ignores(
            &ignoring(&["file[a^].txt"]),
            &["file^.txt", "filea.txt"],
            &["fileb.txt"],
        );
    }

    #[test]
    fn rejects_an_empty_pattern() {
        assert!(Glob::new("").is_err());
    }

    #[test]
    fn rejects_an_unterminated_character_class() {
        assert!(Glob::new("a[bc").is_err());
        assert!(Glob::new("a[bc]").is_ok());
    }

    #[test]
    fn a_path_beneath_an_ignored_directory_is_ignored() {
        assert_ignores(
            &ignoring(&["**/.git"]),
            &[".git/config", "sub/.git/refs/heads/main"],
            &[],
        );
    }

    #[test]
    fn a_sibling_of_an_ignored_directory_is_not_ignored() {
        assert_ignores(
            &ignoring(&["**/.git"]),
            &[],
            &[".gitignore", "sub/notes.txt"],
        );
    }

    #[test]
    fn follow_rules_match_the_path_alone_not_its_ancestors() {
        let rules = following(&["shared"]);
        assert!(rules.follows(&path("shared")));
        assert!(!rules.follows(&path("shared/deep.txt")));
    }

    #[test]
    fn a_path_nothing_matches_has_no_rule() {
        assert_eq!(ignoring(&["*.tmp"]).ignore_rule_for(&path("a.txt")), None);
    }

    #[test]
    fn the_rule_is_returned_as_written() {
        let rules = ignoring(&["**/*.tmp"]);
        let rule = rules.ignore_rule_for(&path("a/b.tmp"));
        assert_eq!(rule.map(Glob::as_str), Some("**/*.tmp"));
    }

    #[test]
    fn a_path_under_an_excluded_folder_names_the_folder_rule() {
        let rules = ignoring(&["**/.git", "*.config"]);
        let rule = rules.ignore_rule_for(&path("src/.git/config"));
        assert_eq!(rule.map(Glob::as_str), Some("**/.git"));
    }

    #[test]
    fn ignore_rule_for_agrees_with_ignores_on_every_path() {
        let rules = ignoring(&["**/.git", "*.tmp"]);
        for text in ["a.tmp", ".git/config", "src/main.dart", "a/b.tmp"] {
            let p = path(text);
            assert_eq!(
                rules.ignore_rule_for(&p).is_some(),
                rules.ignores(&p),
                "{text}"
            );
        }
    }

    #[test]
    fn ignore_and_follow_patterns_are_independent() {
        let rules = RuleSet::new(globs(&["*.tmp"]), globs(&["shared"]));
        assert!(rules.ignores(&path("a.tmp")));
        assert!(!rules.follows(&path("a.tmp")));
        assert!(rules.follows(&path("shared")));
        assert!(!rules.ignores(&path("shared")));
    }

    #[test]
    fn merging_combines_ignore_patterns_additively() {
        let merged = ignoring(&["*.tmp"]).merged_with(&ignoring(&["*.log"]));
        assert_ignores(&merged, &["a.tmp", "a.log"], &["a.txt"]);
    }

    #[test]
    fn merging_combines_follow_patterns_additively() {
        let merged = following(&["shared"]).merged_with(&following(&["linked"]));
        assert!(merged.follows(&path("shared")));
        assert!(merged.follows(&path("linked")));
    }

    #[test]
    fn merging_leaves_both_originals_alone() {
        let profile = ignoring(&["*.tmp"]);
        let cli = ignoring(&["*.log"]);
        let _ = profile.merged_with(&cli);
        assert!(!profile.ignores(&path("a.log")));
        assert!(!cli.ignores(&path("a.tmp")));
    }
}
