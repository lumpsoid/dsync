import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/agent/request_window.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:test/test.dart';

const _testSpec = ReplicaSpec(
  rootPath: '/replica',
  profileId: 'notes',
  side: 'a',
  jobs: 2,
);

void main() {
  late _FakeAgent backing;
  late RemoteAgent remote;

  setUp(() async {
    final (clientChannel, serverChannel) = InMemoryChannel.pair();
    backing = _FakeAgent();
    unawaited(AgentServer().serve(serverChannel, (_) => backing));
    remote = RemoteAgent(clientChannel, _testSpec);
    await remote.hello();
  });

  group('hello', () {
    test('returns the ReplicaInfo the backing agent reports', () async {
      final (clientChannel, serverChannel) = InMemoryChannel.pair();
      final backingWithCommit = _FakeAgent()
        ..helloInfo = ReplicaInfo(lastCommitTime: DateTime.utc(2024, 1, 1));
      unawaited(AgentServer().serve(serverChannel, (_) => backingWithCommit));

      final info = await RemoteAgent(clientChannel, _testSpec).hello();

      // The instant survives the wire; whether it comes back UTC or local
      // depends on `DateTime.fromMicrosecondsSinceEpoch`'s default.
      expect(
        info.lastCommitTime?.isAtSameMomentAs(DateTime.utc(2024, 1, 1)),
        isTrue,
      );
    });
  });

  group("the peer's own span", () {
    test('comes back with the reply, against the operation it measured', () {
      // SPEC §17 phase 0a: an exchange's cost is the request out, whatever
      // the peer did, and the reply back. This is the middle term, and only
      // the peer can measure it.
      return _withHeldCommit((agent, backing, reported) async {
        final commit = agent.archiveCommit(const [
          ArchiveUpsert(
            ArchiveEntry(
              path: 'a.txt',
              size: 1,
              mtime: 1,
              mode: 0x81a4,
              hash: 'h',
            ),
          ),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        backing.heldCommits['a.txt']!.complete();
        await commit;

        expect(reported, hasLength(1));
        expect(reported.single.op, AgentOp.archiveCommit);
        // The hold is the floor: the peer's span contains it, and contains
        // nothing the initiator paid.
        expect(
          reported.single.span,
          greaterThanOrEqualTo(const Duration(milliseconds: 15)),
        );
      });
    });

    test('is not reported for the replies that cannot carry it', () async {
      // `scan` answers with a binary frame and `readFile` with the byte
      // stream itself (SPEC §15.3), so neither has a field to put this in.
      // They report nothing, which the recorder keeps distinguishable from
      // a peer that cost nothing.
      final reported = <({AgentOp op, Duration span})>[];
      final (clientChannel, serverChannel) = InMemoryChannel.pair();
      final peer = _FakeAgent()..fileContents['a.txt'] = utf8.encode('hi');
      unawaited(AgentServer().serve(serverChannel, (_) => peer));
      final agent = RemoteAgent(
        clientChannel,
        _testSpec,
        onFarSide: (op, span) => reported.add((op: op, span: span)),
      );

      await agent.hello();
      await agent.scan(RuleSet());
      await agent.readFile('a.txt').drain<void>();

      expect(reported.map((r) => r.op), isNot(contains(AgentOp.scan)));
      expect(reported.map((r) => r.op), isNot(contains(AgentOp.readFile)));
      // `hello` is a control-frame reply like any other, so it does report.
      expect(reported.map((r) => r.op), contains(AgentOp.hello));
    });

    test('is not reported for a failed operation', () async {
      // A failure carries an error the caller turns into an exception, and
      // there is no figure to record it against.
      final reported = <AgentOp>[];
      final (clientChannel, serverChannel) = InMemoryChannel.pair();
      final peer = _FakeAgent()..lockError = Exception('locked elsewhere');
      unawaited(AgentServer().serve(serverChannel, (_) => peer));
      final agent = RemoteAgent(
        clientChannel,
        _testSpec,
        onFarSide: (op, _) => reported.add(op),
      );
      await agent.hello();

      await expectLater(agent.lock(), throwsA(isA<AgentOperationException>()));

      expect(reported, isNot(contains(AgentOp.lock)));
    });
  });

  group('lock / unlock', () {
    test('dispatch to the backing agent', () async {
      await remote.lock();
      expect(backing.locked, isTrue);

      await remote.unlock();
      expect(backing.locked, isFalse);
    });

    test('a remote failure surfaces as AgentOperationException', () async {
      backing.lockError = Exception('locked elsewhere');

      await expectLater(remote.lock(), throwsA(isA<AgentOperationException>()));
    });
  });

  group('scan', () {
    test('returns the entries the backing agent reports', () async {
      backing.scanResult = [
        const ScanEntry(
          path: 'a.txt',
          reason: ScanReason.created,
          size: 1,
          mtime: 1,
          mode: 420,
          // A real hex digest, not a placeholder: the scan payload carries
          // the hash as the bytes it spells (SPEC §15.3), so a `hash` that is
          // not hex is refused at the encoder.
          hash: 'deadbeef',
        ),
      ];

      final entries = (await remote.scan(RuleSet())).entries;

      expect(entries.single.path, 'a.txt');
      expect(entries.single.status, ScanStatus.created);
      expect(entries.single.hash, 'deadbeef');
    });
  });

  group('readFile', () {
    test('streams the bytes the backing agent holds', () async {
      backing.fileContents['a.txt'] = utf8.encode('hello');

      final chunks = await remote.readFile('a.txt').toList();

      expect(utf8.decode(chunks.expand((c) => c).toList()), 'hello');
    });

    test('a missing file throws AgentOperationException', () async {
      await expectLater(
        remote.readFile('missing.txt').toList(),
        throwsA(isA<AgentOperationException>()),
      );
    });
  });

  group('writeFile', () {
    test('writes through and returns the resulting metadata', () async {
      final metadata = await remote.writeFile(
        'a.txt',
        Stream.value(utf8.encode('hello')),
        mtime: 123,
        mode: 420,
      );

      expect(utf8.decode(backing.fileContents['a.txt']!), 'hello');
      expect(metadata.size, 5);
      expect(metadata.mtime, 123);
      expect(metadata.mode, 420);
    });
  });

  group('delete / removeEmptyDirs', () {
    test('dispatch with the path', () async {
      backing.fileContents['a.txt'] = utf8.encode('x');

      await remote.delete('a.txt');
      expect(backing.fileContents.containsKey('a.txt'), isFalse);

      await remote.removeEmptyDirs('a.txt');
      expect(backing.removedEmptyDirsFor, 'a.txt');
    });
  });

  group('archive commits', () {
    test('dispatch upsert and delete', () async {
      const entry = ArchiveEntry(
        path: 'a.txt',
        size: 1,
        mtime: 1,
        mode: 420,
        hash: 'h',
      );

      await remote.archiveCommit([const ArchiveUpsert(entry)]);
      expect(backing.archive['a.txt']?.hash, 'h');

      await remote.archiveCommit([const ArchiveTombstone('a.txt')]);
      expect(backing.archive.containsKey('a.txt'), isFalse);
    });
  });

  group('compact', () {
    test('dispatches to the backing agent', () async {
      await remote.compact();
      expect(backing.compacted, isTrue);
    });
  });

  group('pipelining (task 0f7dfc)', () {
    ArchiveEntry entry(String path) =>
        ArchiveEntry(path: path, size: 1, mtime: 1, mode: 420, hash: 'h');

    test('replies arriving out of order complete the right callers', () async {
      // Three commits in flight, answered back to front. Matched by arrival
      // order — what the protocol did before the request id — every caller
      // but one would be handed somebody else's answer.
      for (final path in ['a.txt', 'b.txt', 'c.txt']) {
        backing.heldCommits[path] = Completer<void>();
      }
      backing.failCommits.add('b.txt');

      final a = expectLater(
        remote.archiveCommit([ArchiveUpsert(entry('a.txt'))]),
        completes,
      );
      // The failure lands on b's caller and nobody else's: SPEC §7.6's
      // "record the failed path and carry on" has to mean the same thing
      // with a window open as it did one request at a time. Expected before
      // the commits are released, since an outcome nothing is watching yet
      // is reported as an unhandled error whatever is done with it later.
      final b = expectLater(
        remote.archiveCommit([ArchiveUpsert(entry('b.txt'))]),
        throwsA(isA<AgentOperationException>()),
      );
      final c = expectLater(
        remote.archiveCommit([ArchiveUpsert(entry('c.txt'))]),
        completes,
      );
      await pumpEventQueue();
      expect(backing.started, [
        'archiveCommit a.txt',
        'archiveCommit b.txt',
        'archiveCommit c.txt',
      ], reason: 'all three are outstanding at once');

      backing.heldCommits['c.txt']!.complete();
      backing.heldCommits['b.txt']!.complete();
      backing.heldCommits['a.txt']!.complete();

      await c;
      await a;
      await b;
      expect(backing.archive.keys, unorderedEquals(['a.txt', 'c.txt']));
    });

    test('the window never exceeds its size', () async {
      final (clientChannel, serverChannel) = InMemoryChannel.pair();
      final narrow = _FakeAgent();
      unawaited(AgentServer().serve(serverChannel, (_) => narrow));
      final agent = RemoteAgent(
        clientChannel,
        _testSpec,
        window: RequestWindow(size: 2),
      );
      await agent.hello();

      final paths = ['a.txt', 'b.txt', 'c.txt', 'd.txt'];
      for (final path in paths) {
        narrow.heldCommits[path] = Completer<void>();
      }
      final commits = [
        for (final path in paths)
          agent.archiveCommit([ArchiveUpsert(entry(path))]),
      ];
      await pumpEventQueue();

      expect(narrow.started, ['archiveCommit a.txt', 'archiveCommit b.txt']);

      narrow.heldCommits['a.txt']!.complete();
      await pumpEventQueue();
      expect(narrow.started, hasLength(3));

      for (final held in narrow.heldCommits.values) {
        if (!held.isCompleted) held.complete();
      }
      await Future.wait(commits);
      await agent.disconnect();
    });

    test('a barrier operation drains the window before it runs', () async {
      backing.heldCommits['a.txt'] = Completer<void>();
      final commit = remote.archiveCommit([ArchiveUpsert(entry('a.txt'))]);
      await pumpEventQueue();

      // `lock` is a barrier: it changes what the replica means to the whole
      // session, so it must not overlap work already in flight (SPEC §4.2).
      final locked = remote.lock();
      await pumpEventQueue();
      expect(backing.started, ['archiveCommit a.txt']);

      backing.heldCommits['a.txt']!.complete();
      await commit;
      await locked;
      expect(backing.started, ['archiveCommit a.txt', 'lock']);
    });

    test('a batch waits behind every path it carries', () async {
      // Per-path order is what SPEC §7.3 rests on, and a batch is about many
      // paths at once: it must not overtake an operation on *any* of them
      // just because it also carries paths nothing is holding.
      backing.heldCommits['a.txt'] = Completer<void>();
      final held = remote.archiveCommit([ArchiveUpsert(entry('a.txt'))]);
      await pumpEventQueue();

      final batch = remote.archiveCommit([
        ArchiveUpsert(entry('b.txt')),
        ArchiveUpsert(entry('a.txt')),
      ]);
      await pumpEventQueue();
      expect(backing.started, ['archiveCommit a.txt']);

      backing.heldCommits.remove('a.txt')!.complete();
      await held;
      await batch;
      expect(backing.started, [
        'archiveCommit a.txt',
        'archiveCommit b.txt,a.txt',
      ]);
    });

    test('operations on one path keep the order they were issued in', () async {
      // `writeFile` then the commit carrying that path is what SPEC
      // §7.3 rests on, and it must not become "whichever the window let
      // through first".
      backing.heldCommits['a.txt'] = Completer<void>();
      final first = remote.archiveCommit([ArchiveUpsert(entry('a.txt'))]);
      final second = remote.archiveCommit([ArchiveUpsert(entry('a.txt'))]);
      await pumpEventQueue();

      expect(backing.started, ['archiveCommit a.txt']);

      backing.heldCommits.remove('a.txt')!.complete();
      await first;
      await second;
      expect(backing.started, ['archiveCommit a.txt', 'archiveCommit a.txt']);
    });

    test('a tombstone commit is windowed, not a barrier', () async {
      // A tombstone appends one record for one path, exactly as an upsert
      // does. A barrier here would have made every delete action drain the
      // connection — the whole window's worth of overlap given up for a
      // tombstone.
      backing.heldCommits['a.txt'] = Completer<void>();
      backing.heldCommits['b.txt'] = Completer<void>();

      final first = remote.archiveCommit([const ArchiveTombstone('a.txt')]);
      final second = remote.archiveCommit([ArchiveUpsert(entry('b.txt'))]);
      await pumpEventQueue();

      expect(backing.started, ['archiveCommit a.txt', 'archiveCommit b.txt']);

      backing.heldCommits['a.txt']!.complete();
      backing.heldCommits['b.txt']!.complete();
      await first;
      await second;
    });

    test('removeEmptyDirs is still a barrier', () async {
      // It reaches *ancestors* of the path it is given (SPEC §7.5), so it
      // can remove a directory a concurrent `writeFile` on an unrelated path
      // is about to write into. `Applier` keeps it out of the apply loop
      // entirely, which is what makes the drain free rather than what makes
      // it unnecessary.
      backing.heldCommits['a.txt'] = Completer<void>();
      final commit = remote.archiveCommit([ArchiveUpsert(entry('a.txt'))]);
      await pumpEventQueue();

      final pruned = remote.removeEmptyDirs('sub/gone.txt');
      await pumpEventQueue();
      expect(backing.removedEmptyDirsFor, isNull);

      backing.heldCommits['a.txt']!.complete();
      await commit;
      await pruned;
      expect(backing.removedEmptyDirsFor, 'sub/gone.txt');
    });

    test('a connection that fails takes every outstanding operation with '
        'it', () async {
      final (clientChannel, serverChannel) = InMemoryChannel.pair();
      final stalled = _FakeAgent();
      unawaited(AgentServer().serve(serverChannel, (_) => stalled));
      final agent = RemoteAgent(clientChannel, _testSpec);
      await agent.hello();

      for (final path in ['a.txt', 'b.txt']) {
        stalled.heldCommits[path] = Completer<void>();
      }
      final outstanding = [
        for (final path in ['a.txt', 'b.txt'])
          expectLater(
            agent.archiveCommit([ArchiveUpsert(entry(path))]),
            throwsA(isA<Object>()),
          ),
      ];
      await pumpEventQueue();

      // Nothing can be matched to anything once the wire is gone, so this
      // is the one failure that is everyone's — fatal for the run (SPEC
      // §11.5 exit 3) however many operations it took down.
      await serverChannel.close();

      await Future.wait(outstanding);
    });
  });

  group('disconnect', () {
    test('lets go of the channel\'s input, not just its output', () async {
      // The frame stream is read through a `StreamIterator`, which holds its
      // subscription *paused* between reads. On a real `SshChannel` that
      // subscription is on the ssh process's stdout pipe, and a paused
      // subscription keeps that file descriptor registered with the event
      // loop — so a CLI run that had finished everything sat there forever
      // instead of exiting, with `close()` alone not enough to release it.
      final (clientChannel, serverChannel) = InMemoryChannel.pair();
      final watched = _WatchedInputChannel(clientChannel);
      unawaited(AgentServer().serve(serverChannel, (_) => _FakeAgent()));
      final agent = RemoteAgent(watched, _testSpec);
      await agent.hello();
      expect(
        watched.inputHasListener,
        isTrue,
        reason: 'nothing is being asserted unless a read really is in place',
      );

      await agent.disconnect();

      expect(watched.inputHasListener, isFalse);
    });
  });
}

/// A [Channel] that reports whether anyone is still listening to its
/// [input] — the one fact about `disconnect` no other seam exposes.
///
/// Wraps a real [InMemoryChannel] end rather than faking the protocol: the
/// agent on the other side has to answer a `hello` for there to be a live
/// subscription to ask about in the first place.
class _WatchedInputChannel implements Channel {
  final Channel _inner;
  final StreamController<Uint8List> _input = StreamController();

  _WatchedInputChannel(this._inner) {
    _input.onListen = () => _input.addStream(_inner.input);
  }

  bool get inputHasListener => _input.hasListener;

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<void> send(Uint8List bytes) => _inner.send(bytes);

  @override
  int? get writes => _inner.writes;

  @override
  Future<void> close() => _inner.close();
}

/// A minimal in-memory [Agent] fake — just enough to be driven through
/// [RemoteAgent]'s wire protocol without a real filesystem or archive.
/// Runs [body] against a peer holding `a.txt`'s commit open, with every
/// reported far-side span collected — the shape all three of these tests
/// need and none of them should build twice.
Future<void> _withHeldCommit(
  Future<void> Function(
    RemoteAgent agent,
    _FakeAgent backing,
    List<({AgentOp op, Duration span})> reported,
  )
  body,
) async {
  final reported = <({AgentOp op, Duration span})>[];
  final (clientChannel, serverChannel) = InMemoryChannel.pair();
  final peer = _FakeAgent()..heldCommits['a.txt'] = Completer<void>();
  unawaited(AgentServer().serve(serverChannel, (_) => peer));
  final agent = RemoteAgent(
    clientChannel,
    _testSpec,
    onFarSide: (op, span) => reported.add((op: op, span: span)),
  );
  await agent.hello();
  reported.clear();

  await body(agent, peer, reported);
}

class _FakeAgent implements Agent {
  bool locked = false;
  List<ScanEntry> scanResult = [];
  final Map<String, List<int>> fileContents = {};
  final Map<String, ArchiveEntry> archive = {};
  String? removedEmptyDirsFor;
  Object? lockError;
  ReplicaInfo helloInfo = const ReplicaInfo();

  /// Paths whose commit waits to be released, so a test can hold several
  /// operations open at once and decide the order they are answered in.
  final Map<String, Completer<void>> heldCommits = {};

  /// Paths whose commit fails.
  final Set<String> failCommits = {};

  /// Every operation the server dispatched, in the order it started them.
  final List<String> started = [];

  @override
  Future<ReplicaInfo> hello() async => helloInfo;

  @override
  Future<void> lock() async {
    started.add('lock');
    if (lockError != null) throw lockError!;
    locked = true;
  }

  @override
  Future<void> unlock() async {
    locked = false;
  }

  @override
  Future<ScanResult> scan(RuleSet rules) async =>
      ScanResult(entries: scanResult);

  @override
  Stream<List<int>> readFile(String path) {
    final bytes = fileContents[path];
    if (bytes == null) {
      return Stream<List<int>>.error(Exception('not found: $path'));
    }
    return Stream.value(bytes);
  }

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) async {
    final bytes = <int>[];
    await for (final chunk in data) {
      bytes.addAll(chunk);
    }
    fileContents[path] = bytes;
    return FileMetadata(size: bytes.length, mtime: mtime, mode: mode);
  }

  @override
  Future<void> delete(String path) async {
    fileContents.remove(path);
  }

  @override
  Future<void> removeEmptyDirs(String path) async {
    removedEmptyDirsFor = path;
  }

  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) async {
    started.add('archiveCommit ${commits.map((c) => c.path).join(',')}');
    for (final commit in commits) {
      await heldCommits[commit.path]?.future;
      if (failCommits.contains(commit.path)) {
        throw Exception('commit refused: ${commit.path}');
      }
    }
    for (final commit in commits) {
      switch (commit) {
        case ArchiveUpsert(:final entry):
          archive[entry.path] = entry;
        case ArchiveTombstone(:final path):
          archive.remove(path);
      }
    }
  }

  bool compacted = false;

  @override
  Future<void> compact() async {
    compacted = true;
  }

  @override
  Future<void> disconnect() async {}
}
