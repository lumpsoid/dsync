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
  }) {
    return EffectiveOptions(
      a: a,
      b: b,
      rules: RuleSet(),
      warnSizeBytes: null,
      jobs: null,
      profileId: profileId,
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
