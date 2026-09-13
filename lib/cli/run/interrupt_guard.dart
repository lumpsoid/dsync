/// What `SyncRunner.run` should do about one SIGINT (task fc661b): plain
/// state, no signal handling of its own, so "the first one asks nicely, the
/// next one means now" is unit-testable without ever raising a real signal.
enum InterruptResponse {
  /// Let the current run reach the next safe point and stop there (SPEC
  /// §7.1, §7.6): no action in flight is aborted, and nothing new starts.
  stopGracefully,

  /// A second SIGINT — the run already had its chance to stop gracefully and
  /// didn't, or is stuck somewhere this handler can't reach (SPEC §11.3's
  /// interactive prompt, blocked on stdin). "The usual contract for a
  /// handler that delays anything" (task fc661b): stop waiting and exit
  /// right now.
  exitImmediately,
}

/// Counts the SIGINTs one `sync`/`status` run has received and says what to
/// do about each one, plus whether `SyncRunner.run`'s consumer should stop
/// asking `RunController.run()`'s stream for the next `RunEvent`.
///
/// Kept free of `dart:io` entirely: `SyncRunner.run` owns the one real
/// `ProcessSignal.sigint.watch()` subscription and calls [receiveSignal]
/// each time it fires; this class only ever sees plain method calls, which
/// is what makes both rules below testable on plain values (task fc661b:
/// "unit-test whatever decides ... the stop-after-current-action logic ...
/// without signals").
class InterruptGuard {
  int _signalCount = 0;

  /// Whether at least one SIGINT has been recorded.
  bool get requested => _signalCount > 0;

  /// Records one SIGINT. The first call returns
  /// [InterruptResponse.stopGracefully]; every call after that returns
  /// [InterruptResponse.exitImmediately].
  InterruptResponse receiveSignal() {
    _signalCount++;
    return _signalCount == 1
        ? InterruptResponse.stopGracefully
        : InterruptResponse.exitImmediately;
  }

  /// Whether `SyncRunner.run`'s consumer should stop after the event it just
  /// rendered, rather than asking for the next one.
  ///
  /// True only once a SIGINT has been [requested], and only up to and
  /// including the first `RunActionEvent`: `Applier.apply` has no
  /// incremental callback (see `RunController`'s own doc comment), so once
  /// it has been handed even one action, the whole plan it was given runs as
  /// a single, uninterruptible unit — stopping partway through would only
  /// discard the summary that run has already committed to producing, not
  /// prevent any actual work. [sawFirstAction] must reflect the state
  /// *before* the current event is folded in, so the call reacting to that
  /// very first `RunActionEvent` still sees it `false` here — stopping right
  /// there is safe: it runs before `Applier.apply` is ever invoked for this
  /// plan.
  bool shouldStop({required bool sawFirstAction}) =>
      requested && !sawFirstAction;
}
