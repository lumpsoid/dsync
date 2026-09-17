import 'package:dsync/dsync_core/models/run_metrics.dart';

/// Where elapsed time comes from, so a test can drive [RunMetricsRecorder]
/// with plain values instead of sleeping.
///
/// A monotonic *elapsed* reading rather than a wall clock (`DateTime
/// Function()`, which is what `AppController` and `HumanRenderer` inject for
/// their own purposes): those two format timestamps for a human, where the
/// wall clock is the answer, while everything here is a difference between
/// two readings — and a wall clock that steps, over an NTP correction or a
/// phone changing timezone mid-run, makes a difference meaningless or
/// negative.
typedef Elapsed = Duration Function();

/// Collects one run's timings (SPEC §17). Written to by `RunController` for
/// phases and by `MeteredAgent`/`MeteredChannel` for per-operation cost; read
/// by whichever head asked for a report.
///
/// **Concrete, no interface, one implementation** — this is the ordering
/// owner's ledger, not a border (CLAUDE.md: "abstraction lives at the
/// border"). A head that wants no report simply never reads it; there is no
/// second implementation to select between, and a null-object variant would
/// buy nothing over the handful of counter increments this does.
///
/// **Always on.** Recording is a [Stopwatch] read and a map update per
/// operation, against operations whose floor is an fsync or a round trip, so
/// there is no measurable run to protect by making it opt-in — and a flag
/// would mean the numbers are unavailable exactly when someone wants them,
/// which for a report about a slow run on someone else's phone is the whole
/// use.
///
/// **Not thread-safe and does not need to be.** Dart's isolate model means
/// every writer here runs on the one event loop.
///
/// **It does have to handle overlap**, and since task 0f7dfc a great deal
/// more of it: the connection keeps several operations outstanding
/// (`RequestWindow`) and `Applier` runs several actions at once, so one
/// replica can have a dozen operations open at the same instant. Two
/// consequences a reader of the report has to know about, and SPEC §17 now
/// says both:
/// - A per-operation **total is wall time and the spans overlap**, so the
///   totals no longer sum to the phase that contained them and will exceed
///   it. `mean` is still what one call cost end to end — which is the number
///   that says whether the link is slow — but it is no longer that call's
///   share of the run.
/// - **Bytes are attributed to the operation that moved them**, through the
///   handle [beginOp] returns, rather than to whichever operation on that
///   side was innermost. With one operation open at a time those were the
///   same thing; with a window open they are not.
class RunMetricsRecorder {
  final Elapsed _elapsed;

  final Map<RunPhase, Duration> _phases = {};
  final Map<RunPhase, Duration> _phaseStarts = {};

  final Map<String, _ReplicaRecord> _replicas = {};

  /// [elapsed] defaults to a [Stopwatch] started here, which is why a head
  /// constructs this at the top of the run: [RunMetrics.elapsed] is measured
  /// from this moment, not from the first phase.
  RunMetricsRecorder({Elapsed? elapsed})
    : _elapsed = elapsed ?? _stopwatchElapsed();

  static Elapsed _stopwatchElapsed() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  /// Marks [phase] as starting now. A phase begun twice without an
  /// [endPhase] keeps the later start, which is the honest reading of a run
  /// that re-entered a step.
  void beginPhase(RunPhase phase) => _phaseStarts[phase] = _elapsed();

  /// Marks [phase] as finished, adding its span to the total. Ending a phase
  /// that never began is ignored rather than recorded as zero — see
  /// [RunMetrics.phases] for why absent and zero must stay distinguishable.
  void endPhase(RunPhase phase) {
    final start = _phaseStarts.remove(phase);
    if (start == null) return;
    _phases[phase] = (_phases[phase] ?? Duration.zero) + (_elapsed() - start);
  }

  /// Closes every phase still open, as of now.
  ///
  /// The safety net for the one phase that cannot be bracketed by a closure:
  /// `RunController`'s apply span contains `yield`s, so it is opened and
  /// closed by hand, and a run that aborts part-way through applying would
  /// otherwise drop the span a reader most wants. Called from the run's
  /// outermost `finally`, where "however this ended, stop the clocks" is the
  /// only thing left to say.
  void endOpenPhases() {
    for (final phase in _phaseStarts.keys.toList()) {
      endPhase(phase);
    }
  }

  /// [beginPhase]/[endPhase] around [body], for the phases that are a single
  /// awaited expression. The phase is closed even if [body] throws, since a
  /// failed run's timings are the ones most worth having.
  Future<T> phase<T>(RunPhase phase, Future<T> Function() body) async {
    beginPhase(phase);
    try {
      return await body();
    } finally {
      endPhase(phase);
    }
  }

  /// Opens an operation on the replica named [side]; the returned handle is
  /// how its bytes are counted and how it is closed.
  ///
  /// A handle rather than a matching `endOp(side, op)` so a caller cannot
  /// close or credit the wrong one, and so `MeteredAgent` can hold it in a
  /// `finally` without restating which operation it was in. That matters
  /// more than it used to: several operations are open on one side at once
  /// (see this class's own note), so "the operation currently open" is not a
  /// thing the recorder can work out for itself.
  OpenOperation beginOp(String side, AgentOp op) {
    final record = _replicaRecord(side);
    final open = OpenOperation._(op, _elapsed(), (operation) {
      record.ops[op] = (record.ops[op] ?? AgentOpStats.none).merge(
        _elapsed() - operation.startedAt,
        operation.bytes,
      );
    });
    return open;
  }

  /// Records raw transport traffic for [side], framing included — called by
  /// `MeteredChannel`, and never for a local replica, which has no wire.
  ///
  /// Kept per replica rather than per operation even though an operation is
  /// usually open: the transport's bytes are not the operation's, since a
  /// heartbeat (SPEC §4.2) travels while an operation is outstanding and
  /// belongs to none of them, and the kernel hands over chunks on boundaries
  /// that have nothing to do with which request they answer.
  void countWireBytes(String side, {int sent = 0, int received = 0}) {
    final record = _replicaRecord(side);
    record.wireBytesSent += sent;
    record.wireBytesReceived += received;
  }

  /// Declares that [side] is reached over a transport (SPEC §4.1) — called by
  /// whoever wraps the agent, which is the only place that knows.
  void markRemote(String side) => _replicaRecord(side).remote = true;

  /// Everything measured so far. Safe to take mid-run: a phase still open is
  /// simply not in [RunMetrics.phases] yet, and an operation still open is
  /// not yet in its side's counts.
  RunMetrics snapshot() => RunMetrics(
    elapsed: _elapsed(),
    phases: Map.unmodifiable(_phases),
    replicas: {
      for (final entry in _replicas.entries)
        entry.key: ReplicaMetrics(
          side: entry.key,
          remote: entry.value.remote,
          ops: Map.unmodifiable(entry.value.ops),
          wireBytesSent: entry.value.wireBytesSent,
          wireBytesReceived: entry.value.wireBytesReceived,
        ),
    },
  );

  _ReplicaRecord _replicaRecord(String side) =>
      _replicas.putIfAbsent(side, _ReplicaRecord.new);
}

/// One replica's accumulating counters. Mutable and private; [RunMetrics] is
/// the immutable shape that leaves this file.
class _ReplicaRecord {
  bool remote = false;
  final Map<AgentOp, AgentOpStats> ops = {};
  int wireBytesSent = 0;
  int wireBytesReceived = 0;
}

/// One operation begun and not yet closed (SPEC §17), holding what it has
/// moved so far — the handle [RunMetricsRecorder.beginOp] hands back.
class OpenOperation {
  final AgentOp op;
  final Duration startedAt;
  final void Function(OpenOperation) _record;

  int bytes = 0;
  bool _closed = false;

  OpenOperation._(this.op, this.startedAt, this._record);

  /// Attributes [count] bytes of file content to *this* operation (SPEC
  /// §7.2), whatever else is open on the same replica at the same time.
  void countBytes(int count) {
    if (_closed) return;
    bytes += count;
  }

  /// Closes the operation and records its span. Idempotent: `readFile`'s
  /// `finally` can run on an abandoned stream that has already ended.
  void end() {
    if (_closed) return;
    _closed = true;
    _record(this);
  }
}
