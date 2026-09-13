import 'cli_options_error.dart';

/// How much a head prints during a run (SPEC §11.4), derived from
/// `--verbose` / `--quiet` (SPEC §11.2).
///
/// A three-value enum instead of two independent bools: `verbose` and
/// `quiet` set together is exactly the kind of invalid state this project's
/// code principles say to make unrepresentable, and [resolve] is where that
/// combination is rejected — once, so nothing downstream has to notice a
/// bool pair disagreeing. Rendering per level is a later task (e9b4b6); this
/// enum only names the three levels it will render:
///
/// - [quiet] — summary line and errors only.
/// - [normal] — run header, plan table, conflicts, skipped-symlink notes,
///   progress, summary.
/// - [verbose] — everything [normal] shows, plus more detail.
enum Verbosity {
  quiet,
  normal,
  verbose;

  /// Resolves the two CLI flags to one [Verbosity].
  ///
  /// Throws [CliOptionsError] when both are set (SPEC §11.5): there is no
  /// sensible combined meaning, so this is rejected rather than picking
  /// one silently.
  static Verbosity resolve({required bool verbose, required bool quiet}) {
    if (verbose && quiet) {
      throw const CliOptionsError('cannot combine --verbose and --quiet');
    }
    if (verbose) return Verbosity.verbose;
    if (quiet) return Verbosity.quiet;
    return Verbosity.normal;
  }
}
