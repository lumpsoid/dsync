import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/bucket_digests.dart';
import 'package:dsync/dsync_core/models/changed_scan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/scan/scan_session.dart';
import 'package:dsync/dsync_core/run/elapsed.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';

/// An [Agent] decorator that times every operation into a
/// [RunMetricsRecorder] (SPEC §17) and otherwise changes nothing.
///
/// **The `Agent` boundary is the right place to measure.** It is the one seam
/// every unit of per-path work crosses, on both a local and a remote replica,
/// so one wrapper answers "what did this run actually ask of each side, and
/// what did each request cost" without the engine knowing it is being
/// watched. Instrumenting `RemoteAgent` from the inside was the alternative:
/// it would see only remote replicas, which is exactly half the question —
/// the phone's local side pays an fsync per `archiveCommitUpsert` (SPEC §8.2),
/// and a report that cannot see that blames the network for the filesystem.
///
/// **A decorator, not a new interface** (CLAUDE.md: "if a dependency is
/// already abstract, fake that"). [Agent] is already the abstraction; this
/// adds a hop that a head installs and nothing else can tell apart.
///
/// Wrapping is opt-in at construction: a run whose agents are not wrapped
/// records phases and nothing else, which is what `RunController`'s own tests
/// get.
class MeteredAgent implements Agent {
  final Agent _inner;

  /// Which replica this is, as [ReplicaMetrics.side] reports it — `'A'` or
  /// `'B'`, matching the `side` the `ReplicaSpec` already carries (SPEC
  /// §4.2).
  final String side;

  /// Where this agent's operations are recorded (SPEC §17). The same
  /// recorder both sides and both channels write to, so one report covers
  /// the whole run.
  final RunMetricsRecorder metrics;

  /// [remote] is passed in rather than inferred, because nothing visible from
  /// here distinguishes a `LocalAgent` from a `RemoteAgent` — that is the
  /// point of [Agent] (SPEC §4.1) — and the caller that built the agent is
  /// the one place that knows.
  ///
  /// [elapsed] is the reading the held/own split of [readFile] is taken on,
  /// injectable for the reason `FlushedSink`'s is: a test can then assert the
  /// split with plain values instead of sleeping. Defaults to a `Stopwatch`
  /// started here, which is all a real run needs — the split is a difference
  /// of two readings of it, never an absolute.
  MeteredAgent(
    this._inner, {
    required this.side,
    required this.metrics,
    required bool remote,
    Elapsed? elapsed,
  }) : _elapsed = elapsed ?? stopwatchElapsed() {
    if (remote) metrics.markRemote(side);
  }

  final Elapsed _elapsed;

  @override
  Future<ReplicaInfo> hello() => _timed(AgentOp.hello, _inner.hello);

  @override
  Future<void> lock() => _timed(AgentOp.lock, _inner.lock);

  @override
  Future<void> unlock() => _timed(AgentOp.unlock, _inner.unlock);

  /// All three of SPEC §6.1's phases are recorded under [AgentOp.scan], so a
  /// remote replica's `scan` count is three rather than one — or two, when
  /// every bucket agreed and phase 3 never happened.
  ///
  /// One op rather than three, because they are one thing to a reader of
  /// SPEC §17's table: "what did learning this replica's state cost". Three
  /// rows would split a figure nobody wants split and would make the count
  /// column, which is how a reader spots an operation that ran more often
  /// than they expected, read as three ones.
  @override
  Future<ScanSession> scan(RuleSet rules) async => _MeteredScanSession(
    await _timed(AgentOp.scan, () => _inner.scan(rules)),
    this,
  );

  /// Times the whole transfer, not the call that starts it: [Agent.readFile]
  /// returns immediately and the bytes arrive afterwards, so the operation's
  /// real span is from the first pull to the last — which for a remote
  /// replica is the request, the reply and every `fileBytes` frame between
  /// them.
  ///
  /// A generator rather than a `Stream.map` with a `listen`/`onDone` pair,
  /// so a consumer that stops early — which SPEC §7.6 makes the normal case,
  /// and which `RemoteAgent.readFile` documents at length — closes the
  /// operation through this `finally` as it goes, instead of leaving it open
  /// for the rest of the run.
  ///
  /// **And the span is split where the consumer takes over (task 9d2158).**
  /// It contains two unrelated things: the replica producing bytes, and this
  /// generator parked on a `yield` because its consumer had not asked for the
  /// next chunk. Since the read-ahead landed, that second term is the send
  /// path applying backpressure up through the prefetch buffer — `ReadAhead`
  /// pauses the source at 64 KiB a stream (SPEC §7.2) — so a `readFile` mean
  /// that rose because the wire got slower reads identically to one that rose
  /// because the flash did, and the fixes are opposite. The clock therefore
  /// runs only across the `yield`, which is exactly the instants the consumer
  /// owns, and is reported as `held`.
  ///
  /// Measured here rather than in `ReadAhead`, for the reason every other
  /// split in SPEC §17 is measured where it is: this is the one object that
  /// sees both sides of the handover, and it already sees every call. It is
  /// also the only place that covers the unbuffered path, where `Applier`
  /// hands `source.readFile(path)` straight to the write with no prefetch in
  /// between.
  @override
  Stream<List<int>> readFile(String path) async* {
    final operation = metrics.beginOp(side, AgentOp.readFile);
    var held = Duration.zero;
    // Set while this generator is parked on a `yield`, so the interval is
    // still chargeable if the consumer cancels instead of coming back.
    Duration? handedAt;
    try {
      await for (final chunk in _inner.readFile(path)) {
        operation.countBytes(chunk.length);
        handedAt = _elapsed();
        yield chunk;
        held += _elapsed() - handedAt;
        handedAt = null;
      }
    } finally {
      // A consumer that walked away held this call for the wait it never came
      // back from, and dropping that would credit the read with it.
      if (handedAt case final at?) held += _elapsed() - at;
      operation.countHeld(held);
      operation.end();
    }
  }

  /// Counts [data] as it is consumed by the inner agent rather than after the
  /// fact, so a transfer that fails part-way is credited with the bytes it
  /// did move — the size mismatch `Applier` then raises is about a file, and
  /// this report is about the wire. Credited to *this* operation's handle,
  /// not to whatever is open on this side, since several are (SPEC §17).
  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) async {
    final operation = metrics.beginOp(side, AgentOp.writeFile);
    try {
      return await _inner.writeFile(
        path,
        data.map((chunk) {
          operation.countBytes(chunk.length);
          return chunk;
        }),
        mtime: mtime,
        mode: mode,
      );
    } finally {
      operation.end();
    }
  }

  @override
  Future<void> delete(String path) =>
      _timed(AgentOp.delete, () => _inner.delete(path));

  @override
  Future<void> removeEmptyDirs(String path) =>
      _timed(AgentOp.removeEmptyDirs, () => _inner.removeEmptyDirs(path));

  /// One call, one measurement, however many paths it carried — so the mean
  /// SPEC §17 reports is what an exchange cost, not what a path cost. The
  /// paths-per-batch figure the mean has to be read against is `Applier`'s
  /// and is fixed there.
  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) =>
      _timed(AgentOp.archiveCommit, () => _inner.archiveCommit(commits));

  @override
  Future<void> compact() => _timed(AgentOp.compact, _inner.compact);

  @override
  Future<void> disconnect() => _timed(AgentOp.disconnect, _inner.disconnect);

  /// Records [op]'s span around [body], including a failed call: a run that
  /// spent thirty seconds on requests that all threw is a run whose report
  /// should say thirty seconds.
  Future<T> _timed<T>(AgentOp op, Future<T> Function() body) async {
    final operation = metrics.beginOp(side, op);
    try {
      return await body();
    } finally {
      operation.end();
    }
  }
}

/// A [ScanSession] whose two further phases are timed the same way the
/// operation that opened it was.
///
/// Phase 1 is already measured by the `scan` call that returned this, so
/// [changed] costs nothing and is passed straight through.
class _MeteredScanSession implements ScanSession {
  final ScanSession _inner;
  final MeteredAgent _agent;

  _MeteredScanSession(this._inner, this._agent);

  @override
  ChangedScan get changed => _inner.changed;

  @override
  Future<BucketDigests> digests({
    required int bucketCount,
    required List<String> peerChangedPaths,
  }) => _agent._timed(
    AgentOp.scan,
    () => _inner.digests(
      bucketCount: bucketCount,
      peerChangedPaths: peerChangedPaths,
    ),
  );

  @override
  Future<List<ScanEntry>> entriesIn(List<int> buckets) =>
      _agent._timed(AgentOp.scan, () => _inner.entriesIn(buckets));
}
