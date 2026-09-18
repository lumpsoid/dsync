import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/run/elapsed.dart';

export 'package:dsync/dsync_core/run/elapsed.dart' show Elapsed;

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
/// - **A mean is part far side.** A remote operation's mean covers the
///   request going out, whatever the peer did with it, and the reply coming
///   back. [countFarSide] records the middle term as the peer itself
///   measured it, so `AgentOpStats.meanLinkTime` is what is left for the
///   link. Absent unless the peer reports it, and absent is not zero.
/// - **A mean is part queue.** An operation that waited for a window slot
///   paid that wait inside its span, so [countQueueWait] records the wait
///   separately and the report subtracts it: `AgentOpStats.meanWireTime` is
///   the exchange, `AgentOpStats.meanQueueWait` is the queueing, and only
///   their sum is the mean. Without the split, a mean that rose because the
///   window filled up is indistinguishable from one that rose because the
///   link got slower, and the two have opposite fixes.
class RunMetricsRecorder {
  final Elapsed _elapsed;

  final Map<RunPhase, Duration> _phases = {};
  final Map<RunPhase, Duration> _phaseStarts = {};

  final Map<String, _ReplicaRecord> _replicas = {};

  /// [elapsed] defaults to a [Stopwatch] started here, which is why a head
  /// constructs this at the top of the run: [RunMetrics.elapsed] is measured
  /// from this moment, not from the first phase.
  RunMetricsRecorder({Elapsed? elapsed})
    : _elapsed = elapsed ?? stopwatchElapsed();

  /// Marks [phase] as starting now. A phase begun twice without an
  /// [endPhase] keeps the later start, which is the honest reading of a run
  /// that re-entered a step.
  void beginPhase(RunPhase phase) => _phaseStarts[phase] = _elapsed();

  /// Marks [phase] as finished, adding its span to the total. Ending a phase
  /// that never began is ignored rather than recorded as zero — see
  /// [RunMetrics.phases] for why absent and zero must stay distinguishable.
  void endPhase(RunPhase phase) {
    final start = _phaseStarts[phase];
    if (start == null) return;
    final now = _elapsed();
    // Before the phase is taken off the open list, or the silence between
    // the last byte and the end of the phase is credited to nothing. A phase
    // that ended waiting is exactly the one whose idle time is the point.
    for (final record in _replicas.values) {
      if (record.busySends == 0) _creditIdle(record, phase, start, now);
    }
    _phaseStarts.remove(phase);
    _phases[phase] = (_phases[phase] ?? Duration.zero) + (now - start);
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

  /// Opens a flush of [bytes] framed protocol carrying [frames] frames on
  /// [side]'s transport; the returned handle is closed when the transport has
  /// taken them. Called by `MeteredChannel`, and never for a local replica,
  /// which has no wire.
  ///
  /// Kept per replica rather than per operation even though an operation is
  /// usually open: the transport's bytes are not the operation's, since a
  /// heartbeat (SPEC §4.2) travels while an operation is outstanding and
  /// belongs to none of them, and the kernel hands over chunks on boundaries
  /// that have nothing to do with which request they answer.
  ///
  /// **A span rather than an instant, because idle time depends on it.** A
  /// flush that is still being written is a link carrying something, and on a
  /// link with a rate low enough to matter that write takes real time — which
  /// is exactly the run whose idle time is worth knowing. Counted as a point
  /// event instead, every run would report its whole phase as idle and the
  /// figure would say nothing.
  OpenSend beginSend(String side, {required int bytes, required int frames}) {
    final record = _replicaRecord(side);
    _markWireActivity(record);
    record.wireBytesSent += bytes;
    record.sends++;
    record.framesSent += frames;
    record.busySends++;
    return OpenSend._(() {
      record.busySends--;
      // Idle only starts again once the last flush has landed, so the time
      // spent writing is never charged to it.
      if (record.busySends == 0) record.lastWireActivity = _elapsed();
    });
  }

  /// Records [bytes] arriving from [side]'s transport, framing included.
  ///
  /// No frame count: a chunk boundary carries no meaning (`Channel.input`),
  /// so what arrives here is whatever the kernel handed over and counting
  /// "frames received" from it would be counting chunks under another name.
  void countReceive(String side, {required int bytes}) {
    final record = _replicaRecord(side);
    _markWireActivity(record);
    record.wireBytesReceived += bytes;
  }

  /// Credits the silence since [record]'s last traffic to every phase open
  /// across it, then marks now as its last traffic.
  ///
  /// This is the whole of how wire idle time is measured (SPEC §17): the gaps
  /// between bytes moving. A connection with a request outstanding and no
  /// reply yet is *idle by this measure* — and deliberately so. The question
  /// it exists to answer is "did this phase use its link", and a phone
  /// waiting a beacon interval for a reply is not using its link however busy
  /// the run feels.
  ///
  /// Nothing is credited before a side's first byte: a transport that has not
  /// spoken yet has not been idle, it has not been measured.
  void _markWireActivity(_ReplicaRecord record) {
    final now = _elapsed();
    if (record.busySends == 0) {
      for (final MapEntry(key: phase, value: start) in _phaseStarts.entries) {
        _creditIdle(record, phase, start, now);
      }
    }
    record.lastWireActivity = now;
  }

  /// Adds [record]'s silence within [phase] up to [now] to that phase's idle
  /// total, counting only from whichever is later: the phase's start, or the
  /// last byte that moved.
  void _creditIdle(
    _ReplicaRecord record,
    RunPhase phase,
    Duration phaseStart,
    Duration now,
  ) {
    final last = record.lastWireActivity;
    if (last == null) return;
    final from = last > phaseStart ? last : phaseStart;
    if (now <= from) return;
    record.idle[phase] = (record.idle[phase] ?? Duration.zero) + (now - from);
  }

  /// Records that a call of [op] on [side] waited [wait] for a window slot
  /// (SPEC §17) — called by `RequestWindow` as it admits the operation, which
  /// is the one place that knows both instants.
  ///
  /// Recorded against the operation rather than the replica because the
  /// answer it gives is per operation: `writeFile` queueing behind the window
  /// while `archiveCommit` does not is a different diagnosis from both
  /// of them queueing, and a per-replica total cannot show it.
  void countQueueWait(String side, AgentOp op, Duration wait) {
    final record = _replicaRecord(side);
    record.ops[op] = (record.ops[op] ?? AgentOpStats.none).mergeQueueWait(wait);
  }

  /// Records that the peer reported [span] as its own time on a call of [op]
  /// (SPEC §17) — called by `RemoteAgent` as the reply is decoded, which is
  /// the one place that sees the figure.
  ///
  /// Only calls whose reply actually carried one are recorded, so
  /// `AgentOpStats.farSideCount` stays below `count` against a peer that does
  /// not report and the report can say "absent" rather than "zero". Never
  /// called for a local replica, which has no far side.
  void countFarSide(String side, AgentOp op, Duration span) {
    final record = _replicaRecord(side);
    record.ops[op] = (record.ops[op] ?? AgentOpStats.none).mergeFarSide(span);
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
          sends: entry.value.sends,
          framesSent: entry.value.framesSent,
          idle: Map.unmodifiable(entry.value.idle),
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
  int sends = 0;
  int framesSent = 0;

  /// Flushes handed to the transport and not yet written. While this is
  /// above zero the link is carrying something and no idle time accrues.
  int busySends = 0;

  /// Per phase, how long this transport carried nothing.
  final Map<RunPhase, Duration> idle = {};

  /// When a byte last moved in either direction, or null before the first
  /// one — which is not the same as zero, and is why this is nullable.
  Duration? lastWireActivity;
}

/// One flush handed to a transport and not yet written — the handle
/// [RunMetricsRecorder.beginSend] hands back, closed when the transport has
/// taken the bytes.
class OpenSend {
  final void Function() _done;
  bool _closed = false;

  OpenSend._(this._done);

  /// Marks the flush as written. Idempotent, so a caller can close it in a
  /// `finally` without checking whether the send threw.
  void end() {
    if (_closed) return;
    _closed = true;
    _done();
  }
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
