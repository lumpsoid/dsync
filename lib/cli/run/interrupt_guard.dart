import '../exit_code.dart';

/// What `SyncRunner.run` should do about one stop signal (task fc661b):
/// plain state, no signal handling of its own, so "the first one asks
/// nicely, the next one means now" is unit-testable without ever raising a
/// real signal.
sealed class InterruptResponse {
  const InterruptResponse();
}

/// Let the current run reach the next safe point and stop there (SPEC §7.1,
/// §7.6): no action in flight is aborted, and nothing new starts.
final class StopGracefully extends InterruptResponse {
  const StopGracefully();
}

/// A second signal — the run already had its chance to stop gracefully and
/// didn't, or is stuck somewhere this handler can't reach (SPEC §11.3's
/// interactive prompt, blocked on stdin). "The usual contract for a handler
/// that delays anything" (task fc661b): stop waiting and exit right now,
/// with [exitCode] — the code of the *first* signal, since that is the one
/// the user's stop request was made with (task 7ba6b5).
final class ExitImmediately extends InterruptResponse {
  final int exitCode;

  const ExitImmediately(this.exitCode);
}

/// Records the stop signals one `sync`/`status` run has received and says
/// what to do about each one.
///
/// Kept free of `dart:io` entirely: `SyncRunner.run` owns the one real
/// signal subscription (`watchStopSignals`, `lib/cli/stop_signals.dart`) and
/// calls [receiveSignal] each time it fires; this class only ever sees plain
/// [StopSignal] values, which is what makes it testable without signals
/// (task fc661b: "unit-test whatever decides ... without signals").
///
/// task 7ba6b5: SIGTERM is trapped alongside SIGINT with identical semantics,
/// so this class no longer counts SIGINTs specifically — it remembers which
/// signal came first, because that is what picks the exit code (SPEC §11.5:
/// 130 or 143), and treats any signal after it as "now".
///
/// task e9f31c removed the second rule this class used to hold —
/// `shouldStop(sawFirstAction:)`, which only let `SyncRunner.run` stop up to
/// and including the *first* `RunActionEvent`, because `Applier.apply` ran
/// every action it was given as one uninterruptible unit. Now that
/// `Applier.apply` reports each action as it finishes (`ApplyProgress`),
/// every point `SyncRunner.run` sees a `RunEvent` is a safe action boundary
/// to stop at, first action or not — so [requested] alone is the whole
/// answer, checked directly at the call site instead of through a second
/// method here.
class InterruptGuard {
  StopSignal? _first;

  /// The first signal recorded, or `null` while none has been — the one
  /// `RunOutcome.interruptedBy` reports and whose exit code the run ends
  /// with.
  StopSignal? get interruptedBy => _first;

  /// Whether at least one signal has been recorded — also
  /// `SyncRunner.run`'s answer to "should the consumer stop after the event
  /// it just rendered, rather than asking for the next one".
  bool get requested => _first != null;

  /// Records one signal. The first call returns [StopGracefully]; every call
  /// after that returns [ExitImmediately] carrying the *first* signal's exit
  /// code, whichever kind the later one was.
  InterruptResponse receiveSignal(StopSignal signal) {
    final first = _first;
    if (first == null) {
      _first = signal;
      return const StopGracefully();
    }
    return ExitImmediately(first.exitCode);
  }
}
