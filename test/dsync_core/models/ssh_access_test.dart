import 'package:dsync/dsync_core/models/ssh_access.dart';
import 'package:test/test.dart';

void main() {
  group('SshAccess', () {
    test('defaults to no options and the bare remote dsync (SPEC §4.2)', () {
      const access = SshAccess();
      expect(access.options, isEmpty);
      expect(access.command, 'dsync');
    });
  });

  group('SshAccess.withFlags (SPEC §12)', () {
    test('appends flag options rather than replacing the profile\'s', () {
      // A profile's `-i` is what makes the connection work at all; a
      // `--ssh-option` typed once to debug a run must not drop it.
      const profile = SshAccess(options: ['-i', '/keys/id_x']);

      final merged = profile.withFlags(options: ['-v']);

      expect(merged.options, ['-i', '/keys/id_x', '-v']);
    });

    test('a flag command overrides the profile\'s', () {
      const profile = SshAccess(command: '/opt/bin/dsync');

      expect(
        profile.withFlags(command: '/usr/bin/dsync').command,
        '/usr/bin/dsync',
      );
    });

    test('no flag command leaves the profile\'s standing', () {
      const profile = SshAccess(command: '/opt/bin/dsync');

      expect(profile.withFlags(options: ['-v']).command, '/opt/bin/dsync');
    });

    test('leaves the original alone', () {
      const profile = SshAccess(options: ['-i', '/keys/id_x']);

      profile.withFlags(options: ['-v'], command: 'other');

      expect(profile.options, ['-i', '/keys/id_x']);
      expect(profile.command, 'dsync');
    });
  });
}
