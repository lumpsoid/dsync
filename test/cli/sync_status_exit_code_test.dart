import 'dart:io';

import 'package:dsync/cli/dsync_cli.dart';
import 'package:test/test.dart';

/// End-to-end coverage of task 867af9 through the real entry point
/// (`runDsyncCli`, `DsyncCommandRunner`), complementing the
/// `SyncCommand`/`StatusCommand`-level tests in `test/cli/commands/` which
/// assert on the parsed `CliOptions` itself. These only assert on the exit
/// code (SPEC §11.5), since that is all `runDsyncCli` exposes.
void main() {
  group('sync/status exit codes (SPEC §11.5)', () {
    late Directory tempDir;
    late Map<String, String> unresolvableEnvironment;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_exit_code_test_');
      // No "work" profile, and no "notes"/"backup" directory, exists
      // anywhere under here — used below by the three tests that now drive
      // a real run (task ee190c's predecessor wired `sync`/`status` up to
      // actually do something) rather than a `CliOptions`-only rejection,
      // so their fatal outcome is deterministic regardless of what the
      // machine running this suite happens to have under its own real
      // $HOME/$XDG_CONFIG_HOME.
      unresolvableEnvironment = {
        'HOME': tempDir.path,
        'XDG_CONFIG_HOME': '${tempDir.path}/config',
        'XDG_STATE_HOME': '${tempDir.path}/state',
      };
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    // These three used to assert exit 0 back when `sync`/`status` only
    // parsed their flags and did nothing (this file predates task ee190c's
    // predecessor, which wired `SyncRunner` up to actually run them). A
    // profile named "work", or replicas at "~/notes"/"~/backup", are exactly
    // the kind of thing a real invocation needs and this suite must not
    // depend on — so what they now assert is the real, equally deterministic
    // outcome: neither exists, so each is fatal (SPEC §11.5, exit 3), not a
    // usage error.
    test(
      'sync <profile> against a profile that does not exist exits 3',
      () async {
        expect(
          await runDsyncCli([
            'sync',
            'work',
          ], environment: unresolvableEnvironment),
          3,
        );
      },
    );

    test(
      'sync <locA> <locB>, both local, but neither replica exists, exits 3',
      () async {
        expect(
          await runDsyncCli([
            'sync',
            '~/notes',
            '~/backup',
          ], environment: unresolvableEnvironment),
          3,
        );
      },
    );

    test(
      'status <profile> against a profile that does not exist exits 3',
      () async {
        expect(
          await runDsyncCli([
            'status',
            'work',
          ], environment: unresolvableEnvironment),
          3,
        );
      },
    );

    test(
      'a remote-first mixed ad-hoc pair exits 3 — DECIDED "local first"',
      () async {
        expect(
          await runDsyncCli(['sync', 'me@phone:/sdcard/notes', '~/notes']),
          3,
        );
      },
    );

    test('--verbose with --quiet exits 3', () async {
      expect(await runDsyncCli(['sync', 'work', '--verbose', '--quiet']), 3);
    });

    test('--json without --batch or --dry-run exits 3', () async {
      expect(await runDsyncCli(['sync', 'work', '--json']), 3);
    });

    test('--batch with --dry-run exits 3', () async {
      expect(await runDsyncCli(['sync', 'work', '--batch', '--dry-run']), 3);
    });

    test('--batch with status exits 3', () async {
      expect(await runDsyncCli(['status', 'work', '--batch']), 3);
    });

    test('sync with three positionals exits 3', () async {
      expect(await runDsyncCli(['sync', 'a', 'b', 'c']), 3);
    });

    test('sync <locA> <locB> that are the same location exits 3', () async {
      expect(await runDsyncCli(['sync', '~/notes', '~/notes']), 3);
    });

    test('--jobs 0 exits 3', () async {
      expect(await runDsyncCli(['sync', 'work', '--jobs', '0']), 3);
    });

    test('--warn-size negative exits 3', () async {
      expect(await runDsyncCli(['sync', 'work', '--warn-size', '-1']), 3);
    });
  });
}
