import 'dart:async';

import 'package:dsync/cli/dsync_cli.dart';
import 'package:test/test.dart';

/// Runs [body] with `print` captured instead of going to real stdout, and
/// returns every printed line. Used below so assertions on `--help` output
/// don't depend on inspecting the process's actual stdout stream.
Future<List<String>> _capturePrint(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );
  return lines;
}

void main() {
  group('runDsyncCli', () {
    test('--help exits 0 and prints usage', () async {
      late final int exitCode;
      final lines = await _capturePrint(() async {
        exitCode = await runDsyncCli(['--help']);
      });

      expect(exitCode, 0);
      expect(lines.join('\n'), contains('Usage: dsync <command>'));
    });

    test(
      'no arguments behaves like --help (SPEC §11.1 has no bare form)',
      () async {
        late final int exitCode;
        final lines = await _capturePrint(() async {
          exitCode = await runDsyncCli([]);
        });

        expect(exitCode, 0);
        expect(lines.join('\n'), contains('Usage: dsync <command>'));
      },
    );

    test(
      'an unknown command exits 3 with a clear error (SPEC §11.5)',
      () async {
        final exitCode = await runDsyncCli(['frobnicate']);
        expect(exitCode, 3);
      },
    );

    test(
      'a real command is reported as unknown until its task lands',
      () async {
        // SPEC §11.1 names sync/status/agent, but none is registered yet
        // (this task's scope stops at --help and the unknown-command path).
        final exitCode = await runDsyncCli(['sync', 'profile-name']);
        expect(exitCode, 3);
      },
    );
  });
}
