import 'dart:io';

import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/cli/profile/profile_loader.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Directory profilesDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('profile_loader_test');
    profilesDir = Directory('${tempDir.path}/dsync/profiles');
    await profilesDir.create(recursive: true);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Map<String, String> env() => {'XDG_CONFIG_HOME': tempDir.path};

  Future<void> writeProfile(String name, String contents) async {
    await File('${profilesDir.path}/$name.toml').writeAsString(contents);
  }

  group('loadProfile', () {
    test('loads the worked example from SPEC §12', () async {
      await writeProfile('notes', '''
[replicas]
a = "/home/me/notes"
b = "me@phone:/sdcard/notes"

[rules]
ignore = ["**/.git", "*.tmp", "**/node_modules"]
follow = ["shared"]

[options]
warn_size_bytes = 500_000_000
jobs = 4
''');

      final profile = await loadProfile('notes', environment: env());

      expect(profile.name, 'notes');
      expect(profile.a.path, '/home/me/notes');
      expect(profile.a.host, isNull);
      expect(profile.b.user, 'me');
      expect(profile.b.host, 'phone');
      expect(profile.b.path, '/sdcard/notes');
      expect(profile.rules.ignorePatterns, [
        '**/.git',
        '*.tmp',
        '**/node_modules',
      ]);
      expect(profile.rules.followPatterns, ['shared']);
      // TOML permits underscores in integer literals; this is the literal
      // spelling SPEC §12 uses.
      expect(profile.warnSizeBytes, 500000000);
      expect(profile.jobs, 4);
    });

    test('falls back to ~/.config when XDG_CONFIG_HOME is unset', () async {
      final home = Directory('${tempDir.path}/home');
      final homeProfiles = Directory('${home.path}/.config/dsync/profiles');
      await homeProfiles.create(recursive: true);
      await File('${homeProfiles.path}/notes.toml')
          .writeAsString('[replicas]\na = "/a"\nb = "/b"\n');

      final profile = await loadProfile(
        'notes',
        environment: {'HOME': home.path},
      );

      expect(profile.a.path, '/a');
      expect(profile.b.path, '/b');
    });

    test('[rules] and [options] are optional', () async {
      await writeProfile('minimal', '''
[replicas]
a = "/a"
b = "/b"
''');

      final profile = await loadProfile('minimal', environment: env());

      expect(profile.rules.ignorePatterns, isEmpty);
      expect(profile.rules.followPatterns, isEmpty);
      expect(profile.warnSizeBytes, isNull);
      expect(profile.jobs, isNull);
    });

    test(
      'the order replicas appear in the file has no effect on which is a '
      'and which is b, and a profile may put the remote replica in a',
      () async {
        await writeProfile('remote-first', '''
[replicas]
b = "/local/notes"
a = "me@phone:/sdcard/notes"
''');

        final profile = await loadProfile('remote-first', environment: env());

        expect(profile.a.host, 'phone');
        expect(profile.b.path, '/local/notes');
      },
    );

    test('a missing profile file is fatal', () async {
      expect(
        () => loadProfile('does-not-exist', environment: env()),
        throwsA(isA<ProfileNotFoundException>()),
      );
    });

    test('unparseable TOML is fatal', () async {
      await writeProfile('broken', '[replicas\na = "/a"\n');

      expect(
        () => loadProfile('broken', environment: env()),
        throwsA(isA<ProfileFormatException>()),
      );
    });

    test('a table defined twice is fatal as unparseable TOML', () async {
      await writeProfile('redefined', '''
[replicas]
a = "/a"
b = "/b"

[replicas]
a = "/c"
b = "/d"
''');

      expect(
        () => loadProfile('redefined', environment: env()),
        throwsA(isA<ProfileFormatException>()),
      );
    });

    test('a missing replica is fatal', () async {
      await writeProfile('one-sided', '''
[replicas]
a = "/a"
''');

      expect(
        () => loadProfile('one-sided', environment: env()),
        throwsA(isA<ProfileMissingReplicaException>()),
      );
    });

    test('an absent [replicas] table is fatal as a missing replica', () async {
      await writeProfile('no-replicas', '''
[options]
jobs = 2
''');

      expect(
        () => loadProfile('no-replicas', environment: env()),
        throwsA(isA<ProfileMissingReplicaException>()),
      );
    });

    test('an unknown top-level table is fatal', () async {
      await writeProfile('typo-table', '''
[replicas]
a = "/a"
b = "/b"

[replicaz]
a = "/c"
''');

      expect(
        () => loadProfile('typo-table', environment: env()),
        throwsA(isA<ProfileUnknownKeyException>()),
      );
    });

    test('an unknown key in [replicas] is fatal', () async {
      await writeProfile('typo-replicas', '''
[replicas]
a = "/a"
b = "/b"
c = "/c"
''');

      expect(
        () => loadProfile('typo-replicas', environment: env()),
        throwsA(isA<ProfileUnknownKeyException>()),
      );
    });

    test('an unknown key in [rules] is fatal — this is the case that would '
        'silently stop ignoring **/.git', () async {
      await writeProfile('typo-rules', '''
[replicas]
a = "/a"
b = "/b"

[rules]
ignroe = ["**/.git"]
''');

      expect(
        () => loadProfile('typo-rules', environment: env()),
        throwsA(isA<ProfileUnknownKeyException>()),
      );
    });

    test('an unknown key in [options] is fatal', () async {
      await writeProfile('typo-options', '''
[replicas]
a = "/a"
b = "/b"

[options]
wrn_size_bytes = 100
''');

      expect(
        () => loadProfile('typo-options', environment: env()),
        throwsA(isA<ProfileUnknownKeyException>()),
      );
    });
  });

  group('resolveProfilePath', () {
    test('uses XDG_CONFIG_HOME when set', () {
      final path = resolveProfilePath(
        'notes',
        environment: {'XDG_CONFIG_HOME': '/xdg'},
      );
      expect(path.path, '/xdg/dsync/profiles/notes.toml');
    });

    test('falls back to HOME/.config when XDG_CONFIG_HOME is unset', () {
      final path = resolveProfilePath(
        'notes',
        environment: {'HOME': '/home/me'},
      );
      expect(path.path, '/home/me/.config/dsync/profiles/notes.toml');
    });

    test('throws when neither is set', () {
      expect(
        () => resolveProfilePath('notes', environment: const {}),
        throwsStateError,
      );
    });
  });

  group('Location integration', () {
    test('replicas parse through Location.parse', () async {
      await writeProfile('loc', '''
[replicas]
a = "notes"
b = "host:/remote/notes"
''');

      final profile = await loadProfile('loc', environment: env());

      expect(profile.a, isA<Location>());
      expect(profile.a.path, 'notes');
      expect(profile.b.host, 'host');
    });
  });
}
