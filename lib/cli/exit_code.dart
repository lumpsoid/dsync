import 'package:dsync/dsync_core/models/run_event.dart';

/// One `RunController` run, reduced to nothing more than SPEC §11.5 needs to
/// pick an exit code: whether a [RunSummaryEvent] was seen and whether a
/// [RunErrorEvent] was seen. A run emits at most one of each — [RunErrorEvent]
/// is documented as "always the last event on the stream; nothing follows
/// it" — but this type does not assume that; [exitCode] resolves every
/// combination explicitly, including the two a well-behaved run never
/// produces (both present, or neither).
///
/// The caller (a later wiring task) tracks these two fields while consuming
/// the event stream — plain assignment, no branching — then builds one
/// [RunOutcome] and reads [exitCode] once, after the loop ends.
class RunOutcome {
  final RunSummaryEvent? summary;
  final RunErrorEvent? error;

  const RunOutcome({this.summary, this.error});

  /// SPEC §11.5's four-level scheme, mirroring Unison:
  /// ```
  /// 0  all planned actions applied, no conflicts
  /// 1  completed, but some paths were skipped or are unresolved conflicts
  /// 2  completed, but some actions failed
  /// 3  fatal: bad arguments, cannot reach a replica, lock held, archive
  ///    unreadable, protocol version mismatch
  /// ```
  /// "When both 1 and 2 apply, 2 wins" — checked in that order below.
  ///
  /// [error] always wins outright: a run that reported a [RunErrorEvent]
  /// ended before it could be trusted to finish, whatever a stray [summary]
  /// might say. No [summary] at all — a fatal thrown before one could be
  /// built — maps here too, which is exactly the "no summary and no error"
  /// case a caller gets from a crash that didn't even produce a
  /// [RunErrorEvent].
  ///
  /// task cb7abd, DECIDED: `status` and `--dry-run` get no special case
  /// here. A dry run proposes actions and applies none, so every proposed
  /// action reaches [RunSummaryEvent.skippedCount] and this function falls
  /// straight into the exit-1 branch when there's pending work — which is
  /// the whole point of running `dsync status` from a cron job or a shell
  /// prompt.
  int get exitCode {
    final summary = this.summary;
    if (error != null || summary == null) return 3;
    if (summary.failedCount > 0) return 2;
    if (summary.skippedCount > 0 || summary.conflictCount > 0) return 1;
    return 0;
  }
}
