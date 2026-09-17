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
/// every writer here runs on the one event loop; the overlap this *does* have
/// to handle is two concurrent operations on different replicas (both `scan`s,
/// or a copy's `readFile` on one side inside the other's `writeFile`), which
/// is why an open operation is tracked per side rather than globally.
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

  /// Opens an operation on the replica named [side]; the returned callback
  /// closes it and records the span.
  ///
  /// A callback rather than a matching `endOp(side, op)` so a caller cannot
  /// close the wrong one, and so `MeteredAgent` can hold it in a `finally`
  /// without restating which operation it was in. Operations on one side
  /// nest as a stack: bytes counted while one is open are attributed to the
  /// innermost, which is the one actually moving them.
  void Function() beginOp(String side, AgentOp op) {
    final record = _replicaRecord(side);
    final open = _OpenOp(op, _elapsed());
    record.open.add(open);
    var closed = false;
    return () {
      if (closed) return;
      closed = true;
      record.open.remove(open);
      record.ops[op] = (record.ops[op] ?? AgentOpStats.none).merge(
        _elapsed() - open.startedAt,
        open.bytes,
      );
    };
  }

  /// Attributes [bytes] of file content to whichever operation is currently
  /// open on [side] (SPEC §7.2). Bytes arriving with no operation open are
  /// dropped: they belong to nothing this report describes, and inventing an
  /// operation to hang them on would be worse than not counting them.
  void countPayloadBytes(String side, int bytes) {
    final open = _replicaRecord(side).open;
    if (open.isEmpty) return;
    open.last.bytes += bytes;
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
  final List<_OpenOp> open = [];
  int wireBytesSent = 0;
  int wireBytesReceived = 0;
}

/// An operation begun and not yet closed, holding what it has moved so far.
class _OpenOp {
  final AgentOp op;
  final Duration startedAt;
  int bytes = 0;

  _OpenOp(this.op, this.startedAt);
}
