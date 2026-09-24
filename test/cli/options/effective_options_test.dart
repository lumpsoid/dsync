import 'package:dsync/cli/options/cli_options.dart';
import 'package:dsync/cli/options/cli_options_error.dart';
import 'package:dsync/cli/options/effective_options.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:dsync/cli/profile/profile.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/ssh_access.dart';
import 'package:test/test.dart';

void main() {
  const environment = {'HOME': '/home/me'};

  CliOptions optionsWith({
    SyncTarget? target,
    List<String> ignore = const [],
    List<String> sshOptions = const [],
    String? remoteCommand,
    String? warnSizeRaw,
    String? jobsRaw,
  }) {
    return CliOptions(
      target: target ?? const ProfileTarget('work'),
      dryRun: false,
      batch: false,
      json: false,
      ignore: ignore,
      sshOptions: sshOptions,
      remoteCommand: remoteCommand,
      verbose: false,
      quiet: false,
      warnSizeRaw: warnSizeRaw,
      jobsRaw: jobsRaw,
      applyConcurrencyRaw: null,
    );
  }

  group('EffectiveOptions.forProfile', () {
    final profile = Profile(
      name: 'work',
      a: Location.parse('/home/me/notes'),
      b: Location.parse('me@phone:/sdcard/notes'),
      rules: RuleSet(ignore: const ['*.tmp']),
      warnSizeBytes: 500,
      jobs: 2,
    );

    test('each side keeps its own [ssh.a]/[ssh.b], and the run\'s flags reach '
        'both (SPEC §4.2, §12)', () {
      final twoRemotes = Profile(
        name: 'both',
        a: Location.parse('ssh://work:/srv/notes'),
        b: Location.parse('ssh://phone:/sdcard/notes'),
        rules: RuleSet(),
        sshA: const SshAccess(options: ['-p', '2222']),
        sshB: const SshAccess(
          options: ['-i', '/keys/id_phone'],
          command: '/opt/bin/dsync',
        ),
      );

      final effective = EffectiveOptions.forProfile(
        twoRemotes,
        optionsWith(sshOptions: const ['-v']),
      );

      // Additive, per side: neither host's identity or port is dropped to
      // make room for the flag.
      expect(effective.sshA.options, ['-p', '2222', '-v']);
      expect(effective.sshB.options, ['-i', '/keys/id_phone', '-v']);
      expect(effective.sshA.command, SshAccess.defaultCommand);
      expect(effective.sshB.command, '/opt/bin/dsync');
    });

    test('--remote-dsync overrides every side\'s profile command', () {
      final withCommand = Profile(
        name: 'both',
        a: Location.parse('ssh://work:/srv/notes'),
        b: Location.parse('ssh://phone:/sdcard/notes'),
        rules: RuleSet(),
        sshB: const SshAccess(command: '/opt/bin/dsync'),
      );

      final effective = EffectiveOptions.forProfile(
        withCommand,
        optionsWith(remoteCommand: '/tmp/build/dsync'),
      );

      expect(effective.sshA.command, '/tmp/build/dsync');
      expect(effective.sshB.command, '/tmp/build/dsync');
    });

    test('a flag beats the profile for warn_size_bytes', () {
      final options = optionsWith(warnSizeRaw: '999');
      final effective = EffectiveOptions.forProfile(profile, options);
      expect(effective.warnSizeBytes, 999);
    });

    test('with no flag, the profile value for warn_size_bytes is kept', () {
      final options = optionsWith();
      final effective = EffectiveOptions.forProfile(profile, options);
      expect(effective.warnSizeBytes, 500);
    });

    test('a flag beats the profile for jobs', () {
      final options = optionsWith(jobsRaw: '8');
      final effective = EffectiveOptions.forProfile(profile, options);
      expect(effective.jobs, 8);
    });

    test('with no flag, the profile value for jobs is kept', () {
      final options = optionsWith();
      final effective = EffectiveOptions.forProfile(profile, options);
      expect(effective.jobs, 2);
    });

    test('with neither a flag nor a profile value, the result is null', () {
      final bareProfile = Profile(
        name: 'bare',
        a: Location.parse('/home/me/notes'),
        b: Location.parse('me@phone:/sdcard/notes'),
        rules: RuleSet(),
      );
      final effective = EffectiveOptions.forProfile(bareProfile, optionsWith());
      expect(effective.warnSizeBytes, isNull);
      expect(effective.jobs, isNull);
    });

    test('--ignore adds to the profile\'s ignore list instead of replacing '
        'it', () {
      final options = optionsWith(ignore: ['*.log']);
      final effective = EffectiveOptions.forProfile(profile, options);
      expect(effective.rules.ignorePatterns, ['*.tmp', '*.log']);
    });

    test("a profile's a/b order is preserved untouched, even remote-first", () {
      final effective = EffectiveOptions.forProfile(profile, optionsWith());
      expect(effective.a.path, '/home/me/notes');
      expect(effective.b.host, 'phone');
      expect(effective.profileId, 'work');
    });

    test('a profile whose two replicas canonicalize to the same location '
        'is rejected', () {
      final samePlace = Profile(
        name: 'dup',
        a: Location.parse('~/notes'),
        b: Location.parse(r'$HOME/notes/'),
        rules: RuleSet(),
      );
      expect(
        () => EffectiveOptions.forProfile(
          samePlace,
          optionsWith(),
          environment: environment,
        ),
        throwsA(isA<CliOptionsError>()),
      );
    });
  });

  group('EffectiveOptions.forAdHoc', () {
    test('the same pair typed in both orders derives the same id and the '
        'same A/B assignment (both-local case)', () {
      final forward = AdHocTarget.parse('/home/me/a', '/home/me/b');
      final backward = AdHocTarget.parse('/home/me/b', '/home/me/a');

      final effectiveForward = EffectiveOptions.forAdHoc(
        forward,
        optionsWith(),
      );
      final effectiveBackward = EffectiveOptions.forAdHoc(
        backward,
        optionsWith(),
      );

      expect(effectiveForward.profileId, effectiveBackward.profileId);
      expect(effectiveForward.a.path, effectiveBackward.a.path);
      expect(effectiveForward.b.path, effectiveBackward.b.path);
      // Lexicographic tie-break: "/home/me/a" sorts before "/home/me/b".
      expect(effectiveForward.a.path, '/home/me/a');
      expect(effectiveForward.b.path, '/home/me/b');
      expect(effectiveForward.profileId, startsWith('adhoc-'));
    });

    test('both sides get the run\'s ssh flags — there is no profile to '
        'differ from', () {
      final target = AdHocTarget.parse('/home/me/a', 'ssh://phone:/sdcard/b');

      final effective = EffectiveOptions.forAdHoc(
        target,
        optionsWith(
          sshOptions: const ['-i', '/keys/id_x'],
          remoteCommand: '/opt/bin/dsync',
        ),
      );

      for (final access in [effective.sshA, effective.sshB]) {
        expect(access.options, ['-i', '/keys/id_x']);
        expect(access.command, '/opt/bin/dsync');
      }
    });

    test('how a replica is reached is not part of its identity', () {
      // SPEC §5.2, §8.1: the archive keyed by this id *is* change detection,
      // so a run that added an ssh option must not get a fresh, empty one.
      final target = AdHocTarget.parse('/home/me/a', 'ssh://phone:/sdcard/b');

      final plain = EffectiveOptions.forAdHoc(target, optionsWith());
      final withAccess = EffectiveOptions.forAdHoc(
        target,
        optionsWith(sshOptions: const ['-v'], remoteCommand: '/opt/bin/dsync'),
      );

      expect(plain.profileId, withAccess.profileId);
    });

    test('an ssh:// side is remote whatever this machine\'s addresses say, '
        'so the local path is still A', () {
      // SPEC §4.1: the plain form would classify in-process here and take
      // the A slot away from the genuinely local path.
      final target = AdHocTarget.parse(
        '/home/me/notes',
        'ssh://192.168.1.10:/srv/notes',
      );

      final effective = EffectiveOptions.forAdHoc(
        target,
        optionsWith(),
        localAddresses: {'192.168.1.10'},
      );

      expect(effective.a.path, '/home/me/notes');
      expect(effective.b.host, '192.168.1.10');
    });

    test('a mixed pair keeps the local side as A', () {
      final target = AdHocTarget.parse('~/notes', 'me@phone:/sdcard/notes');
      final effective = EffectiveOptions.forAdHoc(
        target,
        optionsWith(),
        environment: environment,
      );
      expect(effective.a.host, isNull);
      expect(effective.b.host, 'phone');
    });

    test('locality is recomputed from localAddresses rather than trusted from '
        'argument order: a "two remotes" pair (legal in either order at '
        'parse time, since only a mixed pair is order-constrained) is '
        'reordered once localAddresses reveals one side is actually this '
        'machine', () {
      final target = AdHocTarget.parse('host1:/data', 'host2:/data');
      final effective = EffectiveOptions.forAdHoc(
        target,
        optionsWith(),
        localAddresses: {'host2'},
      );
      // host2 was typed second but is the local side, so it becomes A —
      // exactly the case JsonlArchiveStore._verifyHeader would otherwise
      // catch as a rootPath mismatch, per task 603ea7's DECIDED reasoning.
      expect(effective.a.host, 'host2');
      expect(effective.b.host, 'host1');
    });

    test('two different local paths in canonical (sorted) order keep their '
        'typed order', () {
      final target = AdHocTarget.parse('~/aaa', '~/bbb');
      final effective = EffectiveOptions.forAdHoc(
        target,
        optionsWith(),
        environment: environment,
      );
      expect(effective.a.path, '~/aaa');
      expect(effective.b.path, '~/bbb');
    });

    test('--ignore becomes the whole rule set — there is no profile to '
        'merge with', () {
      final target = AdHocTarget.parse('/home/me/a', '/home/me/b');
      final options = optionsWith(ignore: ['*.tmp']);
      final effective = EffectiveOptions.forAdHoc(target, options);
      expect(effective.rules.ignorePatterns, ['*.tmp']);
    });

    test('a --warn-size / --jobs flag is carried straight through', () {
      final target = AdHocTarget.parse('/home/me/a', '/home/me/b');
      final options = optionsWith(warnSizeRaw: '10', jobsRaw: '3');
      final effective = EffectiveOptions.forAdHoc(target, options);
      expect(effective.warnSizeBytes, 10);
      expect(effective.jobs, 3);
    });

    test('the same-canonical-location rejection: "~/notes" vs "\$HOME/notes" '
        'vs "/home/me/notes/" are all the same place with a matching '
        'environment map', () {
      for (final pair in [
        ('~/notes', r'$HOME/notes'),
        ('~/notes', '/home/me/notes/'),
        (r'$HOME/notes', '/home/me/notes/'),
      ]) {
        final target = AdHocTarget.parse(pair.$1, pair.$2);
        expect(
          () => EffectiveOptions.forAdHoc(
            target,
            optionsWith(),
            environment: environment,
          ),
          throwsA(isA<CliOptionsError>()),
          reason: '${pair.$1} vs ${pair.$2} should canonicalize the same',
        );
      }
    });

    test('two locations that are merely textually different are not '
        'rejected', () {
      final target = AdHocTarget.parse('~/notes', '~/backup');
      expect(
        () => EffectiveOptions.forAdHoc(
          target,
          optionsWith(),
          environment: environment,
        ),
        returnsNormally,
      );
    });

    group('relative local paths (workingDirectory)', () {
      test('the same relative local path from two different working '
          'directories derives different ids — the exact crossover this '
          'change closes', () {
        final target = AdHocTarget.parse('notes', 'me@phone:/n');

        final proj1 = EffectiveOptions.forAdHoc(
          target,
          optionsWith(),
          workingDirectory: '/home/me/proj1',
        );
        final proj2 = EffectiveOptions.forAdHoc(
          target,
          optionsWith(),
          workingDirectory: '/home/me/proj2',
        );

        expect(proj1.profileId, isNot(proj2.profileId));
      });

      test('a relative local path from a given working directory derives the '
          'same id as its already-absolute spelling', () {
        final relative = AdHocTarget.parse('notes', 'me@phone:/n');
        final absolute = AdHocTarget.parse(
          '/home/me/proj1/notes',
          'me@phone:/n',
        );

        final effectiveRelative = EffectiveOptions.forAdHoc(
          relative,
          optionsWith(),
          workingDirectory: '/home/me/proj1',
        );
        final effectiveAbsolute = EffectiveOptions.forAdHoc(
          absolute,
          optionsWith(),
        );

        expect(effectiveRelative.profileId, effectiveAbsolute.profileId);
      });

      test('a relative remote path is left alone regardless of '
          'workingDirectory — the accepted wart applies on the remote side '
          'only', () {
        final target = AdHocTarget.parse('/home/me/notes', 'me@phone:notes');

        final withCwd = EffectiveOptions.forAdHoc(
          target,
          optionsWith(),
          workingDirectory: '/home/me/proj1',
        );
        final withoutCwd = EffectiveOptions.forAdHoc(target, optionsWith());

        expect(withCwd.profileId, withoutCwd.profileId);
        expect(withCwd.b.path, 'notes');
      });

      test('with no workingDirectory, a relative local path is left '
          'unresolved rather than rejected', () {
        final target = AdHocTarget.parse('notes', 'me@phone:/n');
        expect(
          () => EffectiveOptions.forAdHoc(target, optionsWith()),
          returnsNormally,
        );
      });
    });
  });
}
