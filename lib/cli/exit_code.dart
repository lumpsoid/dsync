import 'package:dsync/dsync_core/models/run_event.dart';

/// SPEC §11.5: 128 + signal number — the exit code for a run [RunOutcome]
/// reports as interrupted by SIGINT, deliberately outside the 0-3 scheme
/// below (task fc661b, DECIDED). 128+N is what every shell and CI system
/// already reads as "killed by signal N", and folding an interrupt into exit
/// 3 would have retry logic retrying a run the user asked to stop — 1 and 2
/// both assert "completed, but ..." and an interrupted run did not complete.
const sigintExitCode = 130;

/// SPEC §11.5's 143, for a process that traps SIGTERM: `dsync agent
/// --listen`/`--serve` and `dsync pair show`, where a signal is the ordinary
/// way out, and — since task 7ba6b5 — a `sync`/`status` run, where it is an
/// interruption handled exactly like SIGINT.
///
/// task fc661b originally scoped a run's handling to SIGINT and left SIGTERM
/// to the kernel's default disposition, which also reports 143 — but that
/// disposition kills the process wherever it happens to be, mid-copy
/// included. Data was never at risk (temp-plus-rename, per-line fsync); what
/// was lost is the per-path commit for the action in flight, the end-of-run
/// summary, and a clean close of the far agent's stream. For anything
/// scheduled — a systemd unit, a `timeout`, a cron job's supervisor — SIGTERM
/// is the *normal* stop signal, so the run now traps it too, with the same
/// stop-at-the-next-boundary semantics. The code is the same 128+15 the
/// untrapped case would have reported.
const sigtermExitCode = 143;

/// The two signals that stop a dsync process, each carrying SPEC §11.5's
/// exit code and the name a human-readable "interrupted (...)" line prints.
///
/// A plain enum so that `InterruptGuard` and [RunOutcome] — both kept free of
/// `dart:io` so they test on plain values — can say *which* signal arrived
/// without naming `ProcessSignal`. `lib/cli/stop_signals.dart` is where each
/// one is mapped to its real `ProcessSignal.watch()`, and where the one
/// host-specific fact (Windows cannot trap SIGTERM) lives.
enum StopSignal {
  sigint(exitCode: sigintExitCode, label: 'SIGINT'),
  sigterm(exitCode: sigtermExitCode, label: 'SIGTERM');

  const StopSignal({required this.exitCode, required this.label});

  /// SPEC §11.5's 128 + signal number.
  final int exitCode;

  /// The conventional upper-case name, for messages.
  final String label;
}

/// One `RunController` run, reduced to nothing more than SPEC §11.5 needs to
/// pick an exit code: whether a [RunSummaryEvent] was seen, whether a
/// [RunErrorEvent] was seen, and which [StopSignal] interrupted the run, if
/// any (task fc661b; SIGTERM since task 7ba6b5). A run emits at most one of each of [summary]/[error] —
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

  /// The first [StopSignal] received at any point during this run, or
  /// `null` when none was (task fc661b, DECIDED) — threaded in by the caller
  /// rather than derived from [summary]/[error], since a run that happened
  /// to finish applying before the interrupt took effect still counts: the
  /// signal is what the user asked for, whatever the run itself went on to
  /// report. The *first* one, because that is the one that decided the exit
  /// code; a second signal of the other kind exits the process before this
  /// is ever built.
  final StopSignal? interruptedBy;

  const RunOutcome({this.summary, this.error, this.interruptedBy});

  /// SPEC §11.5's scheme, mirroring Unison, plus task fc661b's DECIDED
  /// addition:
  /// ```
  /// 0    all planned actions applied, no conflicts
  /// 1    completed, but some paths were skipped or are unresolved conflicts
  /// 2    completed, but some actions failed
  /// 3    fatal: bad arguments, cannot reach a replica, lock held, archive
  ///      unreadable, protocol version mismatch
  /// 130  interrupted by SIGINT (128 + 2)
  /// 143  interrupted by SIGTERM (128 + 15)
  /// ```
  /// "When both 1 and 2 apply, 2 wins" — checked in that order below.
  ///
  /// [interruptedBy] wins outright, ahead of even [error]: it says what the
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
    final interruptedBy = this.interruptedBy;
    if (interruptedBy != null) return interruptedBy.exitCode;
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
