import 'package:args/command_runner.dart';

import '../options/cli_options.dart';
import '../options/cli_options_error.dart';
import '../options/sync_target.dart';
import '../run/sync_runner.dart';
import 'common_flags.dart';

/// `dsync status <profile>` (SPEC §11.1) — "`status` is `sync --dry-run`
/// under a friendlier name".
///
/// [run] builds the exact [CliOptions] a `sync --dry-run` invocation for the
/// same profile would, with [CliOptions.dryRun] forced `true`: not a second
/// code path, just a different [Command] wiring the same shared flags
/// (`lib/cli/commands/common_flags.dart`) with one value pinned, then hands
/// it to [runSync] and returns its exit code (SPEC §11.5) as this command's
/// own return value, exactly like `SyncCommand` does — no branch of its own
/// there either. `--dry-run` itself is not among those flags here
/// (`includeDryRun: false`), so passing it to `status` is an unknown-option
/// error rather than an accepted no-op — SPEC §11.1 only documents
/// `status <profile>`, with no `--dry-run` of its own to redundantly set.
///
/// [runSync] is injected the same way and for the same reason as
/// `SyncCommand`'s — see [RunSync]'s doc comment.
class StatusCommand extends Command<int> {
  @override
  final name = 'status';

  @override
  final description = 'Scan, reconcile, and print the plan. Apply nothing.';

  final RunSync runSync;

  StatusCommand({required this.runSync}) {
    addCommonSyncFlags(argParser, includeDryRun: false);
  }

  @override
  Future<int> run() async {
    final results = argResults!;
    final CliOptions options;
    try {
      options = CliOptions(
        target: ProfileTarget.fromStatusPositionals(results.rest),
        dryRun: true,
        batch: results.flag(CommonSyncFlags.flagBatch),
        json: results.flag(CommonSyncFlags.flagJson),
        timings: results.flag(CommonSyncFlags.flagTimings),
        ignore: results.multiOption(CommonSyncFlags.multiOptionIgnore),
        sshOptions: results.multiOption(CommonSyncFlags.multiOptionSshOption),
        remoteCommand: results.option(CommonSyncFlags.optionRemoteDsync),
        verbose: results.flag(CommonSyncFlags.flagVerbose),
        quiet: results.flag(CommonSyncFlags.flagQuiet),
        warnSizeRaw: results.option(CommonSyncFlags.optionWarnSize),
        jobsRaw: results.option(CommonSyncFlags.optionJobs),
        applyConcurrencyRaw: results.option(
          CommonSyncFlags.optionApplyConcurrency,
        ),
      );
    } on CliOptionsError catch (error) {
      usageException(error.message);
    }
    return runSync(options);
  }
}
