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
class AgentOpStats {
  /// How many times the operation was called.
  final int count;

  /// Summed wall time of every call, measured at the `Agent` boundary — for
  /// a local replica the filesystem call, and for a remote one the wait for a
  /// window slot plus the exchange, which [queueWait] and [wireTime] split
  /// apart.
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

  /// Summed time these calls spent waiting for a `RequestWindow` slot rather
  /// than on the wire (SPEC §17) — the path predecessor they queued behind,
  /// the window's bound, or a barrier ahead of them.
  ///
  /// Zero on a local replica, which has no window, and zero on a remote one
  /// whose window was never full.
  ///
  /// **This is the split a mean stopped being readable without.** Since task
  /// 0f7dfc several operations are outstanding at once, so [total] bundles
  /// queueing with the exchange itself, and the two have opposite fixes: a
  /// mean that rose because [queueWait] rose says "we are queueing — the
  /// window or the concurrency is the bound", while one that rose because
  /// [wireTime] rose says "the exchange itself got dearer". A single figure
  /// cannot tell those apart, and choosing between them from arithmetic over
  /// the figure is how the wrong one gets picked.
  final Duration queueWait;

  /// Summed time the *peer* spent on these calls, as the peer measured it:
  /// from the request frame arriving at `AgentServer` to its reply going out
  /// (SPEC §17).
  ///
  /// **This is the second half of a figure that used to be one.** A remote
  /// [wireTime] covers the request going out, whatever the far side did, and
  /// the reply coming back — three things with three different fixes. On the
  /// measured run `writeFile` cost 40.9 ms an action and nothing could say
  /// how much of it was the destination's own write and fsync. Subtracting
  /// this leaves the link: `wireTime - farSide`.
  ///
  /// For [AgentOp.writeFile] the peer's span starts when the request frame
  /// lands, so it *includes* draining the inbound file bytes — the transfer
  /// is inside this figure, not outside it. What it excludes is the request
  /// going out and the reply coming back, which is the part this split
  /// exists to isolate.
  final Duration farSide;

  /// How many of these calls came back with a [farSide] figure at all.
  ///
  /// Separate from [count] because **absent is not zero**. A peer that does
  /// not report its own span — an older build, or an operation like `scan`
  /// and `readFile` whose reply is not a success control frame — must not
  /// read as a destination that cost nothing, which is precisely the
  /// conclusion this measurement exists to rule out. A mean over zero
  /// samples is no mean, and the report says so rather than printing 0 ms.
  final int farSideCount;

  const AgentOpStats({
    required this.count,
    required this.total,
    required this.max,
    required this.bytes,
    this.queueWait = Duration.zero,
    this.farSide = Duration.zero,
    this.farSideCount = 0,
  });

  /// Zero of everything — the starting point [merge] accumulates onto.
  static const none = AgentOpStats(
    count: 0,
    total: Duration.zero,
    max: Duration.zero,
    bytes: 0,
  );

  /// This plus one more call of [elapsed] carrying [bytes] payload bytes.
  AgentOpStats merge(Duration elapsed, int bytes) => AgentOpStats(
    count: count + 1,
    total: total + elapsed,
    max: elapsed > max ? elapsed : max,
    bytes: this.bytes + bytes,
    queueWait: queueWait,
    farSide: farSide,
    farSideCount: farSideCount,
  );

  /// This plus one more call's wait for a window slot.
  ///
  /// Separate from [merge] because the two are recorded by different things
  /// at different moments: the window reports a wait as the operation is
  /// admitted, while the span is recorded when it ends. A call whose wait
  /// arrived but whose span has not yet shows here with [count] still behind
  /// — which is the honest reading of an operation still running.
  AgentOpStats mergeQueueWait(Duration wait) => AgentOpStats(
    count: count,
    total: total,
    max: max,
    bytes: bytes,
    queueWait: queueWait + wait,
    farSide: farSide,
    farSideCount: farSideCount,
  );

  /// This plus one more call whose peer reported [span] as its own time.
  ///
  /// Separate from [merge] for the same reason [mergeQueueWait] is: the
  /// figure arrives from a different collaborator at a different instant —
  /// off the reply, before the operation's own span has closed.
  AgentOpStats mergeFarSide(Duration span) => AgentOpStats(
    count: count,
    total: total,
    max: max,
    bytes: bytes,
    queueWait: queueWait,
    farSide: farSide + span,
    farSideCount: farSideCount + 1,
  );

  /// Mean call time, [Duration.zero] for an operation never called.
  ///
  /// On a remote replica this is what one call cost end to end. It is *not*
  /// the link's round-trip time any more — see [queueWait]; [meanWireTime] is
  /// the figure that answers that.
  Duration get mean => _per(total);

  /// [total] with the queueing taken out: what these calls spent on the
  /// exchange itself.
  ///
  /// Clamped at zero rather than allowed to go negative. The two figures are
  /// recorded at different instants by different collaborators, so a snapshot
  /// taken mid-operation can hold a wait whose span has not landed yet, and a
  /// report that showed "-3 ms" would look like a bug in the code being
  /// measured rather than in the moment it was measured.
  Duration get wireTime =>
      total > queueWait ? total - queueWait : Duration.zero;

  /// Mean wait for a window slot per call.
  Duration get meanQueueWait => _per(queueWait);

  /// Mean time on the wire per call — for a remote replica, one exchange:
  /// the request out, the peer's own work, and the reply back. [meanFarSide]
  /// is the middle term of those three when the peer reports it.
  Duration get meanWireTime => _per(wireTime);

  /// Mean time the peer spent per call that reported one, or null when none
  /// did — null rather than zero, for the reason [farSideCount] gives.
  Duration? get meanFarSide => farSideCount == 0
      ? null
      : Duration(microseconds: farSide.inMicroseconds ~/ farSideCount);

  /// [meanWireTime] with the peer's own time taken out: what one exchange
  /// cost the *link*, request out and reply back. Null when the peer did not
  /// report, and clamped at zero for the reason [wireTime] is — the two
  /// figures are sampled at different instants.
  Duration? get meanLinkTime {
    final far = meanFarSide;
    if (far == null) return null;
    final wire = meanWireTime;
    return wire > far ? wire - far : Duration.zero;
  }

  Duration _per(Duration value) => count == 0
      ? Duration.zero
      : Duration(microseconds: value.inMicroseconds ~/ count);
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

  /// How many `add`-and-`flush` pairs those buffers actually became (SPEC
  /// §17), or null for a transport with no sink to flush.
  ///
  /// The third number the other two cannot give, and the reason it exists:
  /// since task 9d2158 `FlushedSink` drains everything queued behind an
  /// in-flight write into one of them, and that happens *below* the point
  /// [sends] is counted at, so no arithmetic over [sends] and [framesSent]
  /// can see it. [framesPerWrite] is what says whether the coalescing bit.
  ///
  /// **Null rather than zero**, because a channel that does not write to a
  /// sink — an in-memory pair — has no write to count, and zero there would
  /// read as the one outcome this figure exists to detect.
  final int? writes;

  /// How long this replica's transport carried nothing, per phase (SPEC §17).
  ///
  /// The gaps between one byte moving and the next, so a phase absent here
  /// is one during which the connection was never measured rather than one
  /// that was never idle. Zero for a local replica, which has no wire.
  ///
  /// **This is the figure that chooses the next optimization.** A phase that
  /// used a fraction of its link and was idle for the rest was waiting, and
  /// the fix is fewer round trips or more of them in flight; a phase that
  /// used a fraction of its link with no idle time was busy, and the fix is
  /// elsewhere entirely. Nothing else here can tell those apart — a byte
  /// count cannot, because both move the same bytes.
  final Map<RunPhase, Duration> idle;

  const ReplicaMetrics({
    required this.side,
    required this.remote,
    required this.ops,
    required this.wireBytesSent,
    required this.wireBytesReceived,
    this.sends = 0,
    this.framesSent = 0,
    this.writes,
    this.idle = const {},
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

  /// Every operation's time on the wire summed — [opTime] with the queueing
  /// taken out.
  Duration get wireTime =>
      ops.values.fold(Duration.zero, (sum, stats) => sum + stats.wireTime);

  /// Mean bytes per frame sent, zero when nothing was sent. The size the
  /// protocol actually put on the link, framing included.
  double get meanFrameBytes => framesSent == 0 ? 0 : wireBytesSent / framesSent;

  /// Frames per flush. One until something coalesces them; the number the
  /// coalescing case is judged by afterwards.
  double get framesPerSend => sends == 0 ? 0 : framesSent / sends;

  /// Frames per actual write — what [framesPerSend] would say if [sends] were
  /// counted below the coalescing instead of above it (SPEC §17).
  ///
  /// One while nothing batches, and the figure task 9d2158's phase 3 is
  /// judged by: it rises exactly as far as `FlushedSink` found frames queued
  /// behind a write in flight. Null when this side reported no write count,
  /// and null rather than 1 when it reported zero writes, since "nothing was
  /// written" is not a ratio.
  double? get framesPerWrite => switch (writes) {
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

  /// Every phase's idle time summed.
  Duration get idleTime =>
      idle.values.fold(Duration.zero, (sum, value) => sum + value);
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
