//! One glob pattern, compiled at construction (SPEC §9).

use std::fmt;
use std::str::FromStr;

/// A glob matched against a whole root-relative path (SPEC §9): `*` within
/// one segment, `?` one character other than `/`, `**/` zero or more
/// leading directories, `**` anything including `/`, and `[...]` classes
/// with ranges and `!`/`^` negation. No escape character and no negation
/// of a whole pattern.
///
/// A `]` right after `[` (or after its `!`/`^`) is a class member, not the
/// end - the only way glob spells a class containing `]`. Everything else
/// inside a class is literal: `[\d]` is `\` or `d`, never "a digit".
///
/// Compiled to its own tokens rather than a regex, so no pattern can reach
/// through the glob syntax into regex features SPEC §9 does not offer. The
/// source is kept: rules travel to a remote replica as written, and the
/// far side compiles them itself.
#[derive(Clone, serde::Serialize, serde::Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Glob {
    source: String,
    tokens: Vec<Token>,
}

#[derive(Clone, Debug)]
enum Token {
    Literal(char),
    /// `?`
    AnyChar,
    /// `*`
    AnyInSegment,
    /// `**` not followed by `/`
    AnyChars,
    /// `**/`: zero or more whole leading segments.
    AnySegments,
    Class {
        negated: bool,
        members: Vec<Member>,
    },
}

#[derive(Clone, Debug)]
enum Member {
    Char(char),
    Range(char, char),
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum GlobError {
    #[error("empty glob pattern")]
    Empty,
    #[error("glob {0:?} has an unterminated character class")]
    UnterminatedClass(String),
    #[error("glob {pattern:?} has a reversed range {from}-{to}")]
    ReversedRange {
        pattern: String,
        from: char,
        to: char,
    },
}

impl Glob {
    pub fn new(pattern: &str) -> Result<Glob, GlobError> {
        if pattern.is_empty() {
            return Err(GlobError::Empty);
        }
        let chars: Vec<char> = pattern.chars().collect();
        let mut tokens = Vec::new();
        let mut i = 0;
        while i < chars.len() {
            match chars[i] {
                '*' if chars.get(i + 1) == Some(&'*') => {
                    if chars.get(i + 2) == Some(&'/') {
                        tokens.push(Token::AnySegments);
                        i += 3;
                    } else {
                        tokens.push(Token::AnyChars);
                        i += 2;
                    }
                }
                '*' => {
                    tokens.push(Token::AnyInSegment);
                    i += 1;
                }
                '?' => {
                    tokens.push(Token::AnyChar);
                    i += 1;
                }
                '[' => {
                    let (token, end) = class(pattern, &chars, i)?;
                    tokens.push(token);
                    i = end + 1;
                }
                other => {
                    tokens.push(Token::Literal(other));
                    i += 1;
                }
            }
        }
        Ok(Glob {
            source: pattern.to_owned(),
            tokens,
        })
    }

    /// The pattern as written.
    pub fn as_str(&self) -> &str {
        &self.source
    }

    /// Whether the whole of `path` matches.
    pub fn is_match(&self, path: &str) -> bool {
        matches(&self.tokens, path)
    }
}

impl TryFrom<String> for Glob {
    type Error = GlobError;

    fn try_from(pattern: String) -> Result<Self, Self::Error> {
        Glob::new(&pattern)
    }
}

impl From<Glob> for String {
    fn from(glob: Glob) -> String {
        glob.source
    }
}

/// The class opening at `open`, and the index of its closing `]`.
fn class(pattern: &str, chars: &[char], open: usize) -> Result<(Token, usize), GlobError> {
    let mut start = open + 1;
    let negated = matches!(chars.get(start), Some('!' | '^'));
    if negated {
        start += 1;
    }
    // A `]` in first position is a member, so the search for the end
    // starts after it.
    let search = if chars.get(start) == Some(&']') {
        start + 1
    } else {
        start
    };
    let end = chars[search.min(chars.len())..]
        .iter()
        .position(|c| *c == ']')
        .map(|offset| search + offset)
        .ok_or_else(|| GlobError::UnterminatedClass(pattern.to_owned()))?;

    let body = &chars[start..end];
    let mut members = Vec::new();
    let mut j = 0;
    while j < body.len() {
        if body.get(j + 1) == Some(&'-') && j + 2 < body.len() {
            let (from, to) = (body[j], body[j + 2]);
            if from > to {
                return Err(GlobError::ReversedRange {
                    pattern: pattern.to_owned(),
                    from,
                    to,
                });
            }
            members.push(Member::Range(from, to));
            j += 3;
        } else {
            members.push(Member::Char(body[j]));
            j += 1;
        }
    }
    Ok((Token::Class { negated, members }, end))
}

fn matches(tokens: &[Token], path: &str) -> bool {
    let Some((token, rest)) = tokens.split_first() else {
        return path.is_empty();
    };
    let mut chars = path.chars();
    match token {
        Token::Literal(expected) => {
            chars.next() == Some(*expected) && matches(rest, chars.as_str())
        }
        Token::AnyChar => chars.next().is_some_and(|c| c != '/') && matches(rest, chars.as_str()),
        Token::Class { negated, members } => {
            chars.next().is_some_and(|c| {
                members.iter().any(|member| match member {
                    Member::Char(m) => *m == c,
                    Member::Range(from, to) => (*from..=*to).contains(&c),
                }) != *negated
            }) && matches(rest, chars.as_str())
        }
        Token::AnyInSegment => {
            let segment_end = path.find('/').unwrap_or(path.len());
            char_boundaries(&path[..segment_end]).any(|i| matches(rest, &path[i..]))
        }
        Token::AnyChars => char_boundaries(path).any(|i| matches(rest, &path[i..])),
        Token::AnySegments => {
            matches(rest, path)
                || path
                    .match_indices('/')
                    .any(|(slash, _)| matches(rest, &path[slash + 1..]))
        }
    }
}

/// Every char boundary of `text`, `0` through `text.len()` inclusive.
fn char_boundaries(text: &str) -> impl Iterator<Item = usize> {
    text.char_indices()
        .map(|(i, _)| i)
        .chain(std::iter::once(text.len()))
}

impl FromStr for Glob {
    type Err = GlobError;

    fn from_str(pattern: &str) -> Result<Self, Self::Err> {
        Glob::new(pattern)
    }
}

impl PartialEq for Glob {
    fn eq(&self, other: &Self) -> bool {
        self.source == other.source
    }
}

impl Eq for Glob {}

impl fmt::Display for Glob {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.source)
    }
}

impl fmt::Debug for Glob {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Glob({:?})", self.source)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn glob(pattern: &str) -> Glob {
        Glob::new(pattern).unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn regex_syntax_inside_a_class_is_literal() {
        // SPEC §9 offers globs, not regexes: `\` and `d`, not "any digit".
        // Matched as a raw string: a replica path cannot hold a `\`.
        let pattern = glob("file[\\d].txt");
        assert!(pattern.is_match("file\\.txt"));
        assert!(pattern.is_match("filed.txt"));
        assert!(!pattern.is_match("file5.txt"));
    }

    #[test]
    fn regex_metacharacters_outside_a_class_are_literal() {
        let pattern = glob("a+(b)|c$");
        assert!(pattern.is_match("a+(b)|c$"));
        assert!(!pattern.is_match("aa(b)|c"));
    }

    #[test]
    fn trailing_and_leading_dashes_in_a_class_are_members() {
        let pattern = glob("x[-a]y[b-]");
        assert!(pattern.is_match("x-yb"));
        assert!(pattern.is_match("xay-"));
        assert!(!pattern.is_match("xcyb"));
    }

    #[test]
    fn rejects_a_reversed_range_and_an_unterminated_class() {
        assert!(matches!(
            Glob::new("[z-a]"),
            Err(GlobError::ReversedRange { .. })
        ));
        assert!(matches!(
            Glob::new("a[]"),
            Err(GlobError::UnterminatedClass(_))
        ));
        assert!(matches!(
            Glob::new("a[!"),
            Err(GlobError::UnterminatedClass(_))
        ));
        assert_eq!(Glob::new(""), Err(GlobError::Empty));
    }

    #[test]
    fn stars_span_multibyte_characters() {
        assert!(glob("*.md").is_match("ünï.md"));
        assert!(glob("?.md").is_match("ü.md"));
        assert!(glob("**/x").is_match("ä/ö/x"));
    }
}
