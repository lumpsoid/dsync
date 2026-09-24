import 'package:args/command_runner.dart';

import '../options/cli_options.dart';
import '../options/cli_options_error.dart';
import '../options/sync_target.dart';
import '../run/sync_runner.dart';
import 'common_flags.dart';

/// `dsync sync <profile> [flags]` / `dsync sync <locA> <locB> [flags]`
/// (SPEC §11.1).
///
/// [run] builds a [CliOptions] — parsing and validating raw argv is
/// [CliOptions]'s job (and [SyncTarget]'s, for the target half) — then hands
/// it to [runSync] and returns its exit code (SPEC §11.5) as this command's
/// own return value: `Command<int>.run()`'s return value is exactly what
/// `CommandRunner<int>.run(argv)` (`DsyncCommandRunner`,
/// `lib/cli/dsync_cli.dart`) hands back to `runDsyncCli`.
///
/// [runSync] is injected as a [RunSync] callback rather than this command
/// importing `SyncRunner` and calling it directly — see [RunSync]'s own doc
/// comment for why. `DsyncCommandRunner` wires in a real `SyncRunner.run`; a
/// parsing-only test hands in a recording fake instead, so it can assert
/// exactly what argv parsed to without driving a real run.
class SyncCommand extends Command<int> {
  @override
  final name = 'sync';

  @override
  final description =
      'Sync a profile, or an ad-hoc pair of locations (SPEC §11.1).';

  final RunSync runSync;

  SyncCommand({required this.runSync}) {
    addCommonSyncFlags(argParser);
  }

  @override
  Future<int> run() async {
    final results = argResults!;
    final CliOptions options;
    try {
      options = CliOptions(
        target: SyncTarget.fromPositionals(results.rest),
        dryRun: results.flag(CommonSyncFlags.flagDryRun),
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
