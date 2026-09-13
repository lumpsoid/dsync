import 'cli_options_error.dart';
import 'sync_target.dart';
import 'verbosity.dart';

/// Parsed and validated options for one `sync` or `status` invocation (SPEC
/// §11.1, §11.2).
///
/// Every fatal argument-combination rule SPEC §11.5 lists is checked once,
/// here, at construction — not in `lib/cli/commands/`. A `Command` gathers
/// raw `ArgResults` values and calls this constructor; on [CliOptionsError]
/// it turns the message into a `UsageException` via `Command.usageException`,
/// which `runDsyncCli` already maps to exit code 3. That keeps every
/// `Command.run()` body a thin, unconditional translator, and makes an
/// invalid combination impossible to construct, let alone act on.
///
/// `status` is `sync --dry-run` under a friendlier name (SPEC §11.1): its
/// `Command` builds this same class with [dryRun] forced to `true` rather
/// than following a second code path. The `--batch` + `--dry-run` rule below
/// then also rejects `--batch` + `status` for free, with no extra case.
class CliOptions {
  final SyncTarget target;
  final bool dryRun;
  final bool batch;
  final bool json;

  /// `--ignore` globs, additive to whatever a loaded profile contributes
  /// (SPEC §9) — merging the two is task 603ea7's job, not this one's.
  final List<String> ignore;

  final int? warnSizeBytes;
  final int? jobs;
  final Verbosity verbosity;

  /// Builds and validates in one step.
  ///
  /// [warnSizeRaw] and [jobsRaw] are the unparsed `--warn-size`/`--jobs`
  /// option strings (or `null` if absent) rather than already-parsed ints,
  /// so the "non-integer or negative" / "zero or negative" checks live here
  /// too, next to every other rule about this invocation, instead of being
  /// split across a `Command` and this constructor.
  CliOptions({
    required this.target,
    required this.dryRun,
    required this.batch,
    required this.json,
    this.ignore = const [],
    required bool verbose,
    required bool quiet,
    String? warnSizeRaw,
    String? jobsRaw,
  }) : verbosity = Verbosity.resolve(verbose: verbose, quiet: quiet),
       warnSizeBytes = _parseWarnSize(warnSizeRaw),
       jobs = _parseJobs(jobsRaw) {
    if (batch && dryRun) {
      throw const CliOptionsError(
        '--batch cannot be combined with --dry-run (or with status, which '
        'forces --dry-run)',
      );
    }
    if (json && !(batch || dryRun)) {
      throw const CliOptionsError('--json requires --batch or --dry-run');
    }
  }

  static int? _parseWarnSize(String? raw) {
    if (raw == null) return null;
    final value = int.tryParse(raw);
    if (value == null || value < 0) {
      throw CliOptionsError(
        '--warn-size must be a non-negative integer, got "$raw"',
      );
    }
    return value;
  }

  static int? _parseJobs(String? raw) {
    if (raw == null) return null;
    final value = int.tryParse(raw);
    if (value == null || value <= 0) {
      throw CliOptionsError('--jobs must be a positive integer, got "$raw"');
    }
    return value;
  }
}
