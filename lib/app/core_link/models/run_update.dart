import 'action_result.dart';
import 'conflict_info.dart';
import 'peer_contact.dart';
import 'plan_action.dart';
import 'replica_info.dart';
import 'run_end.dart';
import 'run_error_info.dart';
import 'run_summary_info.dart';
import 'scan_tally.dart';
import 'skipped_path_info.dart';

/// One step of a run, in the run's order (SPEC §11.4).
sealed class RunUpdate {
  const RunUpdate();
}

/// Both sides are connected; what dialling each `peer://` side learned.
final class RunConnected extends RunUpdate {
  const RunConnected(this.peers);

  final List<PeerContact> peers;
}

final class RunReplicas extends RunUpdate {
  const RunReplicas({
    required this.a,
    required this.b,
    required this.lastRunUnfinished,
  });

  final ReplicaInfo a;
  final ReplicaInfo b;
  final bool lastRunUnfinished;
}

final class RunScanTally extends RunUpdate {
  const RunScanTally({required this.a, required this.b});

  final ScanTally a;
  final ScanTally b;
}

final class RunSkipped extends RunUpdate {
  const RunSkipped(this.skipped);

  final SkippedPathInfo skipped;
}

final class RunConflict extends RunUpdate {
  const RunConflict(this.conflict);

  final ConflictInfo conflict;
}

/// The plan. [awaitingDecision]: the run now waits for
/// `CoreLink.decideRun` (a dry run does not).
final class RunPlan extends RunUpdate {
  const RunPlan({
    required this.actions,
    required this.conflicts,
    required this.bytesToTransfer,
    required this.exceedsWarnSize,
    required this.awaitingDecision,
  });

  final List<PlanAction> actions;
  final List<ConflictInfo> conflicts;
  final int bytesToTransfer;
  final bool exceedsWarnSize;
  final bool awaitingDecision;
}

/// Approved actions, outcomes and progress since the last batch: at most
/// one of these per 50 ms.
final class RunApplied extends RunUpdate {
  const RunApplied({
    required this.approved,
    required this.results,
    required this.progress,
  });

  final List<PlanAction> approved;
  final List<ActionResult> results;
  final ({int completed, int total})? progress;
}

final class RunSummarized extends RunUpdate {
  const RunSummarized(this.summary);

  final RunSummaryInfo summary;
}

final class RunFailed extends RunUpdate {
  const RunFailed(this.error);

  final RunErrorInfo error;
}

/// The last update of a run's stream.
final class RunEnded extends RunUpdate {
  const RunEnded(this.end);

  final RunEnd end;
}
