import 'dart:io';

import 'package:dsync/cli/agents/connected_replicas.dart';
import 'package:dsync/cli/agents/replica_unreachable_exception.dart';
import 'package:dsync/cli/host_platform.dart';
import 'package:dsync/cli/options/effective_options.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/ssh_access.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:dsync/dsync_core/state_dir.dart';
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
        metrics: RunMetricsRecorder(),
        optionsFor(Location.parse(rootA.path), Location.parse(rootB.path)),
        environment: environment,
        platform: const LinuxHost(),
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
          platform: const LinuxStateDir(),
        ).path,
      );
      expect(
        result.diagnosticsB.archivePath,
        resolveArchiveLogPath(
          profileId: 'test-profile',
          side: 'b',
          environment: environment,
          platform: const LinuxStateDir(),
        ).path,
      );
      expect(
        result.diagnosticsA.lockPath,
        resolveLockPath(
          profileId: 'test-profile',
          side: 'a',
          environment: environment,
          platform: const LinuxStateDir(),
        ).path,
      );
      expect(
        result.diagnosticsB.lockPath,
        resolveLockPath(
          profileId: 'test-profile',
          side: 'b',
          environment: environment,
          platform: const LinuxStateDir(),
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
          metrics: RunMetricsRecorder(),
          optionsFor(
            Location.parse('me@this-host:${tempDir.path}/notes'),
            Location.parse(rootB.path),
          ),
          environment: stateEnv,
          platform: const LinuxHost(),
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
          metrics: RunMetricsRecorder(),
          optionsFor(
            Location.parse(rootA.path),
            Location.parse('me@foreign-host:/sdcard/notes'),
          ),
          environment: stateEnv,
          platform: const LinuxHost(),
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
        metrics: RunMetricsRecorder(),
        optionsFor(
          Location.parse(rootA.path),
          Location.parse('ssh://qq@unix/run/ssh-unix-local/socket:/tmp/notes'),
          sshB: const SshAccess(
            options: ['-i', '~/.ssh/id_ssshd'],
            command: '/home/qq/.local/bin/dsync',
          ),
        ),
        environment: stateEnv,
        platform: const LinuxHost(),
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
        metrics: RunMetricsRecorder(),
        optionsFor(
          Location.parse(rootA.path),
          Location.parse('unix://$socketPath:/srv/notes'),
          // Would reach an ssh side; this one has no argv to reach.
          sshB: const SshAccess(options: ['-i', 'key'], command: 'elsewhere'),
        ),
        environment: stateEnv,
        platform: const LinuxHost(),
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
            metrics: RunMetricsRecorder(),
            optionsFor(
              Location.parse(rootA.path),
              Location.parse('unix://$stale:/srv/notes'),
            ),
            environment: stateEnv,
            platform: const LinuxHost(),
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

  group('a peer:// replica (SPEC §2, §4.4)', () {
    late DeviceIdentity remoteIdentity;
    late PairedDeviceStore remotePairedDevices;

    setUp(() async {
      // The device this host is dialing — a stand-in for a paired phone or
      // desktop, with its own identity and its own (separate) paired-device
      // store, the same two-sided shape `agent_listener_secure_e2e_test.dart`
      // sets up.
      remoteIdentity = generateDeviceIdentity(commonName: 'dsync-remote');
      remotePairedDevices = PairedDeviceStore(
        File('${tempDir.path}/remote-paired-devices.json'),
      );
    });

    // The identity `_resolvePeerSide` itself loads or creates — computed
    // once so a test can register it as a trusted client on the remote side
    // before binding (SPEC §4.4: `bindSecure`'s trust anchors are fixed at
    // bind time), and get back the exact same one `resolveReplicaAgents`
    // goes on to load.
    Future<DeviceIdentity> ownIdentity() => DeviceIdentityStore.forStateDir(
      environment: stateEnv,
      platform: const LinuxStateDir(),
    ).loadOrCreate(commonName: 'test-initiator');

    Future<AgentListener> bindRemoteListener() => AgentListener.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      ownIdentity: remoteIdentity,
      pairedDeviceStore: remotePairedDevices,
      // Never reached: `resolveReplicaAgents` only opens the transport and
      // stops there (see its own doc comment) — `hello` is `RunController`'s
      // to make, and none of these tests call it.
      buildAgent: (spec) =>
          throw UnimplementedError('resolveReplicaAgents never calls hello()'),
      onSessionError: (_, _) {},
    );

    int portOf(AgentListener listener) {
      final address = listener.address;
      return int.parse(address.substring(address.lastIndexOf(':') + 1));
    }

    Future<void> pairLocally(String name, PeerAddress address) =>
        PairedDeviceStore.forStateDir(
          environment: stateEnv,
          platform: const LinuxStateDir(),
        ).add(
          PairedDevice(
            certificatePem: remoteIdentity.certificatePem,
            name: name,
            agreedReplicaRoots: const {},
            pairedAt: DateTime.utc(2026, 9, 15),
            lastKnownAddress: address,
          ),
        );

    test('an unpaired device name fails before any socket is opened, naming '
        'the device and pointing at `dsync pair`', () async {
      final rootA = await tempDir.createTemp('root-a');

      await expectLater(
        resolveReplicaAgents(
          metrics: RunMetricsRecorder(),
          optionsFor(
            Location.parse(rootA.path),
            Location.parse('peer://phone:/sdcard/notes'),
          ),
          environment: stateEnv,
          platform: const LinuxHost(),
          localAddressLookup: () => Future.error(
            StateError(
              'a peer:// location declares its own locality (SPEC §4.1)',
            ),
          ),
        ).timeout(const Duration(seconds: 2)),
        throwsA(
          isA<ReplicaUnreachableException>()
              .having((e) => e.side, 'side', 'b')
              .having(
                (e) => e.cause,
                'cause',
                isA<UnpairedDeviceException>().having(
                  (e) => e.toString(),
                  'toString()',
                  allOf(contains('phone'), contains('dsync pair')),
                ),
              ),
        ),
      );
    });

    test('a paired device name dials its cached address, and a successful '
        'connection is recorded back to the store', () async {
      final rootA = await tempDir.createTemp('root-a');
      final identity = await ownIdentity();
      // The remote side has to trust *this* installation's certificate
      // too — bindSecure requires a client certificate (SPEC §4.4).
      await remotePairedDevices.add(
        PairedDevice(
          certificatePem: identity.certificatePem,
          name: 'this-initiator',
          agreedReplicaRoots: const {},
          pairedAt: DateTime.utc(2026, 9, 15),
          lastKnownAddress: PeerAddress(host: '127.0.0.1'),
        ),
      );

      final listener = await bindRemoteListener();
      addTearDown(listener.close);
      final port = portOf(listener);
      await pairLocally('phone', PeerAddress(host: '127.0.0.1', port: port));

      final storeFile = File(
        '${resolveStateDir(stateEnv, const LinuxStateDir())}/paired-devices.json',
      );
      // A write only `recordConnection` (or another store mutation this
      // test never calls again) could produce — the decisive half of "a
      // successful connection updates the cached address", since the
      // address value alone is the same before and after by construction
      // (it is exactly what got dialed).
      final beforeConnect = storeFile.statSync().modified;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final result = await resolveReplicaAgents(
        metrics: RunMetricsRecorder(),
        optionsFor(
          Location.parse(rootA.path),
          Location.parse('peer://phone:/srv/notes'),
        ),
        environment: stateEnv,
        platform: const LinuxHost(),
        localAddressLookup: () => Future.error(
          StateError(
            'a peer:// location declares its own locality (SPEC §4.1)',
          ),
        ),
      );

      expect(result.agentB, isA<RemoteAgent>());
      expect(result.diagnosticsB.locality, Locality.remote);
      expect(result.diagnosticsB.location.deviceName, 'phone');
      // No argv reached this replica — same as a unix:// side.
      expect(result.diagnosticsB.sshArgs, isNull);

      expect(
        storeFile.statSync().modified.isAfter(beforeConnect),
        isTrue,
        reason:
            'recordConnection should have rewritten the store after '
            'the connection succeeded',
      );
      final recorded = await PairedDeviceStore.forStateDir(
        environment: stateEnv,
        platform: const LinuxStateDir(),
      ).byName('phone');
      expect(recorded, isNotNull);
      expect(recorded!.lastKnownAddress.host, '127.0.0.1');
      expect(recorded.lastKnownAddress.port, port);

      await result.agentA.disconnect();
      await result.agentB.disconnect();
    });

    test('a paired device whose cached address refuses the connection reports '
        'that address, not a generic failure', () async {
      final rootA = await tempDir.createTemp('root-a');
      await ownIdentity();

      // A port nothing is listening on: bound and released immediately,
      // so it is available for the OS to hand straight back out and,
      // for the moment this test dials it, has nothing behind it.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();
      await pairLocally(
        'phone',
        PeerAddress(host: '127.0.0.1', port: deadPort),
      );

      await expectLater(
        resolveReplicaAgents(
          metrics: RunMetricsRecorder(),
          optionsFor(
            Location.parse(rootA.path),
            Location.parse('peer://phone:/srv/notes'),
          ),
          environment: stateEnv,
          platform: const LinuxHost(),
          localAddressLookup: () => Future.error(
            StateError(
              'a peer:// location declares its own locality (SPEC §4.1)',
            ),
          ),
        ),
        throwsA(
          isA<ReplicaUnreachableException>()
              .having((e) => e.side, 'side', 'b')
              .having(
                (e) => e.cause,
                'cause',
                isA<PeerAddressUnreachableException>()
                    .having((e) => e.deviceName, 'deviceName', 'phone')
                    .having((e) => e.address.port, 'address.port', deadPort)
                    .having(
                      (e) => e.toString(),
                      'toString()',
                      allOf(contains('phone'), contains('127.0.0.1:$deadPort')),
                    ),
              ),
        ),
      );
    });

    test('a cached address that accepts the connection but never answers fails '
        'within a bound, rather than hanging on a handshake that never '
        'completes', () async {
      final rootA = await tempDir.createTemp('root-a');
      await ownIdentity();

      // Accepts the TCP connection and then does nothing — no TLS
      // ServerHello, ever. What a black-holed address looks like to the
      // handshake, without depending on real network routing to produce
      // it.
      final blackHole = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(blackHole.close);
      blackHole.listen((socket) => addTearDown(socket.destroy));
      await pairLocally(
        'phone',
        PeerAddress(host: '127.0.0.1', port: blackHole.port),
      );

      await expectLater(
        resolveReplicaAgents(
          metrics: RunMetricsRecorder(),
          optionsFor(
            Location.parse(rootA.path),
            Location.parse('peer://phone:/srv/notes'),
          ),
          environment: stateEnv,
          platform: const LinuxHost(),
          localAddressLookup: () => Future.error(
            StateError(
              'a peer:// location declares its own locality (SPEC §4.1)',
            ),
          ),
          // Production's own bound is 10s; what is under test is that there
          // *is* one, not its length, so the test drives a short one rather
          // than waiting out the real one.
          peerConnectTimeout: const Duration(milliseconds: 200),
          // A generous outer bound: this fails the test on an actual hang
          // rather than letting one wedge the suite — the same shape
          // `ssh_channel_test.dart`'s own shutdown-grace assertion uses.
        ).timeout(const Duration(seconds: 5)),
        throwsA(
          isA<ReplicaUnreachableException>()
              .having((e) => e.side, 'side', 'b')
              .having(
                (e) => e.cause,
                'cause',
                isA<PeerAddressUnreachableException>(),
              ),
        ),
      );
    });
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
        metrics: RunMetricsRecorder(),
        optionsFor(
          Location.parse(rootA.path),
          Location.parse('me@foreign-host:/sdcard/notes'),
        ),
        environment: stateEnv,
        platform: const LinuxHost(),
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
        metrics: RunMetricsRecorder(),
        optionsFor(
          Location.parse(rootA.path),
          Location.parse('me@foreign-host:/sdcard/notes'),
        ),
        environment: stateEnv,
        platform: const LinuxHost(),
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
            metrics: RunMetricsRecorder(),
            optionsFor(
              Location.parse(rootA.path),
              Location.parse('me@foreign-host:/sdcard/notes'),
            ),
            environment: stateEnv,
            platform: const LinuxHost(),
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
            metrics: RunMetricsRecorder(),
            optionsFor(
              Location.parse('me@side-a-host:/notes'),
              Location.parse('~/notes'),
            ),
            environment: stateEnv,
            platform:
                const LinuxHost(), // has no HOME: side b's expandedPath throws
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
