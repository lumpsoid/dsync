import 'package:args/command_runner.dart';

import '../options/cli_options.dart';
import '../options/cli_options_error.dart';
import '../options/sync_target.dart';
import 'common_flags.dart';

/// `dsync sync <profile> [flags]` / `dsync sync <locA> <locB> [flags]`
/// (SPEC §11.1).
///
/// [run] only builds a [CliOptions] and stores it on [options] — parsing and
/// validating raw argv is [CliOptions]'s job (and [SyncTarget]'s, for the
/// target half). Actually driving a run from those options is a later
/// task's job; [options] is the seam it hangs off.
class SyncCommand extends Command<void> {
  @override
  final name = 'sync';

  @override
  final description =
      'Sync a profile, or an ad-hoc pair of locations (SPEC §11.1).';

  /// The options built by the most recent [run]. `null` until [run] has
  /// executed at least once without hitting a [CliOptionsError].
  CliOptions? options;

  SyncCommand() {
    addCommonSyncFlags(argParser);
  }

  @override
  Future<void> run() async {
    final results = argResults!;
    try {
      options = CliOptions(
        target: SyncTarget.fromPositionals(results.rest),
        dryRun: results.flag('dry-run'),
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
