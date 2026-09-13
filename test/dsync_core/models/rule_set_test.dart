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

    test('rejects an empty pattern', () {
      expect(() => RuleSet(ignore: ['']), throwsFormatException);
    });

    test('rejects a pattern with an unterminated character class', () {
      expect(() => RuleSet(ignore: ['a[bc']), throwsFormatException);
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
