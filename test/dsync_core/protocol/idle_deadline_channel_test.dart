import 'dart:async';
import 'dart:typed_data';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_root.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/frame_router.dart';
import 'package:dsync/dsync_core/protocol/idle_deadline_channel.dart';
import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:dsync/dsync_core/scan/scan_session.dart';
import 'package:test/test.dart';

import '../../support/scan_session.dart';

/// Short enough to keep the suite quick, and far enough apart that a machine
/// under load does not turn a healthy connection into a reaped one: five
/// heartbeats fit inside one deadline, the same ratio the production
/// constants use (SPEC §4.2).
const _deadline = Duration(milliseconds: 250);
const _heartbeat = Duration(milliseconds: 50);

const _testSpec = ReplicaSpec(
  rootPath: '/replica',
  profileId: 'notes',
  side: 'a',
  jobs: 2,
);

void main() {
  group('a peer that stops sending', () {
    test('fails the client mid-scan, naming the device', () async {
      final (clientEnd, serverEnd) = InMemoryChannel.pair();
      final agent = _FakeAgent();
      // The wedged peer: it answers `hello`, then owes a `scan` reply it
      // never sends and never closes the socket — the half-open connection a
      // slept laptop leaves behind. Not wrapped, so it sends no heartbeats.
      final scanForever = Completer<ScanSession>();
      agent.scanReply = scanForever.future;
      unawaited(AgentServer().serve(serverEnd, (_) => agent));

      final client = _wrap(clientEnd);
      final remote = RemoteAgent(client, _testSpec);
      await remote.hello();

      await expectLater(
        remote.scan(RuleSet()),
        throwsA(
          isA<PeerWentSilentException>()
              .having((e) => e.peer, 'peer', 'laptop')
              .having((e) => '$e', 'message', contains('"laptop"'))
              .having((e) => '$e', 'message', contains('stopped answering')),
        ),
      );

      scanForever.complete(LocalScanSession(const ScanResult(entries: [])));
    });

    test('is reaped by the server, which then releases the lock', () async {
      final (clientEnd, serverEnd) = InMemoryChannel.pair();
      final agent = _FakeAgent();
      final session = AgentServer().serve(_wrap(serverEnd), (_) => agent);

      // A raw client rather than a `RemoteAgent`, so the silence below is
      // this test's and not a decorator's: it takes the lock and then stops
      // sending anything at all, heartbeats included.
      final router = FrameRouter(clientEnd.input);
      final handshake = router.open(Frame.noRequest);
      unawaited(router.run(onUnrouted: (_, _) {}).catchError((_) {}));
      await performVersionHandshake(clientEnd, handshake);
      router.close(Frame.noRequest);

      final helloReply = router.open(1);
      await _send(
        clientEnd,
        AgentRequest('hello', {'replica': replicaSpecToJson(_testSpec)}),
        1,
      );
      expect(await helloReply.first, isNotNull);
      final lockReply = router.open(2);
      await _send(clientEnd, const AgentRequest('lock'), 2);
      expect(await lockReply.first, isNotNull);
      expect(agent.locked, isTrue);

      await expectLater(session, throwsA(isA<PeerWentSilentException>()));
      // Task 4402e9's release, which only runs because something ends the
      // session: a wedged one never reaches that `finally` at all.
      expect(agent.locked, isFalse);
      expect(agent.unlockCalls, greaterThan(0));
      await router.cancel();

      // And the replica is lockable again, which is the point of the pair:
      // a second session against the same agent takes the lock the reaped
      // one was holding.
      final (secondClient, secondServer) = InMemoryChannel.pair();
      unawaited(AgentServer().serve(_wrap(secondServer), (_) => agent));
      final second = RemoteAgent(_wrap(secondClient), _testSpec);
      await second.hello();
      await expectLater(second.lock(), completes);
      await second.disconnect();
    });
  });

  group('a peer that is busy, not gone', () {
    test('completes a scan that outlives the deadline', () async {
      final (clientEnd, serverEnd) = InMemoryChannel.pair();
      final agent = _FakeAgent();
      // Four deadlines' worth of cold tree — the case a bare deadline with no
      // heartbeat could only survive by being longer than the worst-case scan.
      agent.scanReply = Future.delayed(
        _deadline * 4,
        () => LocalScanSession(const ScanResult(entries: [])),
      );
      unawaited(AgentServer().serve(_wrap(serverEnd), (_) => agent));

      final remote = RemoteAgent(_wrap(clientEnd), _testSpec);
      await remote.hello();

      expect(await allScanEntries(await remote.scan(RuleSet())), isEmpty);
    });

    test('is not reaped while a user sits at a conflict prompt', () async {
      final (clientEnd, serverEnd) = InMemoryChannel.pair();
      final agent = _FakeAgent();
      final session = AgentServer().serve(_wrap(serverEnd), (_) => agent);

      // The client side is wrapped and otherwise idle: SPEC §11.3 has it
      // waiting on a human for as long as the human takes, sending nothing of
      // its own. Only its heartbeats keep the server from reaping it.
      final client = _wrap(clientEnd);
      final router = FrameRouter(client.input);
      final handshake = router.open(Frame.noRequest);
      unawaited(router.run(onUnrouted: (_, _) {}).catchError((_) {}));
      await performVersionHandshake(client, handshake);
      router.close(Frame.noRequest);

      final helloReply = router.open(1);
      await _send(
        client,
        AgentRequest('hello', {'replica': replicaSpecToJson(_testSpec)}),
        1,
      );
      expect(await helloReply.first, isNotNull);

      await Future<void>.delayed(_deadline * 4);

      final lockReply = router.open(2);
      await _send(client, const AgentRequest('lock'), 2);
      expect(AgentResult.fromFrame(await lockReply.first), isA<AgentSuccess>());
      expect(agent.locked, isTrue);

      await client.close();
      await session;
      await router.cancel();
    });
  });

  test(
    'a heartbeat mid-transfer is neither file bytes nor the terminator',
    () async {
      // The sharpest case for dropping ticks, held to directly: a tick carries
      // an empty payload, which is spelled exactly like the frame that ends a
      // transfer. `FrameRouter` is the one reader that now has to know —
      // it drops the tick before any route sees it, so `readByteStream` reads
      // only this transfer's own frames (task 0f7dfc).
      final codec = FrameCodec();
      final input = Stream.value(
        Uint8List.fromList([
          ...codec.encode(
            const Frame(
              type: FrameType.fileBytes,
              requestId: 1,
              payload: [1, 2],
            ),
          ),
          ...codec.encode(const Frame(type: FrameType.heartbeat, payload: [])),
          ...codec.encode(
            const Frame(type: FrameType.fileBytes, requestId: 1, payload: [3]),
          ),
          ...codec.encode(
            const Frame(type: FrameType.fileBytes, requestId: 1, payload: []),
          ),
        ]),
      );

      final router = FrameRouter(input);
      final transfer = router.open(1);
      unawaited(router.run(onUnrouted: (_, _) {}));

      expect(await readByteStream(transfer).toList(), [
        [1, 2],
        [3],
      ]);
    },
  );
}

IdleDeadlineChannel _wrap(Channel channel) => IdleDeadlineChannel(
  channel,
  peer: 'laptop',
  deadline: _deadline,
  heartbeatInterval: _heartbeat,
);

Future<void> _send(Channel channel, AgentRequest request, int requestId) =>
    channel.send(FrameCodec().encode(request.toFrame(requestId)));

class _FakeAgent implements Agent {
  @override
  Future<void> createRoot() async {}

  bool locked = false;
  int unlockCalls = 0;
  Future<ScanSession> scanReply = Future.value(
    LocalScanSession(const ScanResult(entries: [])),
  );

  @override
  Future<ReplicaInfo> hello() async => const ReplicaInfo(root: RootPresent());

  @override
  Future<void> lock() async {
    // Like the real `ReplicaLock` (SPEC §4.3): a second taker is refused
    // while the first still holds it, so "lockable again" is an assertion
    // and not a no-op.
    if (locked) throw StateError('Replica is already locked');
    locked = true;
  }

  @override
  Future<void> unlock() async {
    unlockCalls++;
    locked = false;
  }

  @override
  Future<ScanSession> scan(RuleSet rules) => scanReply;

  @override
  Stream<List<int>> readFile(String path) => const Stream.empty();

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) async => FileMetadata(size: 0, mtime: mtime, mode: mode);

  @override
  Future<void> delete(String path) async {}

  @override
  Future<void> removeEmptyDirs(String path) async {}

  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) async {}

  @override
  Future<void> compact() async {}

  @override
  Future<void> disconnect() async {}
}
