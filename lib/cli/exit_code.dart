import 'package:dsync/dsync_core/models/run_event.dart';

/// SPEC §11.5: 128 + signal number — the exit code for a run [RunOutcome]
/// reports as [RunOutcome.interrupted], deliberately outside the 0-3 scheme
/// below (task fc661b, DECIDED). 128+N is what every shell and CI system
/// already reads as "killed by signal N", and folding an interrupt into exit
/// 3 would have retry logic retrying a run the user asked to stop — 1 and 2
/// both assert "completed, but ..." and an interrupted run did not complete.
///
/// SIGTERM's own 143 needs no constant or code here: this process never
/// traps SIGTERM (task fc661b scopes the new handling to SIGINT only), so
/// the kernel's default disposition kills it, and 128+15 is already what a
/// shell reports for that on its own.
const sigintExitCode = 130;

/// One `RunController` run, reduced to nothing more than SPEC §11.5 needs to
/// pick an exit code: whether a [RunSummaryEvent] was seen, whether a
/// [RunErrorEvent] was seen, and whether the run was interrupted by SIGINT
/// (task fc661b). A run emits at most one of each of [summary]/[error] —
/// [RunErrorEvent] is documented as "always the last event on the stream;
/// nothing follows it" — but this type does not assume that; [exitCode]
/// resolves every combination explicitly, including the two a well-behaved
/// run never produces (both present, or neither).
///
/// The caller (`SyncRunner.run`) tracks these fields while consuming the
/// event stream — plain assignment, no branching — then builds one
/// [RunOutcome] and reads [exitCode] once, after the loop ends.
class RunOutcome {
  final RunSummaryEvent? summary;
  final RunErrorEvent? error;

  /// Whether a SIGINT was received at any point during this run (task
  /// fc661b, DECIDED) — threaded in by the caller rather than derived from
  /// [summary]/[error], since a run that happened to finish applying before
  /// the interrupt took effect still counts: the signal is what the user
  /// asked for, whatever the run itself went on to report.
  final bool interrupted;

  const RunOutcome({this.summary, this.error, this.interrupted = false});

  /// SPEC §11.5's scheme, mirroring Unison, plus task fc661b's DECIDED
  /// addition:
  /// ```
  /// 0    all planned actions applied, no conflicts
  /// 1    completed, but some paths were skipped or are unresolved conflicts
  /// 2    completed, but some actions failed
  /// 3    fatal: bad arguments, cannot reach a replica, lock held, archive
  ///      unreadable, protocol version mismatch
  /// 130  interrupted by SIGINT (128 + 2)
  /// ```
  /// "When both 1 and 2 apply, 2 wins" — checked in that order below.
  ///
  /// [interrupted] wins outright, ahead of even [error]: it says what the
  /// *user* did, not what the run did, so it is not one more outcome to rank
  /// against the other three — it pre-empts them. [error] wins next: a run
  /// that reported a [RunErrorEvent] ended before it could be trusted to
  /// finish, whatever a stray [summary] might say. No [summary] at all — a
  /// fatal thrown before one could be built — maps here too, which is
  /// exactly the "no summary and no error" case a caller gets from a crash
  /// that didn't even produce a [RunErrorEvent].
  ///
  /// task 37bf4f: a path either scan could not read joins the exit-1 branch,
  /// not exit 2 or 3. Exit 2 is for an *action* that failed, and an
  /// unreadable path never became one; exit 3 says the run could not be
  /// trusted to finish, and it did — everything else synced. What is left is
  /// exactly §11.5's exit 1, "completed, but some paths were skipped".
  ///
  /// task cb7abd, DECIDED: `status` and `--dry-run` get no special case
  /// here. A dry run proposes actions and applies none, so every proposed
  /// action reaches [RunSummaryEvent.skippedCount] and this function falls
  /// straight into the exit-1 branch when there's pending work — which is
  /// the whole point of running `dsync status` from a cron job or a shell
  /// prompt.
  int get exitCode {
    if (interrupted) return sigintExitCode;
    final summary = this.summary;
    if (error != null || summary == null) return 3;
    if (summary.failedCount > 0) return 2;
    if (summary.skippedCount > 0 ||
        summary.conflictCount > 0 ||
        summary.unreadableCount > 0) {
      return 1;
    }
    return 0;
  }
}
