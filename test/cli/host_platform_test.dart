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
}
