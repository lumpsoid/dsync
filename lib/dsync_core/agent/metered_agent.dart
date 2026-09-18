import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
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
  MeteredAgent(
    this._inner, {
    required this.side,
    required this.metrics,
    required bool remote,
  }) {
    if (remote) metrics.markRemote(side);
  }

  @override
  Future<ReplicaInfo> hello() => _timed(AgentOp.hello, _inner.hello);

  @override
  Future<void> lock() => _timed(AgentOp.lock, _inner.lock);

  @override
  Future<void> unlock() => _timed(AgentOp.unlock, _inner.unlock);

  @override
  Future<ScanResult> scan(RuleSet rules) =>
      _timed(AgentOp.scan, () => _inner.scan(rules));

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
  @override
  Stream<List<int>> readFile(String path) async* {
    final operation = metrics.beginOp(side, AgentOp.readFile);
    try {
      await for (final chunk in _inner.readFile(path)) {
        operation.countBytes(chunk.length);
        yield chunk;
      }
    } finally {
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
