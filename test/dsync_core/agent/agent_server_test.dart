import 'dart:async';
import 'dart:convert';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_root.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/frame_router.dart';
import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:dsync/dsync_core/protocol/scan_result_codec.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:dsync/dsync_core/models/changed_scan.dart';
import 'package:dsync/dsync_core/scan/scan_session.dart';
import 'package:test/test.dart';

/// A minimal pipelining client: allocates request ids, opens a route per
/// request, and sends. Deliberately not a `RemoteAgent` — these tests are
/// about what the *server* answers, including for requests no `RemoteAgent`
/// would ever make.
class _RawClient {
  final Channel channel;
  final FrameRouter router;

  int _lastId = Frame.noRequest;

  _RawClient(this.channel) : router = FrameRouter(channel.input);

  int nextId() => ++_lastId;

  /// The version exchange, on the route for [Frame.noRequest] — opened
  /// before the router reads, since the server's own version frame is
  /// already on its way.
  Future<void> handshake() async {
    final replies = router.open(Frame.noRequest);
    unawaited(router.run(onUnrouted: (_, _) {}).catchError((_) {}));
    await performVersionHandshake(channel, replies);
    router.close(Frame.noRequest);
  }

  Future<_Exchange> request(AgentRequest request) async {
    final id = nextId();
    final replies = router.open(id);
    await channel.send(FrameCodec().encode(request.toFrame(id)));
    return _Exchange(id, replies);
  }
}

class _Exchange {
  final int id;
  final Stream<Frame> replies;

  _Exchange(this.id, this.replies);
}

/// The spec every test's `hello` prologue sends, when the test doesn't care
/// what it contains.
const _testSpec = ReplicaSpec(
  rootPath: '/replica',
  profileId: 'notes',
  side: 'a',
  jobs: 2,
);

void main() {
  late _FakeAgent agent;
  late _RawClient client;

  setUp(() async {
    final (a, b) = InMemoryChannel.pair();
    agent = _FakeAgent();
    client = _RawClient(a);

    unawaited(AgentServer().serve(b, (_) => agent));
    await client.handshake();
    final hello = await client.request(
      AgentRequest('hello', {'replica': replicaSpecToJson(_testSpec)}),
    );
    expect(
      AgentResult.fromFrame(await hello.replies.first),
      isA<AgentSuccess>(),
    );
  });

  Future<AgentResult> call(
    String op, [
    Map<String, dynamic> params = const {},
  ]) async {
    final exchange = await client.request(AgentRequest(op, params));
    return AgentResult.fromFrame(await exchange.replies.first);
  }

  /// `scan` alone, because its success is a `FrameType.scanResult` frame
  /// rather than a control frame (SPEC §15.3) — [call] would try to read it
  /// as JSON.
  Future<ChangedScan> callScan(RuleSet rules) async {
    final exchange = await client.request(
      AgentRequest('scan', {'rules': ruleSetToJson(rules)}),
    );
    final frame = await exchange.replies.first;
    expect(frame.type, FrameType.scanResult);
    return decodeChangedScan(frame.payload);
  }

  group('lock / unlock', () {
    test('dispatch to the agent and reply success', () async {
      expect(await call('lock'), isA<AgentSuccess>());
      expect(agent.locked, isTrue);

      expect(await call('unlock'), isA<AgentSuccess>());
      expect(agent.locked, isFalse);
    });
  });

  group('scan', () {
    test('replies with the serialized entries', () async {
      agent.scanResult = [
        const ScanEntry(
          path: 'a.txt',
          reason: ScanReason.created,
          size: 1,
          mtime: 1,
          mode: 420,
          hash: 'deadbeef',
        ),
      ];

      final entries = (await callScan(RuleSet())).entries;

      expect(entries.single.path, 'a.txt');
      expect(entries.single.reason, ScanReason.created);
      expect(entries.single.hash, 'deadbeef');
    });

    test('reports a failed scan as a control frame, not a scan result — the '
        'frame type is what tells the two apart (SPEC §15.3)', () async {
      agent.scanFailure = Exception('permission denied');

      final exchange = await client.request(
        AgentRequest('scan', {'rules': ruleSetToJson(RuleSet())}),
      );
      final frame = await exchange.replies.first;

      expect(frame.type, FrameType.control);
      expect(
        AgentResult.fromFrame(frame),
        isA<AgentFailure>().having(
          (f) => f.error,
          'error',
          contains('permission denied'),
        ),
      );
    });

    test("hands the request's rules to the agent", () async {
      agent.scanResult = [];

      await callScan(RuleSet(ignore: ['*.tmp']));

      // The rules come from the initiator's profile (SPEC §9), so the server
      // must pass through what it was sent rather than scanning by its own.
      expect(agent.lastScanRules?.ignorePatterns, ['*.tmp']);
    });
  });

  group('readFile', () {
    test("streams the file's bytes as fileBytes frames, terminated", () async {
      agent.fileContents['a.txt'] = utf8.encode('hello');

      final exchange = await client.request(
        const AgentRequest('readFile', {'path': 'a.txt'}),
      );

      final chunks = await readByteStream(exchange.replies).toList();
      expect(utf8.decode(chunks.expand((c) => c).toList()), 'hello');
    });

    test(
      'a missing file replies with a failure instead of streaming',
      () async {
        final exchange = await client.request(
          const AgentRequest('readFile', {'path': 'missing.txt'}),
        );

        await expectLater(
          readByteStream(exchange.replies).toList(),
          throwsA(isA<AgentOperationException>()),
        );
      },
    );
  });

  group('writeFile', () {
    test(
      'writes the streamed bytes and replies with the resulting metadata',
      () async {
        final exchange = await client.request(
          const AgentRequest('writeFile', {
            'path': 'a.txt',
            'mtime': 123,
            'mode': 420,
          }),
        );
        await sendByteStream(
          client.channel,
          Stream.value(utf8.encode('hello')),
          requestId: exchange.id,
        );

        final result =
            AgentResult.fromFrame(await exchange.replies.first) as AgentSuccess;

        expect(utf8.decode(agent.fileContents['a.txt']!), 'hello');
        expect(result.data['metadata'], {'size': 5, 'mtime': 123, 'mode': 420});
      },
    );

    test('a write that fails before reading the bytes still serves the next '
        'request', () async {
      agent.writeError = Exception('permission denied');

      final exchange = await client.request(
        const AgentRequest('writeFile', {
          'path': 'a.txt',
          'mtime': 123,
          'mode': 420,
        }),
      );
      await sendByteStream(
        client.channel,
        Stream.value(utf8.encode('hello')),
        requestId: exchange.id,
      );

      expect(
        AgentResult.fromFrame(await exchange.replies.first),
        isA<AgentFailure>(),
      );

      // The peer had already committed to sending the whole transfer. Those
      // frames route nowhere now rather than having to be drained — without
      // the id they would have been read as the next request, and SPEC §7.6
      // keeps the run going, so there is always a next request.
      expect(await call('lock'), isA<AgentSuccess>());
    });

    test('a write still opening its file does not hold up the requests and '
        'frames behind it (task cff96b)', () async {
      // The phone's shape (task 9a89f7): a served `writeFile` takes its first
      // byte frame only once its file is open, and on FUSE that open is a
      // ~20 ms create. Each request is followed on the wire by its own body,
      // as `RemoteAgent` sends them, so a router that stops at the first
      // frame nobody is taking yet reads the next request only after that
      // create returns, and sixteen creates run one at a time.
      const writes = 16;
      const open = Duration(milliseconds: 20);
      agent.openDelay = open;
      final wall = Stopwatch()..start();

      final replies = <Future<Frame>>[];
      for (var i = 0; i < writes; i++) {
        final exchange = await client.request(
          AgentRequest('writeFile', {'path': 'f$i', 'mtime': 1, 'mode': 420}),
        );
        replies.add(exchange.replies.first);
        await sendByteStream(
          client.channel,
          Stream.value([i]),
          requestId: exchange.id,
        );
      }
      for (final reply in replies) {
        expect(AgentResult.fromFrame(await reply), isA<AgentSuccess>());
      }
      wall.stop();

      final unlock = await call('unlock') as AgentSuccess;
      final stages = farSideFromJson(unlock.data)!.writeStages!;
      expect(agent.peakOpening, greaterThan(writes ~/ 2));
      expect(stages.meanServing, greaterThan(1.5));
      expect(wall.elapsed, lessThan(open * (writes ~/ 2)));
    });
  });

  group('malformed frames', () {
    test(
      'a frame that is not a request fails without ending the session',
      () async {
        final id = client.nextId();
        final replies = client.router.open(id);
        await client.channel.send(
          FrameCodec().encode(
            Frame(
              type: FrameType.control,
              requestId: id,
              payload: [0x7b, 0x7b],
            ),
          ),
        );

        expect(AgentResult.fromFrame(await replies.first), isA<AgentFailure>());

        expect(await call('lock'), isA<AgentSuccess>());
      },
    );
  });

  group('delete / removeEmptyDirs', () {
    test('dispatch with the path', () async {
      agent.fileContents['a.txt'] = utf8.encode('x');

      expect(await call('delete', {'path': 'a.txt'}), isA<AgentSuccess>());
      expect(agent.fileContents.containsKey('a.txt'), isFalse);

      expect(
        await call('removeEmptyDirs', {'path': 'a.txt'}),
        isA<AgentSuccess>(),
      );
      expect(agent.removedEmptyDirsFor, 'a.txt');
    });
  });

  group('archive commits', () {
    test('one batch carries upserts and tombstones together', () async {
      // A plan mixes copies with deletes, so a batch does too (SPEC §7.3).
      const entry = ArchiveEntry(
        path: 'a.txt',
        size: 1,
        mtime: 1,
        mode: 420,
        hash: 'h',
      );
      const other = ArchiveEntry(
        path: 'b.txt',
        size: 2,
        mtime: 2,
        mode: 420,
        hash: 'h2',
      );

      expect(
        await call('archiveCommit', {
          'commits': [
            archiveCommitToJson(const ArchiveUpsert(entry)),
            archiveCommitToJson(const ArchiveUpsert(other)),
          ],
        }),
        isA<AgentSuccess>(),
      );
      expect(agent.archive['a.txt']?.hash, 'h');
      expect(agent.archive['b.txt']?.hash, 'h2');

      expect(
        await call('archiveCommit', {
          'commits': [
            archiveCommitToJson(const ArchiveTombstone('a.txt')),
            archiveCommitToJson(const ArchiveUpsert(entry)),
          ],
        }),
        isA<AgentSuccess>(),
      );
      // Applied in order, so the upsert after the tombstone is what stands.
      expect(agent.archive['a.txt']?.hash, 'h');
      expect(agent.archive['b.txt']?.hash, 'h2');
    });
  });

  group('compact', () {
    test('dispatches to the agent', () async {
      expect(await call('compact'), isA<AgentSuccess>());
      expect(agent.compacted, isTrue);
    });
  });

  group('errors', () {
    test('an unknown op replies with a failure', () async {
      expect(await call('bogus'), isA<AgentFailure>());
    });

    test('an exception from the agent is reported as a failure', () async {
      agent.lockError = Exception('locked elsewhere');

      final result = await call('lock') as AgentFailure;

      expect(result.error, contains('locked elsewhere'));
    });
  });

  // Separate from the suites above: these drive their own [AgentServer.serve]
  // session, since the `hello` prologue itself is what's under test — every
  // other group's `setUp` already assumes it succeeds.
  group('hello prologue', () {
    test('builds the agent from the spec the client sent', () async {
      final (channel, server) = InMemoryChannel.pair();
      final client = _RawClient(channel);
      ReplicaSpec? received;
      unawaited(
        AgentServer().serve(server, (spec) {
          received = spec;
          return _FakeAgent();
        }),
      );
      await client.handshake();

      const spec = ReplicaSpec(
        rootPath: '~/notes',
        profileId: 'notes',
        side: 'b',
        jobs: 3,
      );
      final hello = await client.request(
        AgentRequest('hello', {'replica': replicaSpecToJson(spec)}),
      );
      expect(
        AgentResult.fromFrame(await hello.replies.first),
        isA<AgentSuccess>(),
      );

      expect(received?.rootPath, '~/notes');
      expect(received?.profileId, 'notes');
      expect(received?.side, 'b');
      expect(received?.jobs, 3);
    });

    test('a first frame that is not hello gets an AgentFailure and ends the '
        'session', () async {
      final (channel, server) = InMemoryChannel.pair();
      final client = _RawClient(channel);
      final serveFuture = AgentServer().serve(server, (_) => _FakeAgent());
      await client.handshake();

      final exchange = await client.request(const AgentRequest('lock'));
      expect(
        AgentResult.fromFrame(await exchange.replies.first),
        isA<AgentFailure>(),
      );

      // No dispatch loop is ever entered, so `serve` itself returns —
      // nothing is left reading the channel for a next request.
      await expectLater(serveFuture, completes);
    });
  });

  // The lock a session takes is held by the *agent process*, which under
  // `--listen` and `--serve` outlives the session (SPEC §4.2, §4.3). So
  // ending the session has to release it: only the peer's `unlock` op ever
  // did, and a client that dies between `lock` and `unlock` would otherwise
  // leave the replica locked until the agent is restarted.
  group('session teardown', () {
    /// A session past its `hello` prologue, returning the fake it serves, the
    /// client end, and `serve`'s own future.
    Future<(_FakeAgent, _RawClient, Future<void>)> session() async {
      final (channel, server) = InMemoryChannel.pair();
      final client = _RawClient(channel);
      final agent = _FakeAgent();
      final serveFuture = AgentServer().serve(server, (_) => agent);
      await client.handshake();
      final hello = await client.request(
        AgentRequest('hello', {'replica': replicaSpecToJson(_testSpec)}),
      );
      await hello.replies.first;
      await client.router.cancel();
      return (agent, client, serveFuture);
    }

    Future<void> send(_RawClient client, String op) => client.channel.send(
      FrameCodec().encode(AgentRequest(op).toFrame(client.nextId())),
    );

    test('releases the lock a client dropped without unlocking', () async {
      final (agent, client, serveFuture) = await session();
      await send(client, 'lock');
      await pumpEventQueue();
      expect(agent.locked, isTrue);

      await client.channel.close();
      await expectLater(serveFuture, completes);
      expect(agent.locked, isFalse);
    });

    test('a session that never locked tears down without error', () async {
      final (agent, client, serveFuture) = await session();

      await client.channel.close();
      await expectLater(serveFuture, completes);
      expect(agent.locked, isFalse);
    });

    test(
      'a session that unlocked explicitly tears down without error',
      () async {
        final (agent, client, serveFuture) = await session();
        await send(client, 'lock');
        await send(client, 'unlock');
        await pumpEventQueue();
        expect(agent.unlockCalls, 1);

        await client.channel.close();
        await expectLater(serveFuture, completes);
        // The redundant release is the normal case, not an error: every
        // well-behaved client unlocks, and `ReplicaLock.release` is a no-op
        // the second time.
        expect(agent.unlockCalls, 2);
        expect(agent.locked, isFalse);
      },
    );
  });
}

/// A minimal in-memory [Agent] fake — just enough to drive [AgentServer]'s
/// dispatch logic without a real filesystem or archive.
class _FakeAgent implements Agent {
  @override
  Future<void> createRoot() async {}

  bool locked = false;
  int unlockCalls = 0;
  List<ScanEntry> scanResult = [];
  Object? scanFailure;
  RuleSet? lastScanRules;
  final Map<String, List<int>> fileContents = {};
  final Map<String, ArchiveEntry> archive = {};
  String? removedEmptyDirsFor;
  Object? lockError;
  Object? writeError;

  /// How long [writeFile] spends before it takes its first byte — a stand-in
  /// for `LocalAgent` opening its file, which on the phone's FUSE storage is
  /// a ~20 ms create (task 9a89f7).
  Duration openDelay = Duration.zero;
  int _opening = 0;

  /// The most writes ever opening their file at once.
  int peakOpening = 0;

  @override
  Future<ReplicaInfo> hello() async => const ReplicaInfo(root: RootPresent());

  @override
  Future<void> lock() async {
    if (lockError != null) throw lockError!;
    locked = true;
  }

  @override
  Future<void> unlock() async {
    unlockCalls++;
    locked = false;
  }

  @override
  Future<ScanSession> scan(RuleSet rules) async {
    lastScanRules = rules;
    final failure = scanFailure;
    if (failure != null) throw failure;
    return LocalScanSession(ScanResult(entries: scanResult));
  }

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
    // Thrown before `data` is touched, like a parent directory that cannot
    // be created.
    if (writeError != null) throw writeError!;
    if (++_opening > peakOpening) peakOpening = _opening;
    await Future<void>.delayed(openDelay);
    _opening--;
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
    for (final commit in commits) {
      switch (commit) {
        case ArchiveUpsert(:final entry):
          archive[entry.path] = entry;
        case ArchiveTombstone(:final path):
          archive.remove(path);
        case ArchiveIntent() || ArchiveIntentWithdrawn():
          // Marks are the store's to keep (SPEC §7.6); this fake models
          // only the entries.
          break;
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
