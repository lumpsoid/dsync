import 'package:dsync/cli/dsync_cli.dart';
import 'package:test/test.dart';

/// End-to-end coverage of task 867af9 through the real entry point
/// (`runDsyncCli`, `DsyncCommandRunner`), complementing the
/// `SyncCommand`/`StatusCommand`-level tests in `test/cli/commands/` which
/// assert on the parsed `CliOptions` itself. These only assert on the exit
/// code (SPEC §11.5), since that is all `runDsyncCli` exposes.
void main() {
  group('sync/status exit codes (SPEC §11.5)', () {
    test('sync <profile> with no flags exits 0', () async {
      expect(await runDsyncCli(['sync', 'work']), 0);
    });

    test('sync <locA> <locB>, both local, exits 0', () async {
      expect(await runDsyncCli(['sync', '~/notes', '~/backup']), 0);
    });

    test('status <profile> exits 0', () async {
      expect(await runDsyncCli(['status', 'work']), 0);
    });

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
