import 'dart:io';

import 'package:dsync/cli/agents/connected_replicas.dart';
import 'package:dsync/cli/agents/replica_unreachable_exception.dart';
import 'package:dsync/cli/options/effective_options.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/ssh_access.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Map<String, String> stateEnv;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('connected_replicas_test');
    // Every side's diagnostics resolve an archive and lock path (SPEC §8.1,
    // §4.3) regardless of locality, so every test needs a state directory —
    // even the ones about a side that never actually connects.
    stateEnv = {'XDG_STATE_HOME': '${tempDir.path}/state'};
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  EffectiveOptions optionsFor(
    Location a,
    Location b, {
    String profileId = 'test-profile',
    SshAccess sshA = const SshAccess(),
    SshAccess sshB = const SshAccess(),
  }) {
    return EffectiveOptions(
      a: a,
      b: b,
      rules: RuleSet(),
      warnSizeBytes: null,
      jobs: null,
      profileId: profileId,
      sshA: sshA,
      sshB: sshB,
    );
  }

  group('both local', () {
    test('resolves two LocalAgents with the right root, archive, and lock '
        'paths, and spawns no ssh process', () async {
      final rootA = await tempDir.createTemp('root-a');
      final rootB = await tempDir.createTemp('root-b');
      final environment = stateEnv;

      final result = await resolveReplicaAgents(
        optionsFor(Location.parse(rootA.path), Location.parse(rootB.path)),
        environment: environment,
        // Never consulted: neither location has a host, so classify()
        // never needs this — proof nothing here reaches for the network.
        localAddressLookup: () => Future.error(
          StateError('should not be called for two local paths'),
        ),
      );

      expect(result.agentA, isA<LocalAgent>());
      expect(result.agentB, isA<LocalAgent>());
      expect((result.agentA as LocalAgent).rootPath, rootA.path);
      expect((result.agentB as LocalAgent).rootPath, rootB.path);

      // task ee190c: a local `LocalAgent` is built with the same archive
      // path its diagnostics carry, so its own `hello()` reports it back
      // (`ReplicaInfo.archivePath`) — not just this initiator-side label.
      expect(
        (result.agentA as LocalAgent).archivePath,
        result.diagnosticsA.archivePath,
      );
      expect(
        (result.agentB as LocalAgent).archivePath,
        result.diagnosticsB.archivePath,
      );

      expect(result.diagnosticsA.location.path, rootA.path);
      expect(result.diagnosticsB.location.path, rootB.path);
      expect(result.diagnosticsA.locality, Locality.inProcess);
      expect(result.diagnosticsB.locality, Locality.inProcess);

      expect(result.diagnosticsA.sshArgs, isNull);
      expect(result.diagnosticsB.sshArgs, isNull);
      expect(
        result.diagnosticsA.archivePath,
        resolveArchiveLogPath(
          profileId: 'test-profile',
          side: 'a',
          environment: environment,
        ).path,
      );
      expect(
        result.diagnosticsB.archivePath,
        resolveArchiveLogPath(
          profileId: 'test-profile',
          side: 'b',
          environment: environment,
        ).path,
      );
      expect(
        result.diagnosticsA.lockPath,
        resolveLockPath(
          profileId: 'test-profile',
          side: 'a',
          environment: environment,
        ).path,
      );
      expect(
        result.diagnosticsB.lockPath,
        resolveLockPath(
          profileId: 'test-profile',
          side: 'b',
          environment: environment,
        ).path,
      );
    });
  });

  group('locality classification', () {
    test(
      'a host in the injected local-addresses set resolves in-process',
      () async {
        final rootB = await tempDir.createTemp('root-b');

        final result = await resolveReplicaAgents(
          optionsFor(
            Location.parse('me@this-host:${tempDir.path}/notes'),
            Location.parse(rootB.path),
          ),
          environment: stateEnv,
          localAddressLookup: () async => {'this-host'},
        );

        expect(result.agentA, isA<LocalAgent>());
        expect((result.agentA as LocalAgent).rootPath, '${tempDir.path}/notes');
        expect(result.diagnosticsA.sshArgs, isNull);
        expect(result.diagnosticsA.locality, Locality.inProcess);
        expect(
          result.diagnosticsA.location.host,
          'this-host',
        ); // as typed, unexpanded (SPEC §11.4's run header shows this back).
      },
    );

    test(
      'a host absent from the injected local-addresses set resolves remote',
      () async {
        final rootA = await tempDir.createTemp('root-a');

        final result = await resolveReplicaAgents(
          optionsFor(
            Location.parse(rootA.path),
            Location.parse('me@foreign-host:/sdcard/notes'),
          ),
          environment: stateEnv,
          localAddressLookup: () async => {'this-host'},
          // Never actually spoken to (this test never calls `hello`); it
          // only has to exist so `Process.start` succeeds.
          sshExecutable: '/usr/bin/true',
        );

        expect(result.agentB, isA<RemoteAgent>());
        expect(result.diagnosticsB.sshArgs, [
          '-T',
          'me@foreign-host',
          'dsync',
          'agent',
          '--stdio',
        ]);
        expect(result.diagnosticsB.locality, Locality.remote);
        expect(result.diagnosticsB.location.host, 'foreign-host');

        await result.agentA.disconnect();
        await result.agentB.disconnect();
      },
    );

    test('an ssh:// destination resolves remote even when it is an address of '
        'this machine, and its access reaches the argv', () async {
      // SPEC §4.1, §4.2: the pair this task exists for — a destination
      // ssh knows how to reach, a key that is not a default identity, and
      // a `dsync` the remote non-interactive PATH does not have.
      final rootA = await tempDir.createTemp('root-a');

      final result = await resolveReplicaAgents(
        optionsFor(
          Location.parse(rootA.path),
          Location.parse('ssh://qq@unix/run/ssh-unix-local/socket:/tmp/notes'),
          sshB: const SshAccess(
            options: ['-i', '~/.ssh/id_ssshd'],
            command: '/home/qq/.local/bin/dsync',
          ),
        ),
        environment: stateEnv,
        // Says the destination is this machine. The plain form would run
        // it in-process on that answer; the ssh:// form does not ask.
        localAddressLookup: () async => {'unix/run/ssh-unix-local/socket'},
        sshExecutable: '/usr/bin/true',
      );

      expect(result.agentB, isA<RemoteAgent>());
      expect(result.diagnosticsB.locality, Locality.remote);
      expect(result.diagnosticsB.sshArgs, [
        '-i',
        '~/.ssh/id_ssshd',
        '-T',
        'qq@unix/run/ssh-unix-local/socket',
        '/home/qq/.local/bin/dsync',
        'agent',
        '--stdio',
      ]);

      await result.agentA.disconnect();
      await result.agentB.disconnect();
    });
  });

  group('a unix:// replica (SPEC §2, §4.2)', () {
    test('resolves to a RemoteAgent over the socket, with no ssh argv to '
        'show', () async {
      final rootA = await tempDir.createTemp('root-a');
      final socketPath = '${tempDir.path}/agent.sock';
      // Only has to accept the connection: `resolveReplicaAgents` opens the
      // transport and stops there — `hello` is `RunController`'s to make.
      // The ssh tests point `sshExecutable` at `/usr/bin/true` for the same
      // reason.
      final server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      addTearDown(server.close);

      final result = await resolveReplicaAgents(
        optionsFor(
          Location.parse(rootA.path),
          Location.parse('unix://$socketPath:/srv/notes'),
          // Would reach an ssh side; this one has no argv to reach.
          sshB: const SshAccess(options: ['-i', 'key'], command: 'elsewhere'),
        ),
        environment: stateEnv,
        localAddressLookup: () => Future.error(
          StateError(
            'a unix:// location declares its own '
            'locality (SPEC §4.1)',
          ),
        ),
      );

      expect(result.agentB, isA<RemoteAgent>());
      expect(result.diagnosticsB.locality, Locality.remote);
      expect(result.diagnosticsB.location.socketPath, socketPath);
      // Nothing was spawned and no argv reached this replica, so there is
      // none to show — and the run's ssh flags did not invent one.
      expect(result.diagnosticsB.sshArgs, isNull);

      await result.agentA.disconnect();
      await result.agentB.disconnect();
    });

    test(
      'a socket with no agent behind it is an unreachable replica',
      () async {
        // The shape a killed agent leaves: the inode is still there, so this
        // is a refused connection rather than a missing file (SPEC §11.5,
        // exit 3 either way).
        final rootA = await tempDir.createTemp('root-a');
        final stale = '${tempDir.path}/stale.sock';
        await File(stale).writeAsString('');

        await expectLater(
          resolveReplicaAgents(
            optionsFor(
              Location.parse(rootA.path),
              Location.parse('unix://$stale:/srv/notes'),
            ),
            environment: stateEnv,
          ),
          throwsA(
            isA<ReplicaUnreachableException>()
                .having((error) => error.side, 'side', 'b')
                .having((error) => error.cause, 'cause', isA<SocketException>())
                // No second stream to quote: a socket says why in the
                // exception itself.
                .having((error) => error.stderr, 'stderr', isEmpty),
          ),
        );
      },
    );
  });

  group('unreachable replica', () {
    Future<File> writeFailingSshScript(String stderrLine) async {
      final script = File('${tempDir.path}/fake-ssh.sh');
      await script.writeAsString(
        '#!/bin/sh\n'
        'echo "$stderrLine" >&2\n'
        // Give the stderr listener time to record the line before the
        // process exit closes stdout out from under the handshake read.
        'sleep 0.2\n'
        'exit 255\n',
      );
      await Process.run('chmod', ['+x', script.path]);
      return script;
    }

    test('a remote shell that talks over the protocol is reported as what it '
        'sent, alongside anything ssh said', () async {
      final rootA = await tempDir.createTemp('root-a');
      // What a `.bashrc` greeting does to the stream: sshd sources it even
      // for a non-interactive command, so the banner reaches the initiator
      // ahead of the agent's version frame. The stderr line is the noise
      // that used to stand in for the cause and hide it.
      final script = File('${tempDir.path}/chatty-ssh.sh');
      await script.writeAsString(
        '#!/bin/sh\n'
        'echo "Warning: Permanently added the host key." >&2\n'
        'echo "Welcome to build-box!"\n'
        'sleep 0.2\n'
        'exit 255\n',
      );
      await Process.run('chmod', ['+x', script.path]);

      final result = await resolveReplicaAgents(
        optionsFor(
          Location.parse(rootA.path),
          Location.parse('me@foreign-host:/sdcard/notes'),
        ),
        environment: stateEnv,
        localAddressLookup: () async => {},
        sshExecutable: script.path,
      );

      await expectLater(
        result.agentB.hello(),
        throwsA(
          isA<ReplicaUnreachableException>()
              .having(
                (e) => e.cause,
                'cause',
                isA<PeerNotSpeakingProtocolException>(),
              )
              .having(
                (e) => e.toString(),
                'toString()',
                allOf(
                  contains('Welcome to build-box!'),
                  contains('~/.bashrc'),
                  contains('Permanently added the host key.'),
                ),
              ),
        ),
      );

      await result.agentA.disconnect();
    });

    test('a version handshake that never replies names the side and carries '
        'the ssh stderr', () async {
      final rootA = await tempDir.createTemp('root-a');
      final script = await writeFailingSshScript(
        'Permission denied (publickey).',
      );

      final result = await resolveReplicaAgents(
        optionsFor(
          Location.parse(rootA.path),
          Location.parse('me@foreign-host:/sdcard/notes'),
        ),
        environment: stateEnv,
        localAddressLookup: () async => {},
        sshExecutable: script.path,
      );

      await expectLater(
        result.agentB.hello(),
        throwsA(
          isA<ReplicaUnreachableException>()
              .having((e) => e.side, 'side', 'b')
              .having(
                (e) => e.stderr,
                'stderr',
                contains('Permission denied (publickey).'),
              )
              .having(
                (e) => e.toString(),
                'toString()',
                contains('Permission denied (publickey).'),
              ),
        ),
      );

      await result.agentA.disconnect();
    });

    test(
      'an ssh executable that cannot even start is fatal at resolution',
      () async {
        final rootA = await tempDir.createTemp('root-a');

        await expectLater(
          resolveReplicaAgents(
            optionsFor(
              Location.parse(rootA.path),
              Location.parse('me@foreign-host:/sdcard/notes'),
            ),
            environment: stateEnv,
            localAddressLookup: () async => {},
            sshExecutable: '${tempDir.path}/no-such-executable',
          ),
          throwsA(
            isA<ReplicaUnreachableException>().having(
              (e) => e.side,
              'side',
              'b',
            ),
          ),
        );
      },
    );

    test(
      'a side that fails after the other already connected disconnects it',
      () async {
        final marker = File('${tempDir.path}/side-a-closed');
        final script = File('${tempDir.path}/marking-ssh.sh');
        await script.writeAsString(
          '#!/bin/sh\n'
          'cat > /dev/null\n'
          'touch "${marker.path}"\n',
        );
        await Process.run('chmod', ['+x', script.path]);

        // Side b is a bare local path missing its home expansion — a
        // deterministic failure unrelated to ssh, chosen so this test
        // exercises the teardown path rather than ssh's own failure mode a
        // second time.
        await expectLater(
          resolveReplicaAgents(
            optionsFor(
              Location.parse('me@side-a-host:/notes'),
              Location.parse('~/notes'),
            ),
            environment: stateEnv, // has no HOME: side b's expandedPath throws
            localAddressLookup: () async => {},
            sshExecutable: script.path,
          ),
          throwsA(isA<StateError>()),
        );

        expect(await marker.exists(), isTrue);
      },
    );
  });
}
