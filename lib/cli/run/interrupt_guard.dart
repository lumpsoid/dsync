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
/// do about each one.
///
/// Kept free of `dart:io` entirely: `SyncRunner.run` owns the one real
/// `ProcessSignal.sigint.watch()` subscription and calls [receiveSignal]
/// each time it fires; this class only ever sees plain method calls, which
/// is what makes it testable on plain values (task fc661b: "unit-test
/// whatever decides ... without signals").
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
  int _signalCount = 0;

  /// Whether at least one SIGINT has been recorded — also
  /// `SyncRunner.run`'s answer to "should the consumer stop after the event
  /// it just rendered, rather than asking for the next one".
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
}
