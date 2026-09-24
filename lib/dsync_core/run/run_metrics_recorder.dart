import 'package:dsync/dsync_core/models/exchange_record.dart';
import 'package:dsync/dsync_core/models/loop_lag_stats.dart';
import 'package:dsync/dsync_core/models/process_memory.dart';
import 'package:dsync/dsync_core/models/read_ahead_stats.dart';
import 'package:dsync/dsync_core/models/read_cadence_stats.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/write_path_stats.dart';
import 'package:dsync/dsync_core/models/write_stage_stats.dart';
import 'package:dsync/dsync_core/models/sink_write_stats.dart';
import 'package:dsync/dsync_core/run/elapsed.dart';
import 'package:dsync/dsync_core/run/loop_lag_tally.dart';
import 'package:dsync/dsync_core/run/resident_memory.dart';

export 'package:dsync/dsync_core/run/elapsed.dart' show Elapsed;
export 'package:dsync/dsync_core/run/resident_memory.dart'
    show ResidentBytes, ResidentMemory;

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

  /// Time accrued while at least one phase was open, and when the current
  /// such stretch began — null whenever nothing is open.
  ///
  /// The run's clock is not wall time from construction, because the run is
  /// not the only thing on it: `RunController` is a generator, so between
  /// `present` and `apply` it is parked on a `yield` while the head shows a
  /// plan and waits for a person to confirm it, and it stays alive after the
  /// last phase while a report is read. Both are outside the run — timing
  /// them measures how fast someone reads (task 9d2158 §18).
  ///
  /// **"Open" means a phase [_onTheClock], not any phase at all.** Waiting
  /// for the person is inside `present`, not between phases, so a clock that
  /// ran while anything was open put the think time straight back into the
  /// total the fix above took it out of.
  Duration _running = Duration.zero;
  Duration? _openSince;

  final Map<String, _ReplicaRecord> _replicas = {};

  ReadAheadStats? _readAhead;

  /// This isolate's event-loop lag, per phase, from whatever sampler the head
  /// started (task 7080d6). Empty when none was.
  final Map<RunPhase, LoopLagTally> _loopLag = {};

  /// Where a resident-set reading comes from, and what this process held when
  /// the recorder was built — the run's baseline, since the peak the kernel
  /// keeps is for the whole process lifetime (see [ProcessMemory]).
  final ResidentMemory _memory;
  final int _baselineRss;

  /// [elapsed] defaults to a [Stopwatch] started here. It is the reading
  /// every span is taken against; what it is *not* is [RunMetrics.elapsed],
  /// which accrues only while a phase is open — see [_running].
  ///
  /// [memory] defaults to the real `dart:io` reading and exists for the same
  /// reason [elapsed] does: a test asserts what the report says about a peak
  /// with plain values, without having to allocate one.
  factory RunMetricsRecorder({Elapsed? elapsed, ResidentMemory? memory}) =>
      RunMetricsRecorder._(
        elapsed ?? stopwatchElapsed(),
        memory ?? processResidentMemory(),
      );

  RunMetricsRecorder._(this._elapsed, ResidentMemory memory)
    : _memory = memory,
      _baselineRss = memory().current;

  /// Marks [phase] as starting now. A phase begun twice without an
  /// [endPhase] keeps the later start, which is the honest reading of a run
  /// that re-entered a step.
  void beginPhase(RunPhase phase) {
    final now = _elapsed();
    // The first phase to open starts the run's clock; one opening while
    // another is already open changes nothing, which is what keeps this
    // correct if phases ever nest.
    if (_onTheClock(phase)) _openSince ??= now;
    _phaseStarts[phase] = now;
  }

  /// Whether [phase] being open means the *run* is running.
  ///
  /// Every phase but one. [RunPhase.present] is a person deciding (SPEC
  /// §11.3), and it is not a gap between phases the clock could skip by
  /// staying closed: both heads park *inside* the presenter — the Flutter
  /// head on a completer the conflict sheet settles, the CLI on a prompt —
  /// so the phase is open for the whole of the think time. Measuring it is
  /// the point of [RunPhase.present] having a row of its own; adding it to
  /// the total is what made the total measure how fast someone reads.
  static bool _onTheClock(RunPhase phase) => phase != RunPhase.present;

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
    // The last phase that counts closing stops the clock. Asked of the keys
    // rather than of a counter, so a `present` left open by a head that
    // never closed it cannot hold the clock open either.
    if (_openSince != null && !_phaseStarts.keys.any(_onTheClock)) {
      _running += now - _openSince!;
      _openSince = null;
    }
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
        held: operation.held,
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
    // Both are cumulative peer-side totals, so the last one to arrive is the
    // complete one. The write path's arrives on `unlock` and only there.
    //
    // Installed as a source rather than assigned, so that a remote replica's
    // pushed figure and a local one's pulled figure are the same field and
    // there is no pair of them to keep in step. One closure per `unlock`,
    // which is once per run.
    if (record.far?.writePath case final steps?) {
      replica.writePathSource = () => steps;
    }
    // Served-side only, so a plain field: a local replica has no server and
    // nothing to source it from. Arrives on `unlock` like the write path.
    if (record.far?.writeStages case final stages?) {
      replica.writeStages = stages;
    }
    if (record.far?.loopLag case final lag?) {
      replica.servedLoopLag = lag;
    }
    if (record.far?.reads case final reads?) {
      replica.servedReads = reads;
    }
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

  /// Where [side]'s own `writeFile` step breakdown is read from (SPEC §17,
  /// §7.2).
  ///
  /// **A source, not a sample**, for the reason [watchWrites] gives: the
  /// figures are cumulative, so the answer is always "whatever they are now",
  /// and sampling them per write would cost an object on a path that runs once
  /// per copied file.
  ///
  /// Registered by `RunInstruments` for a **local** replica. A remote one's
  /// arrives pushed, on the `unlock` reply, and [recordExchange] installs it
  /// into the same field — so a report has one write path per replica however
  /// it got there, rather than a local field and a peer field that a reader
  /// has to know to check both of.
  void watchWritePath(String side, WritePathStats? Function() source) =>
      _replicaRecord(side).writePathSource = source;

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

  /// Takes the apply's read-ahead counters, which arrive once rather than
  /// accumulating: `ReadAhead` is built per apply and counts its own totals,
  /// so there is nothing here to add up (SPEC §17).
  void recordReadAhead(ReadAheadStats stats) => _readAhead = stats;

  /// One tick of this isolate's event-loop lag sampler (SPEC §17, task
  /// 7080d6), credited to every phase open on the run's clock. A tick with
  /// none open — before the run, or while a person reads the plan — is
  /// nobody's and is dropped.
  void recordLoopLag(Duration lag) {
    for (final phase in _phaseStarts.keys) {
      if (_onTheClock(phase)) {
        _loopLag.putIfAbsent(phase, LoopLagTally.new).add(lag);
      }
    }
  }

  /// Each sampled phase's lag, over the phase's span so far.
  Map<RunPhase, LoopLagStats> _loopLagAsOfNow() {
    final now = _elapsed();
    return {
      for (final MapEntry(key: phase, value: tally) in _loopLag.entries)
        phase: tally.stats(
          window:
              (_phases[phase] ?? Duration.zero) +
              switch (_phaseStarts[phase]) {
                final start? => now - start,
                null => Duration.zero,
              },
        ),
    };
  }

  /// [_running] including the stretch that is open right now, if one is, so
  /// a mid-run snapshot reads as a clock rather than as the last phase
  /// boundary.
  /// This process's peak against the baseline taken at construction, or null
  /// on a platform that reports no high-water mark at all — absent rather
  /// than zero, for the reason a skipped phase is absent (SPEC §17).
  ProcessMemory? _memoryAsOfNow() {
    final reading = _memory();
    if (reading.peak <= 0) return null;
    return ProcessMemory(baselineRss: _baselineRss, peakRss: reading.peak);
  }

  Duration _runningAsOfNow() =>
      _openSince == null ? _running : _running + (_elapsed() - _openSince!);

  /// Everything measured so far. Safe to take mid-run: a phase still open is
  /// simply not in [RunMetrics.phases] yet, and an operation still open is
  /// not yet in its side's counts.
  RunMetrics snapshot() => RunMetrics(
    elapsed: _runningAsOfNow(),
    phases: Map.unmodifiable(_phases),
    readAhead: _readAhead,
    memory: _memoryAsOfNow(),
    loopLag: _loopLagAsOfNow(),
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
          writePath: entry.value.writePathSource?.call(),
          writeStages: entry.value.writeStages,
          servedLoopLag: entry.value.servedLoopLag,
          servedReads: entry.value.servedReads,
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

  /// Where this replica's write-path breakdown is read from, or null while
  /// nothing has registered one. Set by `watchWritePath` for a local replica
  /// and by `recordExchange` for a remote one.
  WritePathStats? Function()? writePathSource;

  /// The served peer's per-stage `writeFile` occupancy, as of the `unlock`
  /// reply that carried it, or null before one did.
  WriteStageStats? writeStages;

  /// The served peer's event-loop lag, as of the `unlock` reply that carried
  /// it, or null before one did.
  LoopLagStats? servedLoopLag;

  /// The served peer's read cadence, as of the `unlock` reply that carried
  /// it, or null before one did.
  ReadCadenceStats? servedReads;

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

  /// How long this call sat waiting on its consumer, or null for one with no
  /// consumer to wait on (SPEC §17). Null rather than zero: "nothing held it"
  /// and "nothing could have held it" are different answers, and only a
  /// streamed operation can give the first.
  Duration? held;

  bool _closed = false;

  OpenOperation._(this.op, this.startedAt, this._record);

  /// Attributes [count] bytes of file content to *this* operation (SPEC
  /// §7.2), whatever else is open on the same replica at the same time.
  void countBytes(int count) {
    if (_closed) return;
    bytes += count;
  }

  /// Attributes the part of this call's span that its consumer held it for,
  /// so the span can be read as the two things it is made of rather than as
  /// one number meaning both (SPEC §17). Set, not accumulated: the caller
  /// holds the running total and reports it once, at the end.
  void countHeld(Duration value) {
    if (_closed) return;
    held = value;
  }

  /// Closes the operation and records its span. Idempotent: `readFile`'s
  /// `finally` can run on an abandoned stream that has already ended.
  void end() {
    if (_closed) return;
    _closed = true;
    _record(this);
  }
}
