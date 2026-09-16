import 'dart:io';

import 'package:dsync/cli/host_platform.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('HostPlatform cases (SPEC §3, §7.4, §8.3)', () {
    test('LinuxHost — POSIX paths, LinuxStateDir, chmod available', () {
      const host = LinuxHost();

      expect(host.pathStyle, p.Style.posix);
      expect(host.isWindowsReplica, isFalse);
      expect(host.stateDirPlatform, isA<LinuxStateDir>());
    });

    test('MacOsHost — POSIX paths, MacOsStateDir, chmod available', () {
      const host = MacOsHost();

      expect(host.pathStyle, p.Style.posix);
      expect(host.isWindowsReplica, isFalse);
      expect(host.stateDirPlatform, isA<MacOsStateDir>());
    });

    test('WindowsHost — Windows paths, WindowsStateDir, no chmod', () {
      const host = WindowsHost();

      expect(host.pathStyle, p.Style.windows);
      expect(host.isWindowsReplica, isTrue);
      expect(host.stateDirPlatform, isA<WindowsStateDir>());
    });

    test('the three CLI cases exhaust the sum type — a Windows state '
        'directory alongside a POSIX path style is unrepresentable, not '
        'merely undocumented (see [HostPlatform] doc comment)', () {
      // Compile-time proof by exhaustive switch: every subclass of
      // [HostPlatform] is one of these three, so any code that switches
      // over the sealed type is checked to cover them all — no fourth case
      // can be constructed with mismatched properties.
      HostPlatform host = const LinuxHost();
      final label = switch (host) {
        LinuxHost() => 'linux',
        MacOsHost() => 'macos',
        WindowsHost() => 'windows',
      };
      expect(label, 'linux');
    });
  });

  group('hostPlatformFor — every v1 target, from a plain string (SPEC §3)', () {
    test('linux', () {
      expect(hostPlatformFor('linux'), isA<LinuxHost>());
    });

    test('macos', () {
      expect(hostPlatformFor('macos'), isA<MacOsHost>());
    });

    test('windows', () {
      expect(hostPlatformFor('windows'), isA<WindowsHost>());
    });

    test('android maps to the Linux case — Termux sets HOME the same way a '
        'desktop Linux session does, and shares its path style and chmod', () {
      expect(hostPlatformFor('android'), isA<LinuxHost>());
    });

    test('ios throws rather than picking a branch: it has no CLI head at all, '
        'so reaching here means that constraint stopped holding', () {
      expect(() => hostPlatformFor('ios'), throwsA(isA<StateError>()));
    });

    test('an unknown platform throws, naming the five v1 targets', () {
      expect(
        () => hostPlatformFor('fuchsia'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('five v1 targets'),
          ),
        ),
      );
    });
  });

  group('detectsCaseFolding (SPEC §3, §16, task c51db6)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('host_platform_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('answers for this host\'s real filesystem: folding on macOS and '
        'Windows, whose default volumes (APFS, NTFS) are case-insensitive, '
        'and none on Linux — the one probe against a real, unfaked directory '
        'CI runs on all three (SPEC §3)', () {
      expect(
        detectsCaseFolding(tempDir.path),
        Platform.isMacOS || Platform.isWindows,
      );
    });

    test('leaves no marker file behind, whichever answer it found', () {
      detectsCaseFolding(tempDir.path);

      expect(tempDir.listSync(), isEmpty);
    });

    test('false, not a thrown exception, for a root that does not exist — '
        'a probe failure answers the question it can, rather than failing '
        'a caller that only wanted a yes/no', () {
      expect(detectsCaseFolding('${tempDir.path}/does-not-exist'), isFalse);
    });
  });

  group('caseFoldKeyFor (SPEC §16, task c51db6)', () {
    test('null when the replica does not fold case, so Scanner skips the '
        'collision check entirely rather than computing a no-op key', () {
      expect(caseFoldKeyFor(false), isNull);
    });

    test('a lowercasing transform when it does, which is what "folds case" '
        'means for the one transform v1 implements', () {
      final foldKey = caseFoldKeyFor(true);

      expect(foldKey, isNotNull);
      expect(foldKey!('Notes.txt'), foldKey('notes.txt'));
      expect(foldKey('Notes.txt'), 'notes.txt');
    });
  });
}
