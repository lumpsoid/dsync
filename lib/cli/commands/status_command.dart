import 'package:args/command_runner.dart';

import '../options/cli_options.dart';
import '../options/cli_options_error.dart';
import '../options/sync_target.dart';
import 'common_flags.dart';

/// `dsync status <profile>` (SPEC §11.1) — "`status` is `sync --dry-run`
/// under a friendlier name".
///
/// [run] builds the exact [CliOptions] a `sync --dry-run` invocation for the
/// same profile would, with [CliOptions.dryRun] forced `true`: not a second
/// code path, just a different [Command] wiring the same shared flags
/// (`lib/cli/commands/common_flags.dart`) with one value pinned. `--dry-run`
/// itself is not among those flags here (`includeDryRun: false`), so passing
/// it to `status` is an unknown-option error rather than an accepted no-op —
/// SPEC §11.1 only documents `status <profile>`, with no `--dry-run` of its
/// own to redundantly set.
class StatusCommand extends Command<void> {
  @override
  final name = 'status';

  @override
  final description = 'Scan, reconcile, and print the plan. Apply nothing.';

  /// The options built by the most recent [run]. `null` until [run] has
  /// executed at least once without hitting a `CliOptionsError`.
  CliOptions? options;

  StatusCommand() {
    addCommonSyncFlags(argParser, includeDryRun: false);
  }

  @override
  Future<void> run() async {
    final results = argResults!;
    try {
      options = CliOptions(
        target: ProfileTarget.fromStatusPositionals(results.rest),
        dryRun: true,
        batch: results.flag('batch'),
        json: results.flag('json'),
        ignore: results.multiOption('ignore'),
        verbose: results.flag('verbose'),
        quiet: results.flag('quiet'),
        warnSizeRaw: results.option('warn-size'),
        jobsRaw: results.option('jobs'),
      );
    } on CliOptionsError catch (error) {
      usageException(error.message);
    }
  }
}
