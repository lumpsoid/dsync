/// Ignore and follow glob rules for scan and symlink resolution, per SPEC §9.
///
/// Patterns are compiled at construction — [FormatException] is thrown for a
/// malformed pattern, so an invalid rule can never exist downstream.
class RuleSet {
  final List<_GlobPattern> _ignore;
  final List<_GlobPattern> _follow;

  RuleSet._(this._ignore, this._follow);

  factory RuleSet({List<String> ignore = const [], List<String> follow = const []}) {
    return RuleSet._(
      [for (final pattern in ignore) _GlobPattern(pattern)],
      [for (final pattern in follow) _GlobPattern(pattern)],
    );
  }

  /// Combines this set's patterns with [other]'s.
  ///
  /// Per SPEC §9, profile rules and CLI `--ignore` flags are additive rather
  /// than one replacing the other.
  RuleSet mergedWith(RuleSet other) {
    return RuleSet._([..._ignore, ...other._ignore], [..._follow, ...other._follow]);
  }

  /// Whether [rootRelativePath] matches an `ignore` rule (SPEC §5.1, §9).
  bool ignores(String rootRelativePath) => _ignore.any((glob) => glob.matches(rootRelativePath));

  /// Whether [rootRelativePath] matches a `follow` rule (SPEC §5.1, §9).
  bool follows(String rootRelativePath) => _follow.any((glob) => glob.matches(rootRelativePath));
}

/// A single compiled glob pattern, matched against a whole root-relative path.
///
/// Supported per SPEC §9: `*` (within one path segment), `?` (one character),
/// `**` (zero or more path segments), and `[...]` character classes. No
/// negation of a whole pattern.
class _GlobPattern {
  static const _regexSpecial = r'.\^$+{}()|';

  final RegExp _regex;

  _GlobPattern(String pattern) : _regex = RegExp(_translate(pattern));

  bool matches(String path) => _regex.hasMatch(path);

  static String _translate(String pattern) {
    if (pattern.isEmpty) {
      throw FormatException('Empty glob pattern', pattern);
    }

    final buffer = StringBuffer('^');
    var i = 0;
    while (i < pattern.length) {
      final char = pattern[i];
      if (char == '*' && i + 1 < pattern.length && pattern[i + 1] == '*') {
        i += 2;
        if (i < pattern.length && pattern[i] == '/') {
          buffer.write('(?:.*/)?');
          i += 1;
        } else {
          buffer.write('.*');
        }
      } else if (char == '*') {
        buffer.write('[^/]*');
        i += 1;
      } else if (char == '?') {
        buffer.write('[^/]');
        i += 1;
      } else if (char == '[') {
        final end = pattern.indexOf(']', i + 1);
        if (end == -1) {
          throw FormatException('Unterminated character class', pattern, i);
        }
        var body = pattern.substring(i + 1, end);
        if (body.startsWith('!')) body = '^${body.substring(1)}';
        buffer.write('[$body]');
        i = end + 1;
      } else if (_regexSpecial.contains(char)) {
        buffer.write('\\$char');
        i += 1;
      } else {
        buffer.write(char);
        i += 1;
      }
    }
    buffer.write(r'$');
    return buffer.toString();
  }
}
