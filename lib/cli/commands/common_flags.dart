import 'package:args/args.dart';

/// Names for the SPEC §11.2 flags [addCommonSyncFlags] registers.
///
/// `SyncCommand` and `StatusCommand` both read these, so they are named here,
/// next to the function that registers them, rather than on either command —
/// a rename only has to happen in one place, and a typo in a read site is
/// not a compile error, since [ArgResults.flag]/`.option`/`.multiOption` look
/// up by string (task 4fce5d).
class CommonSyncFlags {
  static const flagDryRun = 'dry-run';
  static const flagBatch = 'batch';
  static const flagJson = 'json';
  static const multiOptionIgnore = 'ignore';
  static const optionWarnSize = 'warn-size';
  static const optionJobs = 'jobs';
  static const multiOptionSshOption = 'ssh-option';
  static const optionRemoteDsync = 'remote-dsync';
  static const flagTimings = 'timings';
  static const flagVerbose = 'verbose';
  static const flagQuiet = 'quiet';
}

/// Registers the SPEC §11.2 flags shared by `sync` and `status` on [parser].
///
/// `--dry-run` is opt-out via [includeDryRun]. `status` already forces
/// dry-run behaviour (SPEC §11.1: "`status` is `sync --dry-run` under a
/// friendlier name") and does not register the flag itself, so passing it
/// to `status` is reported as an unknown option rather than accepted as a
/// redundant no-op.
///
/// Registering flags is data, not a decision — the actual cross-flag rules
/// (`--verbose` with `--quiet`, `--batch` with `--dry-run`, …) live in
/// `CliOptions`'s constructor (`lib/cli/options/cli_options.dart`), not here.
void addCommonSyncFlags(ArgParser parser, {bool includeDryRun = true}) {
  if (includeDryRun) {
    parser.addFlag(
      CommonSyncFlags.flagDryRun,
      negatable: false,
      help: 'Show the plan, apply nothing.',
    );
  }
  parser
    ..addFlag(
      CommonSyncFlags.flagBatch,
      negatable: false,
      help:
          'Apply non-conflicting actions without asking; '
          'conflicts are listed, not resolved.',
    )
    ..addFlag(
      CommonSyncFlags.flagJson,
      negatable: false,
      help: 'Machine-readable output (JSON Lines) on stdout.',
    )
    ..addMultiOption(
      CommonSyncFlags.multiOptionIgnore,
      help: 'Glob to ignore, additive to the profile. Repeatable.',
    )
    ..addOption(
      CommonSyncFlags.optionWarnSize,
      help: 'Size in bytes to warn above.',
    )
    ..addOption(CommonSyncFlags.optionJobs, help: 'Hash parallelism.')
    ..addMultiOption(
      CommonSyncFlags.multiOptionSshOption,
      help:
          'One option for ssh itself, before the destination, e.g. '
          '--ssh-option=-p --ssh-option=2222. Repeatable — one argv word '
          'each, since an option value may contain spaces. Additive to the '
          "profile's [ssh.a]/[ssh.b]; applies to every remote replica of "
          'this run.',
    )
    ..addOption(
      CommonSyncFlags.optionRemoteDsync,
      help:
          'The command that starts the agent on the far side. Default: '
          '"dsync", resolved on the remote non-interactive PATH. Applies to '
          'every remote replica of this run.',
    )
    ..addFlag(
      CommonSyncFlags.flagTimings,
      negatable: false,
      help:
          'Print where the run spent its time, and what it asked of each '
          'replica, after the summary (SPEC §17).',
    )
    ..addFlag(
      CommonSyncFlags.flagVerbose,
      negatable: false,
      help: 'Print more detail.',
    )
    ..addFlag(
      CommonSyncFlags.flagQuiet,
      negatable: false,
      help: 'Print only the summary line and errors.',
    );
}
