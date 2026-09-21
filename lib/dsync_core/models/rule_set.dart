/// Ignore and follow glob rules for scan and symlink resolution, per SPEC §9.
///
/// Patterns are compiled at construction — [FormatException] is thrown for a
/// malformed pattern, so an invalid rule can never exist downstream.
class RuleSet {
  final List<_GlobPattern> _ignore;
  final List<_GlobPattern> _follow;

  RuleSet._(this._ignore, this._follow);

  factory RuleSet({
    List<String> ignore = const [],
    List<String> follow = const [],
  }) {
    return RuleSet._(
      [for (final pattern in ignore) _GlobPattern(pattern)],
      [for (final pattern in follow) _GlobPattern(pattern)],
    );
  }

  /// The `ignore` patterns this set was built from, in order.
  ///
  /// Exposed so the rules can be sent to a remote replica (SPEC §9: rules come
  /// from the profile, which only the initiating side has). The compiled form
  /// stays private — a peer receives patterns and compiles them itself, so a
  /// malformed one is rejected on both sides rather than smuggled across as a
  /// regex.
  List<String> get ignorePatterns => [for (final glob in _ignore) glob.source];

  /// The `follow` patterns this set was built from, in order. See
  /// [ignorePatterns].
  List<String> get followPatterns => [for (final glob in _follow) glob.source];

  /// Combines this set's patterns with [other]'s.
  ///
  /// Per SPEC §9, profile rules and CLI `--ignore` flags are additive rather
  /// than one replacing the other.
  RuleSet mergedWith(RuleSet other) {
    return RuleSet._(
      [..._ignore, ...other._ignore],
      [..._follow, ...other._follow],
    );
  }

  /// Whether [rootRelativePath] is excluded from the sync (SPEC §5.1, §9).
  ///
  /// True when the path itself matches an `ignore` rule, or when any ancestor
  /// directory does. The ancestor case is not a convenience: the walk prunes
  /// an ignored directory instead of descending into it, so its children are
  /// never visited even though their own paths match nothing — `**/.git`
  /// matches `.git` but not `.git/config`. Everything that decides whether a
  /// path is in the sync has to agree with the walk, or a pruned subtree reads
  /// as a tree of deletions and gets propagated as one.
  bool ignores(String rootRelativePath) =>
      ignorePatternFor(rootRelativePath) != null;

  /// The `ignore` pattern, as written, that excludes [rootRelativePath] —
  /// or `null` when nothing excludes it.
  ///
  /// The same walk [ignores] answers with, returning *which* rule decided
  /// instead of only that one did: a user looking at a file that is not
  /// syncing has to be told the rule to change, and "it matched something"
  /// is not an answer they can act on.
  ///
  /// Which rule is named when several apply: the one that excludes the
  /// shallowest ancestor, and among the rules matching that ancestor, the
  /// one written first. Shallowest first because that is the rule whose
  /// removal actually brings the path back — dropping a deeper rule that
  /// matches the path itself changes nothing while an ancestor directory
  /// is still pruned.
  ///
  /// The ancestor case is reported as the ancestor's own pattern, for the
  /// reason [ignores] describes: `**/.git` prunes the directory, so every
  /// path under it is out because of that rule, not because of any rule of
  /// its own.
  String? ignorePatternFor(String rootRelativePath) {
    final segments = rootRelativePath.split('/');
    for (var i = 1; i <= segments.length; i++) {
      final prefix = segments.take(i).join('/');
      for (final glob in _ignore) {
        if (glob.matches(prefix)) return glob.source;
      }
    }
    return null;
  }

  /// Whether [rootRelativePath] matches a `follow` rule (SPEC §5.1, §9).
  bool follows(String rootRelativePath) =>
      _follow.any((glob) => glob.matches(rootRelativePath));
}

/// A single compiled glob pattern, matched against a whole root-relative path.
///
/// Supported per SPEC §9: `*` (within one path segment), `?` (one character),
/// `**` (zero or more path segments), and `[...]` character classes. No
/// negation of a whole pattern.
class _GlobPattern {
  static const _regexSpecial = r'.\^$+{}()|';

  /// The pattern as written, kept so a [RuleSet] can be sent over the wire.
  final String source;

  final RegExp _regex;

  _GlobPattern(this.source) : _regex = RegExp(_translate(source));

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
        final end = _classEnd(pattern, i);
        buffer.write(_translateClass(pattern.substring(i + 1, end)));
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

  /// The index of the `]` closing the class that opens at [open].
  ///
  /// A `]` in the first position — right after `[`, or right after the `!`
  /// that negates it — is a literal member of the class rather than its
  /// terminator, which is how glob spells "a class containing `]`", since
  /// glob has no escape character.
  static int _classEnd(String pattern, int open) {
    var search = open + 1;
    if (search < pattern.length &&
        (pattern[search] == '!' || pattern[search] == '^')) {
      search++;
    }
    if (search < pattern.length && pattern[search] == ']') search++;

    final end = pattern.indexOf(']', search);
    if (end == -1) {
      throw FormatException('Unterminated character class', pattern, open);
    }
    return end;
  }

  /// Rewrites a glob class body as a regex one.
  ///
  /// Every character that means something to a regex inside a class is
  /// escaped, so a pattern cannot reach through the glob syntax and use regex
  /// features that SPEC §9 does not offer — `[\d]` is the characters `\` and
  /// `d`, not "any digit". `-` is left alone, since ranges are part of the
  /// glob grammar.
  static String _translateClass(String body) {
    final buffer = StringBuffer('[');
    var i = 0;
    if (body.startsWith('!') || body.startsWith('^')) {
      buffer.write('^');
      i = 1;
    }
    for (; i < body.length; i++) {
      final char = body[i];
      if (r'\^]['.contains(char)) buffer.write(r'\');
      buffer.write(char);
    }
    buffer.write(']');
    return buffer.toString();
  }
}
