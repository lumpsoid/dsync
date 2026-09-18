import 'dart:async';
import 'dart:collection';

import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/run/elapsed.dart';

/// Told how long a call of [op] waited before the window let it start (SPEC
/// §17) — the seam `RemoteAgent`'s owner uses to feed `RunMetricsRecorder`.
///
/// A callback rather than the recorder itself, so the window keeps knowing
/// nothing about reporting: it hands out a number it already has, and
/// whoever built it decides whether anything is listening.
typedef WindowWaitSink = void Function(AgentOp op, Duration wait);

/// Decides how many of a connection's operations may be outstanding at once,
/// and which of them are allowed to overlap at all (SPEC §4.2, task 0f7dfc).
///
/// **Why a window exists.** Measured phone-to-desktop over `peer://`, a
/// one-request-one-reply operation cost 8.5 bare round trips: after the phone
/// transmits and falls silent, 802.11 power save powers its receiver down and
/// the reply waits at the access point for the next beacon. It is a
/// receive-side latency that does not scale with bytes, and it lands on every
/// one of the ~28,000 strictly sequential requests a 14k-file tree costs
/// (SPEC §17). With several operations outstanding, replies arrive while
/// later requests are still going out, so there is continuous traffic in both
/// directions and no idle gap to doze in — and whatever per-exchange latency
/// is left is amortised across the window instead of multiplied by 28,000.
///
/// **Pure scheduling, no I/O.** It decides admission from plain values and
/// futures, so its rules — the bound, per-path order, the barrier — are
/// testable without a channel or a phone. It reads a clock, but only to
/// report how long it made a caller wait (SPEC §17), and that clock is an
/// injected [Elapsed] like the recorder's, so the waits are testable with
/// plain values too.
class RequestWindow {
  /// How many operations may be outstanding on one connection.
  ///
  /// Twice what `Applier` runs at once, because an action's operations
  /// against one replica are sequential — a
  /// `writeFile` then its `archiveCommitUpsert` — while a delete action adds
  /// a third. Headroom, in other words: this bound exists so a peer cannot
  /// be flooded, not to meter the work, and `Applier` is what decides how
  /// much work there is.
  ///
  /// **Why it is not smaller.** Every operation costs one round trip, so a
  /// connection's throughput is the window divided by the round-trip time,
  /// and nothing else — measured over a unix socket with a forwarding proxy
  /// adding 10 ms (`benchmark/local_sync_throughput.dart`), apply time
  /// halved for every doubling from 4 concurrent actions to 64, with every
  /// per-operation mean pinned at exactly one round trip throughout. There
  /// is no contention to find; there is only latency to cover.
  static const defaultSize = 32;

  /// The bound. At most this many [run] bodies are in flight at once.
  final int size;

  /// Where an admission delay is reported, if anyone asked (SPEC §17).
  ///
  /// The window is the only thing that can measure this, and measuring it is
  /// what stops a per-operation mean from being read as a round-trip time: an
  /// operation held here has not reached the wire, so the wait is *this*
  /// class's cost, not the link's. Null in the tests and call sites that only
  /// care what the window admits.
  final WindowWaitSink? onWait;

  final Elapsed _elapsed;

  /// Operations admitted to the window and not yet finished.
  int _admitted = 0;

  /// Whether a [runExclusive] body is running.
  bool _exclusive = false;

  /// Callers waiting for admission, in the order they asked. FIFO rather
  /// than "shared first", so a barrier behind a steady stream of windowed
  /// operations is not starved by it.
  final Queue<_Waiter> _queue = Queue<_Waiter>();

  /// The most recent operation issued for each path, however far it has got.
  /// An entry is removed when the last operation on that path finishes, so
  /// this holds one entry per in-flight path rather than one per path in the
  /// plan. These futures never carry an error — they report that an
  /// operation is *over*, not how it ended, which is its own caller's.
  final Map<String, Future<void>> _pathTail = {};

  RequestWindow({this.size = defaultSize, this.onWait, Elapsed? elapsed})
    : _elapsed = elapsed ?? stopwatchElapsed(),
      assert(size >= 1, 'A window of zero admits nothing');

  /// Runs [body] as one of at most [size] concurrent operations.
  ///
  /// Two operations on the same [path] never overlap, and they run in the
  /// order they were issued: `writeFile` then `archiveCommitUpsert` for one
  /// path is the ordering the whole archive rule rests on (SPEC §7.3), and
  /// it must not become "whichever the window admitted first". Operations on
  /// *different* paths are free to overlap in any order, which is where the
  /// win comes from.
  Future<T> run<T>(String path, AgentOp op, Future<T> Function() body) async {
    final release = await _enter(path, op);
    try {
      return await body();
    } finally {
      release();
    }
  }

  /// [run] for an operation whose cost is the whole stream, not the call
  /// that starts it — `readFile`, which holds its slot until the last byte
  /// or until its consumer gives up.
  Stream<T> runStream<T>(
    String path,
    AgentOp op,
    Stream<T> Function() body,
  ) async* {
    final release = await _enter(path, op);
    try {
      yield* body();
    } finally {
      release();
    }
  }

  /// Runs [body] alone: nothing else is in flight while it runs, and nothing
  /// admitted after it starts until it finishes.
  ///
  /// This is what `lock`, `unlock`, `hello`, `scan`, `compact` and
  /// `removeEmptyDirs` get. `readFile`, `writeFile`, `delete`,
  /// `archiveCommitUpsert` and `archiveCommitDelete` are per-path operations
  /// whose effects commute with another path's, so they go in the window;
  /// the rest either change what the whole replica means to the session or
  /// reach paths they were not given — `removeEmptyDirs` walks *ancestors*
  /// (SPEC §7.5), so it can delete a directory a concurrent `writeFile` on
  /// another path is about to write into.
  ///
  /// `removeEmptyDirs` is the only one of those that costs anything during
  /// an apply, and it no longer does: `Applier` sweeps emptied ancestors
  /// once, after every action has finished (SPEC §7.5), so the drain it asks
  /// for finds an empty window.
  Future<T> runExclusive<T>(AgentOp op, Future<T> Function() body) async {
    final queuedAt = _elapsed();
    // Waited on before queueing, not after: an operation still held behind
    // an earlier one on its own path has not reached the queue yet, so the
    // bound below would not see it, and it would run *after* a barrier that
    // was issued later. One snapshot is exactly the guarantee owed — every
    // operation issued before this one finishes first — while looping until
    // the map empties would never terminate under a steady applier.
    final issued = _pathTail.values.toList();
    if (issued.isNotEmpty) await Future.wait(issued);

    final waiter = _Waiter(exclusive: true);
    _queue.add(waiter);
    _pump();
    await waiter.admitted.future;
    // Measured from entry, so the drain above is part of the wait: a barrier
    // that sat behind a full window waited, whatever it was waiting on.
    onWait?.call(op, _elapsed() - queuedAt);
    try {
      return await body();
    } finally {
      _exclusive = false;
      _pump();
    }
  }

  /// Waits for a slot behind everything that must precede this operation,
  /// and hands back the callback that gives the slot up. Callers release in
  /// a `finally`, or the window never drains.
  Future<void Function()> _enter(String path, AgentOp op) async {
    final queuedAt = _elapsed();
    final predecessor = _pathTail[path];
    final finished = Completer<void>();
    // Recorded before the first `await`, so two calls for one path chain in
    // call order rather than in whatever order they are resumed in.
    _pathTail[path] = finished.future;

    var released = false;
    void release() {
      if (released) return;
      released = true;
      _admitted--;
      if (_pathTail[path] == finished.future) _pathTail.remove(path);
      finished.complete();
      _pump();
    }

    try {
      // Before taking a slot, never while holding one: the predecessor
      // already has its slot and will give it up, so waiting here cannot
      // deadlock the window against itself.
      if (predecessor != null) await predecessor;
      final waiter = _Waiter(exclusive: false);
      _queue.add(waiter);
      _pump();
      await waiter.admitted.future;
      // Both halves of the wait, and on purpose: an operation held behind
      // its own path's predecessor was no more on the wire than one held
      // behind the bound, and a report that counted only the second would
      // charge the first to the link.
      onWait?.call(op, _elapsed() - queuedAt);
      return release;
    } catch (_) {
      // Never admitted, so there is no slot to give back — but the path
      // chain still has to be released, or every later operation on it hangs.
      released = true;
      if (_pathTail[path] == finished.future) _pathTail.remove(path);
      finished.complete();
      rethrow;
    }
  }

  /// Admits whoever is next and may go now.
  void _pump() {
    while (_queue.isNotEmpty) {
      final next = _queue.first;
      if (next.exclusive) {
        if (_exclusive || _admitted > 0) return;
        _queue.removeFirst();
        _exclusive = true;
        next.admitted.complete();
        return;
      }
      if (_exclusive || _admitted >= size) return;
      _queue.removeFirst();
      _admitted++;
      next.admitted.complete();
    }
  }
}

/// One caller waiting for admission.
class _Waiter {
  final bool exclusive;
  final Completer<void> admitted = Completer<void>();

  _Waiter({required this.exclusive});
}
