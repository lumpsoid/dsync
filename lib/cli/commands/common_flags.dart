import 'package:args/args.dart';

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
      'dry-run',
      negatable: false,
      help: 'Show the plan, apply nothing.',
    );
  }
  parser
    ..addFlag(
      'batch',
      negatable: false,
      help:
          'Apply non-conflicting actions without asking; '
          'conflicts are listed, not resolved.',
    )
    ..addFlag(
      'json',
      negatable: false,
      help: 'Machine-readable output (JSON Lines) on stdout.',
    )
    ..addMultiOption(
      'ignore',
      help: 'Glob to ignore, additive to the profile. Repeatable.',
    )
    ..addOption('warn-size', help: 'Size in bytes to warn above.')
    ..addOption('jobs', help: 'Hash parallelism.')
    ..addFlag('verbose', negatable: false, help: 'Print more detail.')
    ..addFlag(
      'quiet',
      negatable: false,
      help: 'Print only the summary line and errors.',
    );
}
