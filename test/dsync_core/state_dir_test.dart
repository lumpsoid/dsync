import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

void main() {
  group('resolveStateDir', () {
    test('uses XDG_STATE_HOME when set', () {
      expect(
        resolveStateDir({'XDG_STATE_HOME': '/custom/state'}),
        '/custom/state/dsync',
      );
    });

    test('falls back to ~/.local/state when XDG_STATE_HOME is unset', () {
      expect(
        resolveStateDir({'HOME': '/home/me'}),
        '/home/me/.local/state/dsync',
      );
    });

    test('ignores an empty XDG_STATE_HOME', () {
      expect(
        resolveStateDir({'XDG_STATE_HOME': '', 'HOME': '/home/me'}),
        '/home/me/.local/state/dsync',
      );
    });

    test('fails loudly when neither variable is set', () {
      // The alternative is a path with the string "null" in it, and state
      // written to a directory of that name (SPEC §8.3).
      expect(() => resolveStateDir({}), throwsStateError);
    });

    test('fails loudly when HOME is empty', () {
      expect(() => resolveStateDir({'HOME': ''}), throwsStateError);
    });
  });
}
