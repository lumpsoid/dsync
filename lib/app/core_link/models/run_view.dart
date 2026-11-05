import 'entry_run.dart';
import 'replica_info.dart';
import 'run_phase.dart';
import 'run_plan_update.dart';
import 'run_standing.dart';
import 'scan_tally.dart';
import 'skipped_path_info.dart';
import 'sync_history.dart';

/// A run as the core sends it after every change: what to show, every
/// decision in it already made. Whole but for its [plan], which comes
/// whole once and then as the rows that changed since the view before.
///
/// A session runs a profile's [entries] in turn; everything from
/// [connectedAt] on describes the [current] one alone.
final class RunView {
  const RunView({
    required this.dryRun,
    required this.phase,
    required this.standing,
    required this.entries,
    required this.current,
    required this.connectedAt,
    required this.replicas,
    required this.tallies,
    required this.skipped,
    required this.plan,
    required this.progress,
    required this.applied,
    required this.failed,
    required this.timings,
  });

  final bool dryRun;
  final RunPhase phase;
  final RunStanding standing;

  /// The profile's entries, in the order they run; empty until the target
  /// resolves.
  final List<EntryRun> entries;

  /// Which of [entries] the plan and tallies describe; `null` before the
  /// first starts.
  final int? current;

  /// When both sides connected; `null` before.
  final DateTime? connectedAt;

  /// What each side's `hello` said, and the pair's history, once both
  /// have.
  final ({ReplicaInfo a, ReplicaInfo b, SyncHistory history})? replicas;

  /// Both scans' counts, and every path either checked and found changed,
  /// once both are done.
  final ({ScanTally a, ScanTally b, int checked, int changed})? tallies;

  /// Paths either scan skipped or could not read, side A's first.
  final List<SkippedPathInfo> skipped;

  /// The entry's plan, if it has one yet.
  final RunPlanUpdate plan;

  /// The apply's latest progress. `received` is `completed` plus the
  /// staged copies whose results are not yet in: ahead of it while a
  /// destination's landings lag, equal otherwise.
  final ({int completed, int received, int total})? progress;

  /// How many reported outcomes landed, and how many failed.
  final int applied;
  final int failed;

  /// The `--timings` report, once the attempt has ended.
  final String? timings;
}
