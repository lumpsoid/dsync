import 'package:dsync/dsync_core/models/exchange_record.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/sink_write_stats.dart';
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
/// - **A remote operation's cost arrives already split.** `RemoteAgent`
///   reports one [ExchangeRecord] per call — its own queue wait, its own wire
///   span, and what the peer said about that same call — because it is the
///   only object that sees all of those instants. This adds up quantities
///   that are already separate; it never reconstructs one by subtracting
///   another. The arrangement that preceded it took `total - queueWait` and
///   then `meanWire - meanFar` over two different denominators, clamped both
///   at zero, and so could not distinguish a measurement from two counters
///   disagreeing about which calls they had seen.
/// - **Idle is two figures, not one.** A send is a span and a receive is a
///   point event, so a gap-based idle total counted every inbound transfer as
///   silence. [ReplicaMetrics.quiet] and [ReplicaMetrics.awaiting] are
///   credited from what this side has outstanding — a state, known at every
///   instant — rather than from the gaps between events.
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
      _creditIdle(record, phase, start, now);
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
    _markIdleBoundary(record);
    record.openOps++;
    return OpenOperation._(op, _elapsed(), (operation) {
      _markIdleBoundary(record);
      record.openOps--;
      record.ops[op] = (record.ops[op] ?? AgentOpStats.none).merge(
        _elapsed() - operation.startedAt,
        operation.bytes,
      );
    });
  }

  /// Records one finished exchange's measured split (SPEC §17) — called by
  /// `RemoteAgent`, the one object that saw every instant it is made of.
  ///
  /// Never called for a local replica, which has neither a window nor a wire.
  void recordExchange(String side, ExchangeRecord record) {
    final replica = _replicaRecord(side);
    replica.ops[record.op] = (replica.ops[record.op] ?? AgentOpStats.none)
        .mergeExchange(record);
    if (record.far?.sendWait case final wait?) replica.peerSendWait = wait;
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
    _markIdleBoundary(record);
    record.wireBytesSent += bytes;
    record.sends++;
    record.framesSent += frames;
    record.busySends++;
    return OpenSend._(() {
      _markIdleBoundary(record);
      record.busySends--;
    });
  }

  /// Where [side]'s sink figures can be read from when a report is taken —
  /// the `add`-and-`flush` pairs `FlushedSink` actually performed, their
  /// batch sizes, and what the senders waited (SPEC §17).
  ///
  /// **A source, not a sample.** The figures it reads are cumulative, so the
  /// answer is always "whatever they are now" and sampling them per send
  /// bought nothing — while costing an object and a list copy on a path that
  /// runs 46,000 times in one apply, on the device this report exists to
  /// measure. Registered once by `MeteredChannel` and read by [snapshot].
  ///
  /// Absent until a channel registers, and free to answer null afterwards: a
  /// transport with no sink to flush has no write to count, and zero would
  /// read as "it coalesced nothing".
  void watchWrites(String side, SinkWriteStats? Function() source) =>
      _replicaRecord(side).writeStats = source;

  /// Records [bytes] arriving from [side]'s transport, framing included.
  ///
  /// No frame count: a chunk boundary carries no meaning (`Channel.input`),
  /// so what arrives here is whatever the kernel handed over and counting
  /// "frames received" from it would be counting chunks under another name.
  void countReceive(String side, {required int bytes}) {
    final record = _replicaRecord(side);
    // No idle boundary: arriving bytes say nothing about whether this side
    // had something outstanding, which is what [quiet] and [awaiting] are
    // credited from. Treating a receive as an instant of "busy" is exactly
    // the bias the two figures replaced.
    record.firstActivity ??= _elapsed();
    record.wireBytesReceived += bytes;
  }

  /// Closes the idle span [record] is currently in, crediting it to every
  /// phase open across it, and starts the next one from now.
  ///
  /// Called wherever this side's outstanding work changes — a send starting
  /// or finishing, an operation opening or closing — because *that* is what
  /// decides which of the two idle figures the time since the last boundary
  /// belongs to. Nothing is credited before a side's first activity: a
  /// transport that has not spoken yet has not been idle, it has not been
  /// measured.
  void _markIdleBoundary(_ReplicaRecord record) {
    // A local replica has no link to be carrying anything, so neither figure
    // means anything for it — and a local operation opening would otherwise
    // start crediting `awaiting` against a side with no wire at all.
    if (!record.remote) return;
    final now = _elapsed();
    if (record.firstActivity == null) {
      record.firstActivity = now;
      record.lastBoundary = now;
      return;
    }
    for (final MapEntry(key: phase, value: start) in _phaseStarts.entries) {
      _creditIdle(record, phase, start, now);
    }
    record.lastBoundary = now;
  }

  /// Adds [record]'s share of the span ending at [now] to whichever figure
  /// its state names, within [phase], counting only from whichever is later:
  /// the phase's start, or the last boundary.
  ///
  /// A connection with a send in flight is carrying something and is neither
  /// quiet nor awaiting. With nothing in flight it is one or the other, and
  /// which one is the whole question: **quiet** means it had nothing to do,
  /// so more callers would help; **awaiting** means it had something open and
  /// was waiting on the peer or the link, so they would not.
  void _creditIdle(
    _ReplicaRecord record,
    RunPhase phase,
    Duration phaseStart,
    Duration now,
  ) {
    if (record.busySends > 0) return;
    final last = record.lastBoundary;
    if (last == null) return;
    final from = last > phaseStart ? last : phaseStart;
    if (now <= from) return;
    final into = record.openOps > 0 ? record.awaiting : record.quiet;
    into[phase] = (into[phase] ?? Duration.zero) + (now - from);
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
          writeStats: entry.value.writeStats?.call(),
          peerSendWait: entry.value.peerSendWait,
          framesSent: entry.value.framesSent,
          quiet: Map.unmodifiable(entry.value.quiet),
          awaiting: Map.unmodifiable(entry.value.awaiting),
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

  /// Where this side's cumulative sink figures are read from, or null while
  /// no channel on this side has registered one.
  SinkWriteStats? Function()? writeStats;

  /// The peer's own cumulative send wait as of the last reply that carried
  /// it, or null from a peer that does not report it.
  Duration? peerSendWait;

  /// Flushes handed to the transport and not yet written. While this is
  /// above zero the link is carrying something and neither idle figure
  /// accrues.
  int busySends = 0;

  /// Operations open on this side. Above zero, silence is [awaiting]; at
  /// zero, it is [quiet].
  int openOps = 0;

  /// Per phase, how long this transport had nothing to carry, and how long it
  /// had something outstanding and was waiting for it.
  final Map<RunPhase, Duration> quiet = {};
  final Map<RunPhase, Duration> awaiting = {};

  /// When this side was first measured at all, and when its last idle span
  /// began. Both null before the first activity — which is not the same as
  /// zero, and is why they are nullable.
  Duration? firstActivity;
  Duration? lastBoundary;
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
