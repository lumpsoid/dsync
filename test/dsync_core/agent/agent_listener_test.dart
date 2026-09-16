/// Not Windows: `dart:io` has no unix-domain sockets there.
@TestOn('!windows')
library;

import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';
import 'package:test/test.dart';

/// [AgentListener] over a real unix socket: the half of the transport that
/// `dsync agent --listen` is (SPEC §4.2, §11.1).
///
/// What is asserted here is everything a listener does that `--stdio` never
/// had to: staying up across sessions, keeping one session's failure to
/// itself, and coping with the socket file a killed agent leaves behind.
void main() {
  late Directory tempDir;
  late String socketPath;
  late List<Object> sessionErrors;

  const header = ArchiveHeader(
    schemaVersion: 1,
    profileId: 'notes',
    rootPath: '/does/not/matter',
  );

  const spec = ReplicaSpec(
    rootPath: '/does/not/matter',
    profileId: 'notes',
    side: 'a',
    jobs: 2,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dsync_agent_listener_');
    socketPath = '${tempDir.path}/agent.sock';
    sessionErrors = [];
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// A listener serving one [LocalAgent] rooted in its own directory under
  /// [tempDir], named by [replica] so two sessions can be pointed at the same
  /// replica or at different ones.
  Future<AgentListener> bind() async {
    Agent buildAgent(ReplicaSpec spec) {
      final root = Directory('${tempDir.path}/${spec.side}')
        ..createSync(recursive: true);
      return LocalAgent(
        rootPath: root.path,
        archiveStore: JsonlArchiveStore(
          File('${tempDir.path}/${spec.side}.jsonl'),
          header,
        ),
        replicaLock: ReplicaLock(File('${tempDir.path}/${spec.side}.lock')),
      );
    }

    return AgentListener.bindUnix(
      socketPath,
      buildAgent: buildAgent,
      onSessionError: (error, _) => sessionErrors.add(error),
    );
  }

  Future<RemoteAgent> connect({String side = 'a'}) async {
    final channel = await SocketChannel.connectUnix(socketPath);
    return RemoteAgent(
      channel,
      ReplicaSpec(
        rootPath: spec.rootPath,
        profileId: spec.profileId,
        side: side,
        jobs: spec.jobs,
      ),
    );
  }

  test('a connection is served as a full agent session', () async {
    final listener = await bind();
    addTearDown(listener.close);

    final agent = await connect();
    final info = await agent.hello();
    await agent.lock();
    final result = await agent.scan(RuleSet());
    await agent.unlock();
    await agent.disconnect();

    expect(info.lastCommitTime, isNull); // Nothing committed yet.
    expect(result.entries, isEmpty);
    expect(sessionErrors, isEmpty);
  });

  test(
    'it stays up: a second session is served after the first ends',
    () async {
      // The whole difference from `--stdio`, which serves one replica and
      // exits when its input closes. A listener that did the same would have
      // to be restarted between every sync.
      final listener = await bind();
      addTearDown(listener.close);

      final first = await connect();
      await first.hello();
      await first.disconnect();

      final second = await connect();
      await expectLater(second.hello(), completes);
      await second.disconnect();
    },
  );

  test('two sessions are served at once', () async {
    // Nothing here serializes them: SPEC §4.3's lock already covers the only
    // case that needs it, and queueing would let one wedged client stall
    // every other replica reached through this agent.
    final listener = await bind();
    addTearDown(listener.close);

    final a = await connect(side: 'a');
    final b = await connect(side: 'b');
    await a.hello();
    await b.hello();
    await a.lock();
    await b.lock();

    await a.unlock();
    await b.unlock();
    await a.disconnect();
    await b.disconnect();
    expect(sessionErrors, isEmpty);
  });

  test(
    'a session that fails is reported and does not take the listener down',
    () async {
      final listener = await bind();
      addTearDown(listener.close);

      // A peer that hangs up mid-handshake: `serve` throws rather than
      // returning, which under `--stdio` would be exit 3 for the whole process
      // (SPEC §11.5).
      final channel = await SocketChannel.connectUnix(socketPath);
      await channel.close();

      // The next session still works, which is what says the listener survived.
      final agent = await connect();
      await expectLater(agent.hello(), completes);
      await agent.disconnect();
      expect(sessionErrors, isNotEmpty);
    },
  );

  group('the socket file', () {
    test('is unlinked on close, leaving nothing for the next agent to step '
        'around', () async {
      final listener = await bind();
      expect(
        await FileSystemEntity.type(socketPath),
        FileSystemEntityType.unixDomainSock,
      );

      await listener.close();
      expect(
        await FileSystemEntity.type(socketPath),
        FileSystemEntityType.notFound,
      );
    });

    test('a stale one left by a killed agent is cleared and rebound', () async {
      // A unix socket's inode outlives the process that bound it, and `bind`
      // refuses a path that already exists — so without this, one `SIGKILL`
      // means deleting a file by hand before the agent can start again.
      await File(socketPath).writeAsString('');
      expect(
        await FileSystemEntity.type(socketPath),
        FileSystemEntityType.file,
      );

      final listener = await bind();
      addTearDown(listener.close);
      expect(
        await FileSystemEntity.type(socketPath),
        FileSystemEntityType.unixDomainSock,
      );
    });

    test('a live one is never taken over', () async {
      // Asked of the socket rather than of a pid file: a connection that
      // succeeds means somebody is being served through it.
      final listener = await bind();
      addTearDown(listener.close);

      await expectLater(bind(), throwsA(isA<SocketAlreadyServedException>()));

      // And the agent that was already there is still serving.
      final agent = await connect();
      await expectLater(agent.hello(), completes);
      await agent.disconnect();
    });
  });
}
