import 'dart:async';
import 'dart:io';

import 'exit_code.dart';

/// Which of the two [StopSignal]s this host can actually trap.
///
/// `dart:io` supports `ProcessSignal.sigint.watch()` everywhere, but
/// `ProcessSignal.sigterm.watch()` throws a `SignalException` on Windows —
/// there is no SIGTERM to deliver there, and the console control events that
/// stand in for it only ever surface as SIGINT. Pure so a test can cover both
/// answers from a plain `bool`; [watchStopSignals] is what reads the real
/// host's.
List<StopSignal> trappableStopSignals({required bool isWindows}) =>
    isWindows ? const [StopSignal.sigint] : StopSignal.values;

/// One stream of every stop signal this process receives, in arrival order —
/// the single place a `ProcessSignal.watch()` for SIGINT/SIGTERM is
/// installed, shared by `AgentCommand`, `PairShowCommand`, and `SyncRunner`
/// (task 7ba6b5) so the Windows guard above is applied once rather than
/// remembered at each call site.
///
/// Cancelling the returned stream's subscription releases every underlying
/// watch, including the one that never fired; every caller owes that cancel
/// on every path. A `ProcessSignal` subscription left alive keeps this
/// process's event loop non-empty, and `bin/dsync.dart` returns an exit code
/// rather than calling `exit()` — so a stray watcher is the difference
/// between a command ending and a command appearing to hang after it has
/// already done everything.
///
/// Watching starts on `listen`, not on construction, so a caller that needs
/// the trap in place *before* some other step (`AgentCommand._serveSocket`
/// binds its socket only after this) can rely on `listen` having returned.
Stream<StopSignal> watchStopSignals() {
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  late final StreamController<StopSignal> controller;
  controller = StreamController<StopSignal>(
    onListen: () {
      for (final signal in trappableStopSignals(
        isWindows: Platform.isWindows,
      )) {
        subscriptions.add(
          _processSignal(signal).watch().listen((_) => controller.add(signal)),
        );
      }
    },
    onCancel: () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      subscriptions.clear();
    },
  );
  return controller.stream;
}

ProcessSignal _processSignal(StopSignal signal) => switch (signal) {
  StopSignal.sigint => ProcessSignal.sigint,
  StopSignal.sigterm => ProcessSignal.sigterm,
};
