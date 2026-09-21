import 'dart:async';
import 'dart:io';

import 'exit_code.dart';
import 'run/interrupt_guard.dart';
import 'stop_signals.dart';

/// How long a stopping dsync process has to finish its shutdown before it
/// exits anyway (task e6be5d).
///
/// **Ten seconds, and the number is part of the contract** — an operator
/// writing a supervisor unit has to pick a kill timeout against it, so it is
/// stated in SPEC §11.5 and in the README rather than left as an
/// implementation detail. A `TimeoutStopSec` below this turns dsync's own
/// bounded exit into a SIGKILL, which is the one exit path that releases
/// nothing; anything comfortably above it never fires.
///
/// Ten rather than five: `SshChannel.close` already spends up to five
/// seconds waiting for a wedged remote `dsync agent --stdio` to notice its
/// stdin closed before it kills it, and that wait happens *after*
/// `LocalAgent.unlock` has flushed the archive and released the lock (SPEC
/// §4.3, §8.2). A deadline at five would cut an ordinary stop off inside a
/// wait the project already decided was reasonable; doubling it leaves the
/// whole of the normal path — flush, release, disconnect — inside the bound,
/// which is the point. This is the last-resort bound, not the normal path:
/// on an ordinary stop nothing here fires at all.
///
/// Ten rather than more: past roughly ten seconds a person watching a
/// terminal has already concluded the program ignored them, and a supervisor
/// stopping a dozen units serially pays it once each.
const stopDeadline = Duration(seconds: 10);

/// The one owner of what happens between a stop signal arriving and this
/// process being gone (task e6be5d; CLAUDE.md "One owner for cross-module
/// ordering").
///
/// Three rules, in one place, for every long-running dsync command —
/// `SyncRunner.run`, `dsync agent --listen`/`--serve`, `dsync pair show`:
///
/// 1. The **first** signal asks nicely. [requested] goes true, [code]
///    completes with SPEC §11.5's exit code for that signal, and the caller
///    unwinds its own shutdown — for a run, the next action boundary, then
///    `LocalAgent.unlock`'s flush-then-release (SPEC §4.3, §8.2); for a
///    listener, `AgentListener.close`.
/// 2. A **second** signal of either kind means now: the process exits at
///    once, with the *first* signal's code, whatever the shutdown was in the
///    middle of. That rule is [InterruptGuard]'s, held below rather than
///    reimplemented.
/// 3. The **deadline** ([stopDeadline]), armed by rule 1, is the rule the
///    other two cannot cover. Every await on an exit path — a scan in
///    flight, an archive flush, a half-open peer socket, a remote agent that
///    stopped answering — is a chance for a shutdown to never finish, and a
///    process that never exits is one a supervisor has to SIGKILL. Rule 2
///    only helps a user with a terminal; a timer helps everyone. When it
///    fires, this process exits with the same code it would have returned,
///    finished or not.
///
/// So an overrunning shutdown step costs a *late* exit, never a hang — and
/// it costs that structurally, without anyone auditing each new await on the
/// way out. That is the same answer this project gave the abandoned dial
/// (`boundedSecureHandshake`, `IdleDeadlineChannel`): a deadline armed by
/// the thing that owns the wait, not a `.timeout()` remembered at each call
/// site.
///
/// **Why the deadline is armed on the first signal and not at construction.**
/// A listener may idle for weeks; nothing about it is late until someone has
/// asked it to stop. The clock this bounds is the one that starts when the
/// user's stop request arrives.
///
/// Both real-world edges — `ProcessSignal.watch()` and `exit()` — are
/// injected, so the whole of the above is exercisable from a plain
/// `StreamController<StopSignal>`, a short [deadline] and a recording
/// function, with no signal raised and no process killed
/// (`test/cli/stop_sequence_test.dart`); the real CLI's end of it is covered
/// through the compiled binary in `test/cli/run/stop_deadline_e2e_test.dart`.
class StopSequence {
  StopSequence({
    this.watchSignals = watchStopSignals,
    this.deadline = stopDeadline,
    this.exitProcess = _realExit,
  });

  /// How long rule 3 above allows, counted from the first signal.
  final Duration deadline;

  /// Installs the real `ProcessSignal.watch()`es, or — in a test — hands
  /// back a plain `StreamController`'s stream. Public and settable for the
  /// same reason `SyncRunner.localAddressLookup` is: it is the one piece of
  /// real I/O this needs, and no real caller ever passes it.
  final Stream<StopSignal> Function() watchSignals;

  /// Ends this process. The real one is [_realExit]; a test passes a
  /// recorder, since a test that actually called `exit` would take the test
  /// runner with it.
  final void Function(int exitCode) exitProcess;
  final InterruptGuard _guard = InterruptGuard();
  final Completer<int> _stopped = Completer<int>();

  StreamSubscription<StopSignal>? _subscription;
  Timer? _deadline;

  /// Starts trapping, and returns as soon as the watches are installed.
  ///
  /// Separate from construction and from awaiting [code] because *when* the
  /// trapping starts matters and when the waiting starts does not:
  /// `AgentCommand` has to be trapping before it binds anything — until
  /// `ProcessSignal.watch()` has run, a SIGTERM kills this process outright
  /// and leaves a socket file behind — but it can only usefully await the
  /// result afterwards.
  void watch() {
    _subscription = watchSignals().listen(_receiveSignal);
  }

  /// Completes with SPEC §11.5's exit code (130 / 143) when the first signal
  /// arrives, and never otherwise — what a listener returns from its `run`.
  Future<int> get code => _stopped.future;

  /// Whether a stop has been asked for — what `SyncRunner.run` checks after
  /// each `RunEvent` to decide whether to stop at this action boundary.
  bool get requested => _guard.requested;

  /// The first signal received, or `null` — what `RunOutcome.interruptedBy`
  /// reports and what the "interrupted (...)" line names.
  StopSignal? get interruptedBy => _guard.interruptedBy;

  void _receiveSignal(StopSignal signal) {
    switch (_guard.receiveSignal(signal)) {
      case StopGracefully():
        // Rule 3 armed by rule 1. `signal` is the first one here by
        // definition, so its code is the one both this timer and
        // `ExitImmediately` below report.
        _deadline = Timer(deadline, () => exitProcess(signal.exitCode));
        _stopped.complete(signal.exitCode);
      case ExitImmediately(:final exitCode):
        exitProcess(exitCode);
    }
  }

  /// Releases the watches and disarms the deadline. The caller owes this on
  /// every path — see `watchStopSignals` for why a stray `ProcessSignal`
  /// subscription turns a finished command into one that appears to hang,
  /// and note that an armed [Timer] keeps the event loop non-empty exactly
  /// the same way.
  Future<void> release() async {
    _deadline?.cancel();
    _deadline = null;
    await _subscription?.cancel();
    _subscription = null;
  }
}

/// The real rule 3: leave, now, with the signal's own code — the one call in
/// this file that a test must not make.
void _realExit(int exitCode) => exit(exitCode);
