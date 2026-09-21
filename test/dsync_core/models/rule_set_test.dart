import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:test/test.dart';

void main() {
  group('RuleSet with no patterns', () {
    test('ignores nothing and follows nothing', () {
      final rules = RuleSet();
      expect(rules.ignores('anything'), isFalse);
      expect(rules.follows('anything'), isFalse);
    });
  });

  group('RuleSet glob grammar', () {
    test('literal pattern matches only that exact path', () {
      final rules = RuleSet(ignore: ['notes.txt']);
      expect(rules.ignores('notes.txt'), isTrue);
      expect(rules.ignores('sub/notes.txt'), isFalse);
      expect(rules.ignores('notes.txt.bak'), isFalse);
    });

    test('* matches within a single path segment', () {
      final rules = RuleSet(ignore: ['*.tmp']);
      expect(rules.ignores('a.tmp'), isTrue);
      expect(rules.ignores('.tmp'), isTrue);
      expect(rules.ignores('sub/a.tmp'), isFalse);
    });

    test('? matches exactly one character', () {
      final rules = RuleSet(ignore: ['file?.txt']);
      expect(rules.ignores('file1.txt'), isTrue);
      expect(rules.ignores('file12.txt'), isFalse);
      expect(rules.ignores('file.txt'), isFalse);
    });

    test('** as a leading segment matches zero or more directories', () {
      final rules = RuleSet(ignore: ['**/.git']);
      expect(rules.ignores('.git'), isTrue);
      expect(rules.ignores('sub/.git'), isTrue);
      expect(rules.ignores('a/b/.git'), isTrue);
      expect(rules.ignores('gitstuff'), isFalse);
    });

    test('** as a trailing segment matches everything beneath it', () {
      final rules = RuleSet(ignore: ['node_modules/**']);
      expect(rules.ignores('node_modules/x.js'), isTrue);
      expect(rules.ignores('node_modules/sub/x.js'), isTrue);
      expect(rules.ignores('node_modules'), isFalse);
    });

    test('character class matches any listed character', () {
      final rules = RuleSet(ignore: ['file[12].txt']);
      expect(rules.ignores('file1.txt'), isTrue);
      expect(rules.ignores('file2.txt'), isTrue);
      expect(rules.ignores('file3.txt'), isFalse);
    });

    test('character class negation with !', () {
      final rules = RuleSet(ignore: ['file[!12].txt']);
      expect(rules.ignores('file3.txt'), isTrue);
      expect(rules.ignores('file1.txt'), isFalse);
    });

    test('regex-special characters in a pattern are literal', () {
      final rules = RuleSet(ignore: ['a.b']);
      expect(rules.ignores('a.b'), isTrue);
      expect(rules.ignores('aXb'), isFalse);
    });

    test('character class range', () {
      final rules = RuleSet(ignore: ['file[a-c].txt']);
      expect(rules.ignores('fileb.txt'), isTrue);
      expect(rules.ignores('filed.txt'), isFalse);
    });

    test('a leading ] is a literal member of the class', () {
      // Glob has no escape character, so this is the only way to write a
      // class containing ']'.
      final rules = RuleSet(ignore: ['file[]a].txt']);
      expect(rules.ignores('file].txt'), isTrue);
      expect(rules.ignores('filea.txt'), isTrue);
      expect(rules.ignores('fileb.txt'), isFalse);
    });

    test('a leading ] after a negation is also literal', () {
      final rules = RuleSet(ignore: ['file[!]a].txt']);
      expect(rules.ignores('fileb.txt'), isTrue);
      expect(rules.ignores('file].txt'), isFalse);
      expect(rules.ignores('filea.txt'), isFalse);
    });

    test('regex syntax inside a class is literal, not regex', () {
      // SPEC §9 offers globs, not regexes: these are the characters `\` and
      // `d`, not "any digit".
      final rules = RuleSet(ignore: [r'file[\d].txt']);
      expect(rules.ignores(r'file\.txt'), isTrue);
      expect(rules.ignores('filed.txt'), isTrue);
      expect(rules.ignores('file5.txt'), isFalse);
    });

    test('a caret that is not leading is a literal in the class', () {
      final rules = RuleSet(ignore: ['file[a^].txt']);
      expect(rules.ignores('file^.txt'), isTrue);
      expect(rules.ignores('filea.txt'), isTrue);
      expect(rules.ignores('fileb.txt'), isFalse);
    });

    test('rejects an empty pattern', () {
      expect(() => RuleSet(ignore: ['']), throwsFormatException);
    });

    test('rejects a pattern with an unterminated character class', () {
      expect(() => RuleSet(ignore: ['a[bc']), throwsFormatException);
    });
  });

  group('RuleSet.ignores covers ancestors', () {
    test('a path beneath an ignored directory is ignored', () {
      final rules = RuleSet(ignore: ['**/.git']);
      // `**/.git` matches the directory itself and nothing beneath it, but the
      // walk prunes the whole subtree, so everything under it must read as
      // ignored too — otherwise the archive diff reports it all as deleted.
      expect(rules.ignores('.git/config'), isTrue);
      expect(rules.ignores('sub/.git/refs/heads/main'), isTrue);
    });

    test('a sibling of an ignored directory is not ignored', () {
      final rules = RuleSet(ignore: ['**/.git']);
      expect(rules.ignores('.gitignore'), isFalse);
      expect(rules.ignores('sub/notes.txt'), isFalse);
    });

    test('follow rules are matched on the path alone, not its ancestors', () {
      final rules = RuleSet(follow: ['shared']);
      expect(rules.follows('shared'), isTrue);
      expect(rules.follows('shared/deep.txt'), isFalse);
    });
  });

  group('RuleSet.ignorePatternFor names the rule that decided', () {
    test('a path nothing matches has no pattern', () {
      expect(RuleSet(ignore: ['*.tmp']).ignorePatternFor('a.txt'), isNull);
    });

    test('the pattern is returned as written, not as a regex', () {
      expect(
        RuleSet(ignore: ['**/*.tmp']).ignorePatternFor('a/b.tmp'),
        '**/*.tmp',
      );
    });

    test('a path under an excluded folder names the folder rule', () {
      // The rule the user has to remove: dropping one that matches the
      // file changes nothing while its folder is still pruned.
      final rules = RuleSet(ignore: ['**/.git', '*.config']);

      expect(rules.ignorePatternFor('src/.git/config'), '**/.git');
    });

    test('it agrees with ignores on every path', () {
      final rules = RuleSet(ignore: ['**/.git', '*.tmp']);

      for (final path in ['a.tmp', '.git/config', 'src/main.dart', 'a/b.tmp']) {
        expect(
          rules.ignorePatternFor(path) != null,
          rules.ignores(path),
          reason: path,
        );
      }
    });
  });

  group('RuleSet ignore vs follow', () {
    test('ignore and follow patterns are independent', () {
      final rules = RuleSet(ignore: ['*.tmp'], follow: ['shared']);
      expect(rules.ignores('a.tmp'), isTrue);
      expect(rules.follows('a.tmp'), isFalse);
      expect(rules.follows('shared'), isTrue);
      expect(rules.ignores('shared'), isFalse);
    });
  });

  group('RuleSet.mergedWith', () {
    test('combines ignore patterns from both sets additively', () {
      final profile = RuleSet(ignore: ['*.tmp']);
      final cli = RuleSet(ignore: ['*.log']);
      final merged = profile.mergedWith(cli);

      expect(merged.ignores('a.tmp'), isTrue);
      expect(merged.ignores('a.log'), isTrue);
      expect(merged.ignores('a.txt'), isFalse);
    });

    test('combines follow patterns from both sets additively', () {
      final a = RuleSet(follow: ['shared']);
      final b = RuleSet(follow: ['linked']);
      final merged = a.mergedWith(b);

      expect(merged.follows('shared'), isTrue);
      expect(merged.follows('linked'), isTrue);
    });

    test('does not mutate either original set', () {
      final profile = RuleSet(ignore: ['*.tmp']);
      final cli = RuleSet(ignore: ['*.log']);
      profile.mergedWith(cli);

      expect(profile.ignores('a.log'), isFalse);
      expect(cli.ignores('a.tmp'), isFalse);
    });
  });
}
