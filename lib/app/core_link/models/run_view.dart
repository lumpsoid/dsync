import 'conflict_row.dart';
import 'plan_row.dart';
import 'replica_info.dart';
import 'run_phase.dart';
import 'scan_tally.dart';
import 'skipped_path_info.dart';

/// A run, whole, as the core sends it after every change: what to show,
/// every decision in it already made. Each one stands alone.
final class RunView {
  const RunView({
    required this.dryRun,
    required this.phase,
    required this.connectedAt,
    required this.replicas,
    required this.tallies,
    required this.skipped,
    required this.conflicts,
    required this.plan,
    required this.bytesToTransfer,
    required this.progress,
    required this.applied,
    required this.failed,
    required this.timings,
  });

  final bool dryRun;
  final RunPhase phase;

  /// When both sides connected; `null` before.
  final DateTime? connectedAt;

  /// What each side's `hello` said, once both have.
  final ({ReplicaInfo a, ReplicaInfo b})? replicas;

  /// Both scans' counts, once both are done.
  final ({ScanTally a, ScanTally b})? tallies;

  /// Paths either scan skipped or could not read, side A's first.
  final List<SkippedPathInfo> skipped;

  final List<ConflictRow> conflicts;
  final List<PlanRow> plan;
  final int bytesToTransfer;

  /// The apply's latest progress.
  final ({int completed, int total})? progress;

  /// How many reported outcomes landed, and how many failed.
  final int applied;
  final int failed;

  /// The `--timings` report, once the attempt has ended.
  final String? timings;
}
