import 'dart:async';
import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/run/replica_connector.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';
import 'package:test/test.dart';

/// `SyncRunController` driven end to end with no socket: a real
/// `AppController` and paired-device store in a temporary directory, and a
/// dial that hands back one end of an `InMemoryChannel` with a real
/// `AgentServer` over a real `LocalAgent` on the other — the same shape the
/// desktop's listener has, minus TLS. So the events the view state folds
/// are `RunController`'s own, over a real scan and reconcile.
void main() {
  late Directory tempDir;
  late AppController app;
  late DeviceIdentity desktop;
  late Directory localRoot;
  late Directory remoteRoot;
  late SyncRunController controller;

  setUpAll(() {
    desktop = generateDeviceIdentity(commonName: 'desktop');
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_run_controller_test');
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
    localRoot = Directory('${tempDir.path}/documents/notes')
      ..createSync(recursive: true);
    remoteRoot = Directory('${tempDir.path}/desktop/notes')
      ..createSync(recursive: true);
    await PairedDeviceStore(File('${tempDir.path}/dsync/paired-devices.json'))
        .add(
          PairedDevice(
            certificatePem: desktop.certificatePem,
            name: 'desktop',
            agreedReplicaRoots: {remoteRoot.path},
            pairedAt: DateTime.utc(2026, 9, 15, 11, 21),
            lastKnownAddress: PeerAddress(host: '10.0.0.7', port: 28771),
          ),
        );
  });

  tearDown(() async {
    app.dispose();
    await tempDir.delete(recursive: true);
  });

  RunRequest request({required bool dryRun, String deviceName = 'desktop'}) =>
      RunRequest(
        localRootPath: localRoot.path,
        deviceName: deviceName,
        peerDeviceId: desktop.deviceId,
        remoteRootPath: remoteRoot.path,
        addressOverride: null,
        jobs: 2,
        dryRun: dryRun,
      );

  /// The desktop's side `b`, built the way `AgentListener` would build it
  /// from the `hello`'s spec: a `LocalAgent` over [remoteRoot], keyed by the
  /// profile id the head sent.
  Agent desktopAgent(ReplicaSpec spec) => LocalAgent(
    rootPath: remoteRoot.path,
    archiveStore: JsonlArchiveStore(
      File('${tempDir.path}/desktop/${spec.profileId}-b.jsonl'),
      ArchiveHeader(
        schemaVersion: 1,
        profileId: spec.profileId,
        rootPath: remoteRoot.path,
      ),
    ),
    replicaLock: ReplicaLock(
      File('${tempDir.path}/desktop/${spec.profileId}-b.lock'),
    ),
  );

  /// A dial answered by a served in-memory channel. [buildAgent] is what
  /// the far end builds for the `hello`; a throw there is what SPEC §4.4's
  /// root refusal looks like from this side.
  DialPeer served(Agent Function(ReplicaSpec spec) buildAgent) =>
      (
        host,
        port, {
        required expectedPeerDeviceId,
        required ownIdentity,
        required now,
      }) async {
        final (near, far) = InMemoryChannel.pair();
        // A session the head hangs up before its `hello` ends the far
        // end's `serve` with a handshake error — on a desktop that goes to
        // its `SessionErrorHandler`, not to the peer; here it is dropped.
        unawaited(AgentServer().serve(far, buildAgent).catchError((_) {}));
        return (channel: near, presentedCertificatePem: desktop.certificatePem);
      };

  DialPeer failing(Object error) =>
      (
        host,
        port, {
        required expectedPeerDeviceId,
        required ownIdentity,
        required now,
      }) async => throw error;

  SyncRunController make(DialPeer dial) =>
      controller = SyncRunController(app, dial: dial);

  SyncRunFailed failed() => controller.state.phase as SyncRunFailed;

  group('connect failures, rendered per case', () {
    test('unpaired device', () async {
      await make(served(desktopAgent))
          .start(request(dryRun: true, deviceName: 'laptop'));

      expect(failed().message, contains('No pairing for "laptop"'));
    });

    test('peer unreachable names the address tried', () async {
      await make(failing(const SocketException('Connection refused')))
          .start(request(dryRun: true));

      expect(
        failed().message,
        allOf(contains('10.0.0.7:28771'), contains('by hand')),
      );
    });

    test("the peer's expired certificate names the peer", () async {
      await make(failing(PeerCertificateExpiredException(desktop.deviceId)))
          .start(request(dryRun: true));

      expect(failed().message, contains('`dsync pair renew` on that device'));
    });

    test("this device's expired certificate names this device", () async {
      app.dispose();
      app = AppController(
        () async =>
            AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
        now: () => DateTime.now().add(const Duration(days: 365 * 20)),
      );
      await make(served(desktopAgent)).start(request(dryRun: true));

      expect(failed().message, contains('own certificate'));
    });
  });

  test(
    "SPEC §4.4's root refusal from the hello is the not-granted line",
    () async {
      await make(served((_) => throw const UnauthorizedReplicaRootException()))
          .start(request(dryRun: true));

      expect(failed().message, contains('desktop has not granted this path'));
      expect(failed().message, contains(remoteRoot.path));
    },
  );

  group('dry run', () {
    test('the plan and its conflicts are reported, nothing is applied, and '
        'every proposed action counts as skipped', () async {
      await File('${localRoot.path}/new.txt').writeAsString('from a');
      await File('${localRoot.path}/both.txt').writeAsString('a version');
      await File('${remoteRoot.path}/both.txt').writeAsString('b version');

      await make(served(desktopAgent)).start(request(dryRun: true));

      final state = controller.state;
      expect(state.header, isNotNull);
      expect(state.header!.firstSyncWarning, isNotNull);
      expect(state.scanTally!.local.created, 2);
      expect(state.plan.map((r) => r.path), ['new.txt']);
      expect(state.plan.single.action, 'copy to desktop');
      expect(state.conflicts.map((r) => r.path), ['both.txt']);
      expect(state.conflicts.single.local, 'created');
      expect(state.conflicts.single.remote, 'created');
      expect(state.results, isEmpty);
      expect(state.progress, isNull);
      final finished = state.phase as SyncRunFinished;
      expect(finished.applied, 0);
      expect(finished.skipped, 1);
      expect(finished.conflicts, 1);
      expect(await File('${remoteRoot.path}/new.txt').exists(), isFalse);
    });
  });

  group('batch run', () {
    test('applies the plan and reports each action', () async {
      // Positive control for the dry run: the same tree, applied.
      await File('${localRoot.path}/new.txt').writeAsString('from a');

      await make(served(desktopAgent)).start(request(dryRun: false));

      final state = controller.state;
      expect(state.results.single.path, 'new.txt');
      expect(state.results.single.error, isNull);
      expect(state.progress!.completed, 1);
      expect((state.phase as SyncRunFinished).applied, 1);
      expect(await File('${remoteRoot.path}/new.txt').exists(), isTrue);
    });

    test('a second run of the same pair is no longer a first sync', () async {
      await File('${localRoot.path}/new.txt').writeAsString('from a');
      await make(served(desktopAgent)).start(request(dryRun: false));
      controller.dispose();

      await make(served(desktopAgent)).start(request(dryRun: false));

      expect(controller.state.header!.firstSyncWarning, isNull);
      expect(controller.state.header!.history, contains('Last synced'));
      expect(controller.state.scanTally!.local.metadataMatched, 1);
    });
  });

  test('a second start on the same instance is refused', () async {
    await make(served(desktopAgent)).start(request(dryRun: true));
    final phase = controller.state.phase;

    await controller.start(request(dryRun: false));

    expect(controller.state.phase, same(phase));
  });

  test(
    'stop while connecting: no run, both sides hung up, zero actions',
    () async {
      final release = Completer<void>();
      final dial = served(desktopAgent);
      final started = make((
        host,
        port, {
        required expectedPeerDeviceId,
        required ownIdentity,
        required now,
      }) async {
        await release.future;
        return dial(
          host,
          port,
          expectedPeerDeviceId: expectedPeerDeviceId,
          ownIdentity: ownIdentity,
          now: now,
        );
      }).start(request(dryRun: false));
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.phase, isA<SyncRunConnecting>());

      final stopping = controller.stop();
      release.complete();
      await started;
      await stopping;

      final stopped = controller.state.phase as SyncRunStopped;
      expect(stopped.completedActions, 0);
      // Side a's lock was never taken and is acquirable; a held one would
      // throw here.
      final lock = ReplicaLock.forProfile(
        profileId: ReplicaConnector.profileIdFor(
          localRootPath: localRoot.path,
          peerDeviceId: desktop.deviceId,
          remoteRootPath: remoteRoot.path,
        ),
        side: 'a',
        platform: (await app.paths).stateDirPlatform,
      );
      await lock.acquire();
      await lock.release();
    },
  );
}
