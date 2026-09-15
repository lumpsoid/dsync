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

  /// `--ssh-option` values, in the order they were given, additive to
  /// whatever a profile's `[ssh.a]`/`[ssh.b]` contributes (SPEC §4.2) — see
  /// [SshAccess.withFlags].
  ///
  /// One list for the run rather than one per side: a replica the flag is
  /// meant for is named right there on the command line, and a run with two
  /// remotes that need *different* options is what a profile is for. The
  /// value that reaches a replica is still per replica — this is folded into
  /// each side's own [SshAccess] by [EffectiveOptions].
  final List<String> sshOptions;

  /// `--remote-dsync`, or `null` when the flag is absent — which is what
  /// lets a profile's own `command` survive a run that does not mention one
  /// (SPEC §12). See [sshOptions] for why it is one value for the run.
  final String? remoteCommand;

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
    this.sshOptions = const [],
    this.remoteCommand,
    required bool verbose,
    required bool quiet,
    String? warnSizeRaw,
    String? jobsRaw,
  }) : verbosity = Verbosity.resolve(verbose: verbose, quiet: quiet),
       warnSizeBytes = _parseWarnSize(warnSizeRaw),
       jobs = _parseJobs(jobsRaw) {
    // An empty string in either would reach ssh as an argv word: an empty
    // option reads as a second destination, an empty command as a remote
    // shell line starting with `agent`. Both fail a long way from the flag
    // that caused them (SPEC §11.5, exit 3 either way), so they are rejected
    // here, where the flag can be named.
    if (sshOptions.any((option) => option.isEmpty)) {
      throw const CliOptionsError('--ssh-option cannot be empty');
    }
    final command = remoteCommand;
    if (command != null && command.isEmpty) {
      throw const CliOptionsError('--remote-dsync cannot be empty');
    }
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
