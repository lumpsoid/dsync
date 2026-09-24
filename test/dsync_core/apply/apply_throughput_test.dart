@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/apply/applier.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/exchange_record.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_root.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/sink_write_stats.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:test/test.dart';

/// Where an overwrite pull over `peer://` spends its time, driven through the
/// real `Applier`, `RemoteAgent` and `AgentServer` with the phone replaced by
/// a fake whose costs are stated (task 7080d6).
///
/// The phone bench measured ~230–260 copies a second at every concurrency
/// from 4 to 32, with the initiator's `writeFile` mean growing in step with
/// it — one serial stage of ~4 ms and the rest queueing. These pin which
/// kind of cost does that and which does not.
void main() {
  test('a far side that is only slow, however slow, does not cap the apply: '
      'throughput follows concurrency', () async {
    // A 60 ms round trip (the phone's measured `link`, and more) and a
    // 12 ms handler (its measured `far`) on every exchange: writes, marks
    // and commit batches alike. None of it is serial, so an apply with a
    // barrier of its own — a mark or a commit batch the workers wait out,
    // a per-file wait on the source, the window, the sink — would stop
    // gaining from more workers.
    Future<_Run> run(int concurrency) => _pull(
      concurrency: concurrency,
      files: 256,
      link: const Duration(milliseconds: 30),
      handler: const Duration(milliseconds: 12),
    );
    final four = await run(4);
    final sixteen = await run(16);
    printOnFailure('$four\n$sixteen');

    // Four times the workers, ideally four times the rate; what a serial
    // stage allows is the same rate.
    expect(sixteen.opsPerSecond, greaterThan(four.opsPerSecond * 2.5));
    // And each write still costs one exchange, not a queue.
    expect(
      sixteen.meanWrite.inMicroseconds,
      lessThan(four.meanWrite.inMicroseconds * 1.5),
    );
  });

  test(
    'a serial cost per read on the served end reproduces the phone: flat '
    'throughput at that cost, and a write mean that grows with concurrency',
    () async {
      // What the phone bench showed and nothing more: every read off the
      // served connection is taken one after the other at a fixed cost, in
      // reads no bigger than the 8 KiB `RawSecureSocket` hands over at a
      // time, and the handler's own 12 ms runs in parallel behind it.
      final runs = [
        for (final concurrency in [4, 16, 32])
          await _pull(
            concurrency: concurrency,
            files: 128,
            ingest: const Duration(milliseconds: 1),
            handler: const Duration(milliseconds: 12),
          ),
      ];
      printOnFailure(runs.join('\n'));
      final [four, _, thirtyTwo] = runs;

      for (final run in runs) {
        // The rate is the serial stage's — reads per file times cost per
        // read — whatever the concurrency...
        expect(run.opsPerSecond, closeTo(run.servedBound, run.servedBound / 4));
        // ...and the served end sees a handful of writes, never the window.
        expect(run.meanServed, lessThan(6));
      }
      expect(
        thirtyTwo.opsPerSecond,
        closeTo(four.opsPerSecond, four.opsPerSecond / 4),
      );
      // Eight times the workers, and the initiator's write mean is Little's
      // law: the extra workers wait in its `link`, not at the served end.
      expect(
        thirtyTwo.meanWrite.inMicroseconds,
        greaterThan(four.meanWrite.inMicroseconds * 5),
      );
    },
  );
}

const _fileSize = 13 * 1024;

/// One overwrite pull of [files] copies of [_fileSize] bytes, from a source
/// that costs nothing to a served replica behind [link] and [ingest].
Future<_Run> _pull({
  required int concurrency,
  required int files,
  Duration link = Duration.zero,
  Duration ingest = Duration.zero,
  Duration handler = Duration.zero,
}) async {
  final (clientEnd, serverEnd) = InMemoryChannel.pair();
  final phone = _TimedReplica(handler);
  final served = _ServedEnd(serverEnd, link: link, ingest: ingest);
  unawaited(AgentServer().serve(served, (_) => phone));

  final writes = <ExchangeRecord>[];
  final remote = RemoteAgent(
    _Delayed(clientEnd, link),
    _spec,
    onExchange: (record) {
      if (record.op == AgentOp.writeFile) writes.add(record);
    },
  );
  await remote.hello();

  final actions = [
    for (var i = 0; i < files; i++)
      PlanAction(path: 'd${i % 50}/f$i', type: ActionType.copyAtoB),
  ];
  final entries = [
    for (final action in actions)
      ScanEntry(
        path: action.path,
        reason: ScanReason.modified,
        size: _fileSize,
        mtime: 1,
        mode: 420,
        hash: 'h',
      ),
  ];

  final clock = Stopwatch()..start();
  final result = await Applier(concurrency: concurrency).apply(
    Plan(actions: actions, conflicts: const []),
    entries,
    const [],
    _Source(),
    remote,
  );
  clock.stop();
  await remote.disconnect();

  expect(result.failed, isEmpty);
  expect(result.applied, hasLength(files));
  final meanWrite =
      writes.fold(Duration.zero, (sum, record) => sum + record.wire) ~/
      writes.length;
  return _Run(
    concurrency: concurrency,
    elapsed: clock.elapsed,
    meanWrite: meanWrite,
    meanServed: phone.meanInFlight,
    files: files,
    reads: served.reads,
    ingestBusy: served.busy,
  );
}

const _spec = ReplicaSpec(
  rootPath: '/phone',
  profileId: 'bench',
  side: 'b',
  jobs: 1,
);

class _Run {
  final int concurrency;
  final Duration elapsed;
  final Duration meanWrite;
  final double meanServed;
  final int files;
  final int reads;
  final Duration ingestBusy;

  const _Run({
    required this.concurrency,
    required this.elapsed,
    required this.meanWrite,
    required this.meanServed,
    required this.files,
    required this.reads,
    required this.ingestBusy,
  });

  double get opsPerSecond => files / (elapsed.inMicroseconds / 1e6);

  double get readsPerFile => reads / files;

  /// What one read on the served end actually cost.
  Duration get meanRead => ingestBusy ~/ reads;

  /// The rate a serial stage of [meanRead] per read allows, and nothing else.
  double get servedBound => 1e6 / (readsPerFile * meanRead.inMicroseconds);

  @override
  String toString() =>
      'c$concurrency: ${opsPerSecond.round()} ops/s, '
      'writeFile mean ${(meanWrite.inMicroseconds / 1000).toStringAsFixed(1)} ms, '
      'served in flight ${meanServed.toStringAsFixed(1)}, '
      'reads/file ${readsPerFile.toStringAsFixed(2)}, '
      'read ${(meanRead.inMicroseconds / 1000).toStringAsFixed(2)} ms, '
      'serial bound ${servedBound.toStringAsFixed(0)} ops/s';
}

/// The desktop's side of a pull: every read answered at once, every commit
/// taken at once. Anything else is a call this test should never see.
class _Source implements Agent {
  @override
  Stream<List<int>> readFile(String path) => Stream.value(Uint8List(_fileSize));

  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}

/// The phone's replica, reduced to a fixed [latency] per operation, run in
/// parallel — the handler's own time, which no serial stage is part of.
class _TimedReplica implements Agent {
  final Duration latency;

  int _inFlight = 0;
  int _samples = 0;
  int _summed = 0;

  _TimedReplica(this.latency);

  /// Mean writes being handled, sampled as each one starts.
  double get meanInFlight => _samples == 0 ? 0 : _summed / _samples;

  @override
  Future<ReplicaInfo> hello() async => const ReplicaInfo(root: RootPresent());

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> unlock() async {}

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) async {
    _inFlight++;
    _samples++;
    _summed += _inFlight;
    try {
      var size = 0;
      await for (final chunk in data) {
        size += chunk.length;
      }
      await Future<void>.delayed(latency);
      return FileMetadata(size: size, mtime: mtime, mode: mode);
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) =>
      Future<void>.delayed(latency);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}

/// [Channel] whose every chunk reaches the other end [delay] later — a link
/// with latency and no bandwidth limit: chunks overlap in flight, and arrive
/// in the order they were sent because they all wait the same.
class _Delayed implements Channel {
  final Channel _inner;
  final Duration _delay;

  _Delayed(this._inner, this._delay);

  @override
  Stream<Uint8List> get input => _inner.input;

  @override
  Future<void> send(Uint8List bytes) {
    if (_delay == Duration.zero) return _inner.send(bytes);
    Timer(_delay, () => _inner.send(bytes));
    return Future.value();
  }

  @override
  SinkWriteStats? get writeStats => null;

  @override
  Future<void> close() => _inner.close();
}

/// The served end of the connection: replies go back over a [link], and
/// what arrives is read in pieces of at most [_readSize] bytes, each costing
/// [ingest] and taken one after the other.
class _ServedEnd implements Channel {
  static const _readSize = 8 * 1024;

  final Channel _inner;
  final Duration ingest;
  late final _Delayed _out;

  int reads = 0;

  /// Time spent inside the serial reads, measured rather than assumed: a
  /// timer overshoots what it was asked for, and the prediction is made from
  /// what the reads actually cost.
  Duration busy = Duration.zero;

  _ServedEnd(this._inner, {required Duration link, required this.ingest})
    : _out = _Delayed(_inner, link);

  @override
  late final Stream<Uint8List> input = _read();

  Stream<Uint8List> _read() async* {
    await for (final chunk in _inner.input) {
      for (var at = 0; at < chunk.length; at += _readSize) {
        final end = at + _readSize < chunk.length
            ? at + _readSize
            : chunk.length;
        reads++;
        if (ingest > Duration.zero) {
          final read = Stopwatch()..start();
          await Future<void>.delayed(ingest);
          busy += read.elapsed;
        }
        yield Uint8List.sublistView(chunk, at, end);
      }
    }
  }

  @override
  Future<void> send(Uint8List bytes) => _out.send(bytes);

  @override
  SinkWriteStats? get writeStats => null;

  @override
  Future<void> close() => _inner.close();
}
