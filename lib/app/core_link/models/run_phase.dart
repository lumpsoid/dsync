import 'decision_summary.dart';
import 'entry_issue.dart';
import 'mass_delete_side.dart';
import 'mass_overwrite_side.dart';
import 'run_summary_info.dart';

/// Where a run stands, as the core decided it.
sealed class RunPhase {
  const RunPhase();
}

final class RunConnecting extends RunPhase {
  const RunConnecting();
}

/// A peer:// link dropped and is being re-dialled: the [attempt] just made
/// (from 1), and the backoff in milliseconds before the next dial.
final class RunReconnecting extends RunPhase {
  const RunReconnecting({required this.attempt, required this.nextInMs});

  final int attempt;
  final int nextInMs;
}

/// Scanning and reconciling; a dry run stays here until it ends.
final class RunScanning extends RunPhase {
  const RunScanning();
}

/// The plan waits on the review; [summary] is the running total.
final class RunReviewing extends RunPhase {
  const RunReviewing(this.summary);

  final DecisionSummary summary;
}

/// SPEC §10's delete guard waits on an answer: one entry per side it
/// tripped on.
final class RunConfirmingDeletes extends RunPhase {
  const RunConfirmingDeletes(this.sides);

  final List<MassDeleteSide> sides;
}

/// SPEC §10's overwrite guard waits on an answer: one entry per side it
/// tripped on.
final class RunConfirmingOverwrites extends RunPhase {
  const RunConfirmingOverwrites(this.sides);

  final List<MassOverwriteSide> sides;
}

final class RunApplying extends RunPhase {
  const RunApplying();
}

final class RunFinished extends RunPhase {
  const RunFinished(this.summary);

  final RunSummaryInfo summary;
}

/// Stopped by the user after [completed] actions. Over.
final class RunStopped extends RunPhase {
  const RunStopped(this.completed);

  final int completed;
}

/// Suspended because the app went to the background, after [completed]
/// actions; coming back runs it again.
final class RunPaused extends RunPhase {
  const RunPaused(this.completed);

  final int completed;
}

final class RunFailed extends RunPhase {
  const RunFailed(this.message);

  final String message;
}

/// SPEC §4.3's held lock: [message] is the core's line naming it.
final class RunReplicaBusy extends RunPhase {
  const RunReplicaBusy(this.message);

  final String message;
}

/// The user declined the deletions the guard asked about: nothing was
/// applied.
final class RunDeletesDeclined extends RunPhase {
  const RunDeletesDeclined();
}

/// The user declined the overwrites the guard asked about: nothing was
/// applied.
final class RunOverwritesDeclined extends RunPhase {
  const RunOverwritesDeclined();
}

/// The run ended without a summary, and nobody stopped it.
final class RunNoSummary extends RunPhase {
  const RunNoSummary();
}

/// A profile of several entries ran to its end and [entries] did not
/// sync; the rest did. A resume runs every entry again.
final class RunFinishedWithIssues extends RunPhase {
  const RunFinishedWithIssues(this.entries);

  final List<EntryIssue> entries;
}
