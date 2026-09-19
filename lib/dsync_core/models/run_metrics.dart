import 'package:dsync/dsync_core/models/exchange_record.dart';
import 'package:dsync/dsync_core/models/sink_write_stats.dart';

/// One step of `RunController`'s flow (SPEC §13), in the order it drives them.
///
/// The phase split is the one the flow already has, not a finer one invented
/// for reporting: each value is a section of `RunController.run` with a
/// single obvious boundary, so a duration here can always be pointed at a
/// particular thing the tool was doing.
///
/// [present] is separated from [apply] rather than folded into it precisely
/// because it is the one phase that is not the tool's own cost — on an
/// interactive head it is however long the user took to answer (SPEC §11.3),
/// which would otherwise swamp every real number in the report.
enum RunPhase {
  /// Both `hello` calls: the version handshake and replica identification
  /// (SPEC §4.2).
  connect,

  /// Both `lock` calls (SPEC §4.3).
  lock,

  /// Both `scan` calls, which run concurrently — so this is the *longer* of
  /// the two sides, not their sum.
  scan,

  /// `Reconciler.reconcile` (SPEC §6): pure computation on two status lists,
  /// no I/O, no wire.
  reconcile,

  /// The `Presenter` callback (SPEC §11.3) — user think-time on an
  /// interactive head, effectively zero on a batch one.
  present,

  /// `Applier.apply` (SPEC §7) end to end, including the per-path archive
  /// commits on both sides (SPEC §7.3).
  apply,

  /// Both `compact` calls (SPEC §8.2), skipped entirely by a run that
  /// committed nothing.
  compact,

  /// Both `unlock` calls (SPEC §4.3).
  unlock,

  /// Both `disconnect` calls — closing the transport (SPEC §4.2).
  disconnect,
}

/// One `Agent` operation (SPEC §4.2), as a key that cannot be misspelled.
///
/// A `Map<AgentOp, AgentOpStats>` rather than one field per operation, which
/// is what `ScanReasonTally` does for its five counts: twelve required fields
/// would be a wall, and unlike a tally over a closed set of branches, an
/// operation a run never performed has no count to report — a `deleteOnB`-free
/// run genuinely has nothing to say about `delete`. The map is partial on
/// purpose, and the enum is what keeps a partial map from also being a
/// misspelled one.
///
/// [disconnect] is here even though it is teardown rather than work: it is an
/// `Agent` call that can block, and a run that appeared to hang after printing
/// its summary is exactly the bug the `RemoteAgent.disconnect` doc comment
/// records. There is no value for a heartbeat — it is not an operation (SPEC
/// §4.2: "no `op`, no reply, and no agent behind it"), and its bytes land in
/// [ReplicaMetrics.wireBytesSent] like any other frame's.
enum AgentOp {
  hello,
  lock,
  unlock,
  scan,
  readFile,
  writeFile,
  delete,
  removeEmptyDirs,
  archiveCommit,
  compact,
  disconnect,
}

/// Everything one [AgentOp] cost on one replica across a whole run.
///
/// **Two sources, kept apart on purpose.** [count], [total], [max] and
/// [bytes] are the `Agent` boundary's view, recorded by `MeteredAgent` on
/// either kind of replica. [exchanges] and everything beside it come from
/// `RemoteAgent`'s per-call [ExchangeRecord]s and exist only on a remote one.
///
/// **Nothing here is a subtraction of one total from another.** Every split
/// was taken on one call, from instants that nest, by the one object that saw
/// all of them; this only ever adds up quantities that arrived already split,
/// and each mean is divided by the count of the calls that contributed to
/// *it*. The arrangement it replaces — `total − queueWait`, then
/// `meanWire − meanFar` over two different denominators, both clamped at zero
/// — could not tell a real figure from two counters disagreeing.
class AgentOpStats {
  /// How many times the operation was called, at the `Agent` boundary.
  final int count;

  /// Summed wall time of every call, measured at the `Agent` boundary — for
  /// a local replica the filesystem call, and for a remote one the whole of
  /// it, queueing included.
  final Duration total;

  /// The slowest single call. Kept alongside [total] because a mean hides
  /// the shape of the distribution, and the two questions a slow run raises
  /// — "is every request slow?" and "did one request stall?" — have opposite
  /// answers depending on which of these dominates.
  final Duration max;

  /// Payload bytes this operation moved: file content for [AgentOp.readFile]
  /// and [AgentOp.writeFile], zero for every other operation, which carries
  /// one path or nothing (SPEC §15.3).
  ///
  /// Counted at the `Agent` boundary, so it is the file's own size — not what
  /// went over the wire, which carries framing on top and is
  /// [ReplicaMetrics.wireBytesSent]. The gap between the two is the protocol's
  /// overhead, which is the whole point of measuring both.
  final int bytes;

  /// How many exchanges of this operation reported a measured split — every
  /// call on a remote replica, none at all on a local one, which has no
  /// window and no wire.
  ///
  /// The denominator for [meanQueueWait] and [meanWireTime], and not the same
  /// number as [count]: the two are recorded by different collaborators at
  /// different instants, so a snapshot taken mid-run holds calls counted at
  /// one and not yet at the other. Keeping them apart is what stops that
  /// from showing up as a plausible-looking duration.
  final int exchanges;

  /// Summed time these calls spent waiting for a `RequestWindow` slot rather
  /// than on the wire (SPEC §17) — the path predecessor they queued behind,
  /// the window's bound, or a barrier ahead of them.
  ///
  /// **The split a mean stopped being readable without.** Since task 0f7dfc
  /// several operations are outstanding at once, and a mean that rose because
  /// this rose says "we are queueing — the window or the concurrency is the
  /// bound", while one that rose because [wire] rose says "the exchange
  /// itself got dearer". A single figure cannot tell those apart.
  final Duration queueWait;

  /// Summed time these calls spent on the wire: admitted to finished, the
  /// request out, whatever the peer did, and the reply back.
  final Duration wire;

  /// Summed time the *peer* spent on the calls that reported one, as the peer
  /// measured it (SPEC §17), and how many of them did.
  ///
  /// **Absent is not zero**, which is what [farCount] is for. A peer that
  /// does not report its own span — an older build, or an operation like
  /// `scan` and `readFile` whose reply is not a success control frame — must
  /// not read as a destination that cost nothing, which is precisely the
  /// conclusion this measurement exists to rule out.
  ///
  /// **And it is residency, not service time.** The peer dispatches every
  /// arriving request concurrently, so this is wall time on an agent serving
  /// [meanFarInFlight] requests at once. Read the two together or not at all.
  final Duration far;
  final int farCount;

  /// Summed link time over those same calls: each one's own [wire] less its
  /// own far-side span. Divided by [farCount], never by [count].
  final Duration link;

  /// Summed count of requests the peer had in flight across the calls that
  /// reported one — the denominator for that is [farInFlightCount], since a
  /// peer may report its span without reporting its concurrency.
  final int farInFlight;
  final int farInFlightCount;

  /// Summed time the peer spent starved of the inbound frames of these
  /// calls, over the ones that reported it, and how many did.
  ///
  /// **What splits `far` into the peer's two opposite meanings.** A
  /// `writeFile`'s far span contains the transfer, because it starts when
  /// the request frame lands and the bytes follow at the link's pace. Near
  /// [far] it says the destination was waiting on the link and writing
  /// cheaply; near zero it says the bytes were there and the destination's
  /// disk is the cost. One number could not tell those apart, and they have
  /// opposite fixes.
  ///
  /// Its denominator is [farInboundCount], not [farCount]: only `writeFile`
  /// has an inbound stream to wait for.
  final Duration farInbound;
  final int farInboundCount;

  /// Summed time between a reply's bytes arriving on this side's transport
  /// and the call that was waiting for it finishing, over the calls that
  /// measured it (SPEC §17), and how many did.
  ///
  /// **The one column that names this side's own event loop.** Everything
  /// else on a remote row is either the peer's, the link's, or — for the
  /// per-action figures — an identity over concurrency and throughput. This
  /// is a span on one clock between two events in one process, so a mean in
  /// the tens of milliseconds says the isolate reading the connection is the
  /// bound and no amount of window or link is going to move it.
  ///
  /// [settleCount] is not [exchanges]: a `readFile` holds its slot for a
  /// whole stream and has no single reply to stamp, so it contributes to one
  /// and not the other.
  final Duration settle;
  final int settleCount;

  const AgentOpStats({
    required this.count,
    required this.total,
    required this.max,
    required this.bytes,
    this.exchanges = 0,
    this.queueWait = Duration.zero,
    this.wire = Duration.zero,
    this.far = Duration.zero,
    this.farCount = 0,
    this.link = Duration.zero,
    this.farInFlight = 0,
    this.farInFlightCount = 0,
    this.settle = Duration.zero,
    this.settleCount = 0,
    this.farInbound = Duration.zero,
    this.farInboundCount = 0,
  });

  /// Zero of everything — the starting point [merge] accumulates onto.
  static const none = AgentOpStats(
    count: 0,
    total: Duration.zero,
    max: Duration.zero,
    bytes: 0,
  );

  /// This plus one more call of [elapsed] carrying [bytes] payload bytes, as
  /// the `Agent` boundary saw it.
  AgentOpStats merge(Duration elapsed, int bytes) => _with(
    count: count + 1,
    total: total + elapsed,
    max: elapsed > max ? elapsed : max,
    bytes: this.bytes + bytes,
  );

  /// This plus one exchange's measured split (SPEC §17).
  ///
  /// Separate from [merge] because the two arrive from different
  /// collaborators at different instants — `RemoteAgent` reports the split as
  /// the exchange ends, `MeteredAgent` the boundary span as the call returns
  /// — and folding them into one counter is what made a snapshot able to hold
  /// halves of two different populations.
  AgentOpStats mergeExchange(ExchangeRecord record) => _with(
    exchanges: exchanges + 1,
    queueWait: queueWait + record.queueWait,
    wire: wire + record.wire,
    far: record.far == null ? far : far + record.far!.span,
    farCount: record.far == null ? farCount : farCount + 1,
    link: record.link == null ? link : link + record.link!,
    farInFlight: farInFlight + (record.far?.inFlight ?? 0),
    farInFlightCount: farInFlightCount + (record.far?.inFlight == null ? 0 : 1),
    settle: record.settle == null ? settle : settle + record.settle!,
    settleCount: record.settle == null ? settleCount : settleCount + 1,
    farInbound: switch (record.far?.inboundWait) {
      final wait? => farInbound + wait,
      null => farInbound,
    },
    farInboundCount: record.far?.inboundWait == null
        ? farInboundCount
        : farInboundCount + 1,
  );

  /// Mean call time at the `Agent` boundary, or null for an operation never
  /// called — null rather than zero, so "never happened" and "was instant"
  /// stay different answers.
  Duration? get mean => _per(total, count);

  /// Mean wait for a window slot per exchange.
  Duration? get meanQueueWait => _per(queueWait, exchanges);

  /// Mean time on the wire per exchange — the request out, the peer's own
  /// work, and the reply back.
  Duration? get meanWireTime => _per(wire, exchanges);

  /// Mean time the peer spent per call that reported one, or null when none
  /// did. Residency: read it with [meanFarInFlight].
  Duration? get meanFarSide => _per(far, farCount);

  /// Mean link time per call that reported a far side — the request out and
  /// the reply back, measured per call and then averaged, not averaged and
  /// then subtracted.
  Duration? get meanLinkTime => _per(link, farCount);

  /// Mean number of requests the peer had in flight while serving these, or
  /// null from a peer that does not report it. A figure near 1 says
  /// [meanFarSide] is service time; a figure near the initiator's concurrency
  /// says it is residency and cannot be read as the destination's own cost.
  /// Mean time between having a reply's bytes and finishing the call, per
  /// call that measured it, or null when none did — a `readFile`-only
  /// operation has no single reply to stamp, and null there is the honest
  /// answer rather than zero.
  Duration? get meanSettle => _per(settle, settleCount);

  /// Mean time the peer was starved of this operation's inbound frames, per
  /// call that reported it, or null when none did — which is every operation
  /// that sends nothing but its request.
  Duration? get meanFarInbound => _per(farInbound, farInboundCount);

  double? get meanFarInFlight =>
      farInFlightCount == 0 ? null : farInFlight / farInFlightCount;

  AgentOpStats _with({
    int? count,
    Duration? total,
    Duration? max,
    int? bytes,
    int? exchanges,
    Duration? queueWait,
    Duration? wire,
    Duration? far,
    int? farCount,
    Duration? link,
    int? farInFlight,
    int? farInFlightCount,
    Duration? settle,
    int? settleCount,
    Duration? farInbound,
    int? farInboundCount,
  }) => AgentOpStats(
    count: count ?? this.count,
    total: total ?? this.total,
    max: max ?? this.max,
    bytes: bytes ?? this.bytes,
    exchanges: exchanges ?? this.exchanges,
    queueWait: queueWait ?? this.queueWait,
    wire: wire ?? this.wire,
    far: far ?? this.far,
    farCount: farCount ?? this.farCount,
    link: link ?? this.link,
    farInFlight: farInFlight ?? this.farInFlight,
    farInFlightCount: farInFlightCount ?? this.farInFlightCount,
    settle: settle ?? this.settle,
    settleCount: settleCount ?? this.settleCount,
    farInbound: farInbound ?? this.farInbound,
    farInboundCount: farInboundCount ?? this.farInboundCount,
  );

  static Duration? _per(Duration value, int count) =>
      count == 0 ? null : Duration(microseconds: value.inMicroseconds ~/ count);
}

/// What one replica's `Agent` cost over a run, by operation.
class ReplicaMetrics {
  /// Which replica this is, as SPEC §4.2's `hello` names it — `'A'` or `'B'`.
  final String side;

  /// Whether this replica was reached over a transport (SPEC §4.1). What it
  /// changes is how every other number here should be read: on a remote side
  /// an operation's [AgentOpStats.mean] is a round trip, on a local one it is
  /// a syscall, and the two differ by orders of magnitude without differing
  /// in type.
  final bool remote;

  /// Per-operation cost. An operation this run never performed is absent, not
  /// present-and-zero — see [AgentOp].
  final Map<AgentOp, AgentOpStats> ops;

  /// Protocol bytes written to and read from this replica's transport,
  /// framing included — zero for a local replica, which has no wire.
  final int wireBytesSent;
  final int wireBytesReceived;

  /// How many times the transport was handed a buffer to write, and how many
  /// protocol frames those buffers spelled (SPEC §17).
  ///
  /// Two numbers rather than one because they are only equal while nothing
  /// coalesces: a `send` is a flush, which on a link with any latency costs
  /// about one of them, while a frame is a unit of protocol. Measuring both
  /// is what turns "we could batch these" from a calculation over an assumed
  /// frame count into an observation — [meanFrameBytes] and [framesPerSend]
  /// say directly how much is riding on each flush.
  final int sends;
  final int framesSent;

  /// What this side's `FlushedSink` actually did with those sends (SPEC
  /// §17), or null for a transport with no sink to flush.
  ///
  /// The numbers [sends] and [framesSent] cannot give, and the reason they
  /// exist: since task 9d2158 `FlushedSink` drains everything queued behind
  /// an in-flight write into one of them, which happens *below* the point
  /// [sends] is counted at, so no arithmetic up here can see it.
  ///
  /// **Null rather than zero**, because a channel that does not write to a
  /// sink — an in-memory pair — has no write to count, and zero there would
  /// read as the one outcome these figures exist to detect.
  final SinkWriteStats? writeStats;

  /// The peer's own cumulative wait on *its* sink, as of the last reply that
  /// carried the figure, or null from a peer that does not report it.
  ///
  /// **Because `far` stops one line before the peer's reply is written.** The
  /// wait that reply then serves behind the peer's other senders falls
  /// outside the peer's span and lands inside what this side calls the link.
  /// A frame cannot carry the cost of its own flush, so this is the session
  /// total instead: read against [farTime] — the only other peer-side sum —
  /// it says how much of what the peer did is missing from what the peer
  /// reported.
  final Duration? peerSendWait;

  /// How long this replica's transport had nothing to carry, per phase, and
  /// how long it had something outstanding and was waiting for it (SPEC §17).
  ///
  /// **Two figures rather than one, because the old single one was biased.**
  /// A send is a span but a receive is a point event, so every byte arriving
  /// contributed no busy time and the whole of an inbound transfer read as
  /// silence. These are measured from what this side *has outstanding*
  /// instead, which is a state it knows at every instant rather than
  /// something it infers from the gaps between events:
  ///
  /// - [quiet] — no send in flight and no operation open. The link had
  ///   nothing to do, and this is the figure that speaks to concurrency.
  /// - [awaiting] — no send in flight but an operation still open. This side
  ///   is waiting on the peer or the link, and more callers will not help.
  ///
  /// A phase absent from either is one during which the connection was never
  /// measured rather than one that was never idle. Both empty for a local
  /// replica, which has no wire.
  final Map<RunPhase, Duration> quiet;
  final Map<RunPhase, Duration> awaiting;

  const ReplicaMetrics({
    required this.side,
    required this.remote,
    required this.ops,
    required this.wireBytesSent,
    required this.wireBytesReceived,
    this.sends = 0,
    this.framesSent = 0,
    this.writeStats,
    this.peerSendWait,
    this.quiet = const {},
    this.awaiting = const {},
  });

  /// Every operation's calls summed: on a remote replica, the run's total
  /// round-trip count, which is the number the mobile case lives or dies by.
  int get opCount => ops.values.fold(0, (sum, stats) => sum + stats.count);

  /// Every operation's wall time summed. Not the same as the run's elapsed
  /// time even for a single side — the two sides' scans overlap, and a copy's
  /// `readFile` on one side runs inside the other's `writeFile`.
  Duration get opTime =>
      ops.values.fold(Duration.zero, (sum, stats) => sum + stats.total);

  /// File content moved in either direction (SPEC §7.2).
  int get payloadBytes => ops.values.fold(0, (sum, stats) => sum + stats.bytes);

  /// Every operation's wait for a window slot summed (SPEC §17). Read against
  /// [opTime]: the share of an operation's life spent queued rather than
  /// exchanging.
  Duration get queueWait =>
      ops.values.fold(Duration.zero, (sum, stats) => sum + stats.queueWait);

  /// Every operation's time on the wire summed.
  Duration get wireTime =>
      ops.values.fold(Duration.zero, (sum, stats) => sum + stats.wire);

  /// Every exchange's link time summed, over the calls whose peer reported a
  /// span.
  Duration get linkTime =>
      ops.values.fold(Duration.zero, (sum, stats) => sum + stats.link);

  /// Every reported far-side span summed — the peer's own time over the same
  /// calls, and **the only figure [peerSendWait] may be read against.**
  ///
  /// Both are peer-side sums over overlapping spans; [linkTime] is a sum over
  /// this side's concurrent calls and is a different kind of quantity, so
  /// putting the two in one sentence invites a ratio that means nothing.
  Duration get farTime =>
      ops.values.fold(Duration.zero, (sum, stats) => sum + stats.far);

  /// Every exchange's settle time summed — this side's own time between
  /// having a reply and finishing the call, over the calls that measured it.
  ///
  /// Read against [wireTime] rather than against [linkTime]: both are sums
  /// over this side's concurrent calls, where [linkTime] is what is left of
  /// `wire` after the peer's own span and a different population.
  Duration get settleTime =>
      ops.values.fold(Duration.zero, (sum, stats) => sum + stats.settle);

  /// Mean bytes per frame sent, zero when nothing was sent. The size the
  /// protocol actually put on the link, framing included.
  double get meanFrameBytes => framesSent == 0 ? 0 : wireBytesSent / framesSent;

  /// Frames per flush. One until something coalesces them; the number the
  /// coalescing case is judged by afterwards.
  double get framesPerSend => sends == 0 ? 0 : framesSent / sends;

  /// Frames per actual write — what [framesPerSend] would say if [sends] were
  /// counted below the coalescing instead of above it (SPEC §17).
  ///
  /// **A poor summary of its own subject, kept for continuity.** It moved
  /// 1.00 → 1.15 on the run where the effect it exists to detect moved ~2×,
  /// because a mean over every write is diluted by the majority that drain
  /// with nothing queued. [SinkWriteStats.batches] is the figure to read.
  /// Null when this side reported no writes, and null rather than 1 when it
  /// reported zero, since "nothing was written" is not a ratio.
  double? get framesPerWrite => switch (writeStats?.writes) {
    null || 0 => null,
    final count => framesSent / count,
  };

  /// Flushes per `Agent` operation — how many times this replica's exchanges
  /// made the transport wait on the link, per unit of work asked of it.
  ///
  /// An operation's floor is one round trip, so a figure near 1 says the
  /// protocol is spending what the work costs and a figure above it says an
  /// operation is paying for several exchanges. Either way it is what an
  /// operation's mean should be divided by before it is compared to a link's
  /// latency.
  double get sendsPerOp => opCount == 0 ? 0 : sends / opCount;

  /// Every phase's quiet and awaiting time summed.
  Duration get quietTime =>
      quiet.values.fold(Duration.zero, (sum, value) => sum + value);

  Duration get awaitingTime =>
      awaiting.values.fold(Duration.zero, (sum, value) => sum + value);
}

/// What one run cost, and where (SPEC §17).
///
/// This is measurement, not behaviour: nothing in the engine reads these
/// numbers or changes what it does because of them. They exist because the
/// mobile head's cost is dominated by *per-path round trips and fsyncs*
/// rather than by bytes — a tree of 14k files under 50 KB each moves less
/// data than one video and takes far longer — and no existing event says so.
/// `RunSummaryEvent` counts outcomes, `ScanReasonTally` counts scan branches;
/// neither can tell a run that was slow because the link was slow from one
/// that was slow because it made 28,000 sequential requests to do 14,000
/// files' worth of work.
///
/// One run's measurements, as of whenever it was taken.
///
/// A snapshot, not a live view: a head that wants a progress ticker takes a
/// fresh one each time rather than holding this and watching it change.
class RunMetrics {
  /// Wall time since the recorder was created, which a head starts at the
  /// top of the run. Not the sum of [phases] — the gaps between phases are
  /// the run's own bookkeeping, and a phase still running is not in there at
  /// all.
  final Duration elapsed;

  /// How long each completed phase took. A phase the run never reached — a
  /// fatal error before `apply`, a `compact` skipped because nothing was
  /// committed (SPEC §8.2) — is absent rather than zero, so "0 ms" always
  /// means "ran and was instant" and never "never happened".
  final Map<RunPhase, Duration> phases;

  /// Each replica the run drove, keyed by [ReplicaMetrics.side]. Empty on a
  /// run whose agents were never wrapped, one entry for each side otherwise.
  final Map<String, ReplicaMetrics> replicas;

  const RunMetrics({
    required this.elapsed,
    required this.phases,
    required this.replicas,
  });

  /// Both sides' operations summed — the run's total request count.
  int get opCount =>
      replicas.values.fold(0, (sum, replica) => sum + replica.opCount);

  /// Both sides' wire traffic summed, framing included.
  int get wireBytes => replicas.values.fold(
    0,
    (sum, replica) => sum + replica.wireBytesSent + replica.wireBytesReceived,
  );
}
