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

import '../../../support/fake_screen_wake.dart';

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
  late FakeScreenWake screenWake;

  setUpAll(() {
    desktop = generateDeviceIdentity(commonName: 'desktop');
  });

  setUp(() async {
    screenWake = FakeScreenWake();
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

  RunRequest request({
    required bool dryRun,
    String deviceName = 'desktop',
    PeerAddress? addressOverride,
  }) => RunRequest(
    localRootPath: localRoot.path,
    deviceName: deviceName,
    peerDeviceId: desktop.deviceId,
    remoteRootPath: remoteRoot.path,
    addressOverride: addressOverride,
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
      controller = SyncRunController(app, dial: dial, screenWake: screenWake);

  SyncRunFailed failed() => controller.state.phase as SyncRunFailed;

  /// Waits for the sheet: `start` is still awaiting the stream, so the
  /// phase is polled rather than awaited — a bounded poll is what a page
  /// would see too, and it cannot deadlock on the test's own zone.
  Future<void> untilAwaiting() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (controller.state.phase is! SyncRunAwaitingDecisions) {
      if (DateTime.now().isAfter(deadline)) {
        fail('the sheet never opened: ${controller.state.phase}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// A run answered the `--batch` way (SPEC §11.3): the sheet opens and
  /// "accept all" takes the plan as reconciled.
  Future<void> startAndAcceptAll(RunRequest request) async {
    final started = controller.start(request);
    await untilAwaiting();
    controller.acceptAll();
    await started;
  }

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

  test('a far end that hangs up under the version handshake is rendered as '
      'unreachable, with the address tried (SPEC §4.4)', () async {
    // The shape a revoked (or never-paired) device sees under TLS 1.3:
    // the dial itself succeeds and the refusal is the channel closing
    // before `hello` — see `_PeerAgent` in `replica_connector.dart`.
    // The dial closes the far end the moment it is handed out; the near
    // end's version handshake then finds nothing to read.
    Future<DialResult> hangsUp(
      String host,
      int port, {
      required String expectedPeerDeviceId,
      required DeviceIdentity ownIdentity,
      required DateTime now,
    }) async {
      final (near, far) = InMemoryChannel.pair();
      far.input.listen((_) {});
      // Not awaited: a `StreamController.close()` only completes once the
      // near end has listened and drained the done event — which is `hello`
      // itself — so awaiting it here would time the dial out instead, and
      // "unreachable" would come from the timeout rather than the rewrap.
      unawaited(far.close());
      return (channel: near, presentedCertificatePem: desktop.certificatePem);
    }

    await make(hangsUp).start(request(dryRun: true));

    expect(
      failed().message,
      allOf(
        startsWith('Could not reach "desktop" at 10.0.0.7:28771'),
        contains('Enter its address by hand'),
        // The cause travels with it, the way the CLI's "Cannot reach
        // replica b: <cause>" line carries it.
        contains('Channel closed before version handshake'),
      ),
    );
  });

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

    test('a hand-entered address a dry run reached becomes the last-known '
        'address, and the Devices row shows it', () async {
      // SPEC §4.4's manual re-entry hatch, tried first after a phone moves
      // network — as a dry run, the natural way to prove the new address
      // before letting anything apply. A dry run that reached the peer
      // proves the address exactly as an applying one does, so the cache
      // must follow it here too, and the next visit to Run setup needs
      // nothing typed (the empty field is the cached address).
      final before = app.state.devices;
      await make(served(desktopAgent)).start(
        request(
          dryRun: true,
          addressOverride: PeerAddress(host: '192.168.1.9', port: 4000),
        ),
      );
      expect(controller.state.phase, isA<SyncRunFinished>());

      final recorded = (await (await app.pairedDevices).byName('desktop'))!
          .lastKnownAddress;
      expect(recorded.host, '192.168.1.9');
      expect(recorded.port, 4000);
      // The Devices page reads this process's cached copy of the store, not
      // the file: it was stale before this connect ([before] is whatever the
      // page last saw), and it is the connector's refresh that has brought
      // the row in line with the address that just worked.
      expect(app.state.devices.single.address, '192.168.1.9:4000');
      expect(
        before.map((row) => row.address),
        isNot(contains('192.168.1.9:4000')),
      );
    });
  });

  group('batch run', () {
    test('applies the plan and reports each action', () async {
      // Positive control for the dry run: the same tree, applied.
      await File('${localRoot.path}/new.txt').writeAsString('from a');

      make(served(desktopAgent));
      await startAndAcceptAll(request(dryRun: false));

      final state = controller.state;
      expect(state.results.single.path, 'new.txt');
      expect(state.results.single.error, isNull);
      expect(state.progress!.completed, 1);
      expect((state.phase as SyncRunFinished).applied, 1);
      expect(await File('${remoteRoot.path}/new.txt').exists(), isTrue);
    });

    test('a second run of the same pair is no longer a first sync', () async {
      await File('${localRoot.path}/new.txt').writeAsString('from a');
      make(served(desktopAgent));
      await startAndAcceptAll(request(dryRun: false));
      controller.dispose();

      // Nothing left to do, so no sheet opens: `start` runs to the end.
      await make(served(desktopAgent)).start(request(dryRun: false));

      expect(controller.state.header!.firstSyncWarning, isNull);
      expect(controller.state.header!.history, contains('Last synced'));
      expect(controller.state.scanTally!.local.metadataMatched, 1);
    });
  });

  group('interactive run', () {
    test('a resolved conflict is applied in the chosen direction and a '
        'skipped action is not', () async {
      await File('${localRoot.path}/new.txt').writeAsString('from a');
      await File('${localRoot.path}/both.txt').writeAsString('a version');
      await File('${remoteRoot.path}/both.txt').writeAsString('b version');

      final started = make(served(desktopAgent)).start(request(dryRun: false));
      await untilAwaiting();
      controller.resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller.skip('new.txt');
      controller.confirm();
      await started;

      final state = controller.state;
      final finished = state.phase as SyncRunFinished;
      expect(finished.applied, 1);
      expect(finished.skipped, 1);
      expect(finished.conflicts, 1);
      expect(state.results.single.path, 'both.txt');
      expect(state.results.single.action, 'copy to desktop');
      expect(
        await File('${remoteRoot.path}/both.txt').readAsString(),
        'a version',
      );
      expect(await File('${remoteRoot.path}/new.txt').exists(), isFalse);
    });

    test('stop while the sheet is up applies nothing and releases both '
        'locks', () async {
      await File('${localRoot.path}/new.txt').writeAsString('from a');
      final started = make(served(desktopAgent)).start(request(dryRun: false));
      await untilAwaiting();

      await controller.stop();
      await started;

      expect(controller.state.phase, isA<SyncRunStopped>());
      expect(await File('${remoteRoot.path}/new.txt').exists(), isFalse);
      // Both locks are free again: a run suspended on the presenter holds
      // them, and only completing the parked completer lets the generator
      // reach its cleanup. A held lock throws here.
      final profileId = ReplicaConnector.profileIdFor(
        localRootPath: localRoot.path,
        peerDeviceId: desktop.deviceId,
        remoteRootPath: remoteRoot.path,
      );
      final lockA = ReplicaLock.forProfile(
        profileId: profileId,
        side: 'a',
        platform: (await app.paths).stateDirPlatform,
      );
      await lockA.acquire();
      await lockA.release();
      final lockB = ReplicaLock(
        File('${tempDir.path}/desktop/$profileId-b.lock'),
      );
      await lockB.acquire();
      await lockB.release();
    });

    test(
      'leaving the page while the sheet is up lets the run finish',
      () async {
        await File('${localRoot.path}/new.txt').writeAsString('from a');
        final started = make(served(desktopAgent))
            .start(request(dryRun: false));
        await untilAwaiting();

        controller.dispose();
        await started;

        // The generator's cleanup is not awaited by dispose; a second run of
        // the same pair proves both locks came free.
        await make(served(desktopAgent)).start(request(dryRun: true));
        expect(controller.state.phase, isA<SyncRunFinished>());
      },
    );
  });

  group('backgrounding', () {
    test('pausing suspends the run, and resuming finishes the work', () async {
      await File('${localRoot.path}/new.txt').writeAsString('from a');
      final started = make(served(desktopAgent)).start(request(dryRun: false));
      await untilAwaiting();

      await controller.pause();
      await started;

      final paused = controller.state.phase as SyncRunPaused;
      expect(paused.completedActions, 0);
      // Suspended, not finished: nothing was applied, and the screen is no
      // longer held for a run the app cannot see.
      expect(await File('${remoteRoot.path}/new.txt').exists(), isFalse);
      expect(screenWake.held, isFalse);

      final resumed = controller.resume(request(dryRun: false));
      await untilAwaiting();
      expect(screenWake.held, isTrue);
      controller.acceptAll();
      await resumed;

      expect(controller.state.phase, isA<SyncRunFinished>());
      expect(await File('${remoteRoot.path}/new.txt').readAsString(), 'from a');
      expect(screenWake.held, isFalse);
    });

    test('the resumed run renders from nothing, not on top of the '
        'paused one', () async {
      await File('${localRoot.path}/new.txt').writeAsString('from a');
      final started = make(served(desktopAgent)).start(request(dryRun: false));
      await untilAwaiting();
      expect(controller.state.plan, hasLength(1));
      await controller.pause();
      await started;

      // The same path is planned again by the resumed run; one row, not two.
      final resumed = controller.resume(request(dryRun: false));
      await untilAwaiting();
      expect(controller.state.plan, hasLength(1));
      controller.acceptAll();
      await resumed;

      expect(controller.state.results, hasLength(1));
    });

    test('a run that is over is neither paused nor resumed', () async {
      await make(served(desktopAgent)).start(request(dryRun: true));
      final finished = controller.state.phase;

      await controller.pause();
      await controller.resume(request(dryRun: false));

      expect(controller.state.phase, same(finished));
    });

    test('coming back to a run that never paused changes nothing', () async {
      await File('${localRoot.path}/new.txt').writeAsString('from a');
      final started = make(served(desktopAgent)).start(request(dryRun: false));
      await untilAwaiting();
      final phase = controller.state.phase;

      // The lifecycle fires this on every return to the foreground, including
      // the ones that never backgrounded a run (a notification, a dialog).
      await controller.resumeFromBackground(request(dryRun: false));

      expect(controller.state.phase, same(phase));
      controller.acceptAll();
      await started;
      expect(controller.state.phase, isA<SyncRunFinished>());
    });

    test('the screen is held for exactly as long as the run is live', () async {
      await File('${localRoot.path}/new.txt').writeAsString('from a');
      await make(served(desktopAgent)).start(request(dryRun: true));

      // Once on, once off — never re-asked for what it already holds, and
      // the dry run's phase moves several times in between.
      expect(screenWake.calls, [true, false]);
      expect(screenWake.held, isFalse);
    });

    test('leaving the page releases the screen', () async {
      await File('${localRoot.path}/new.txt').writeAsString('from a');
      final started = make(served(desktopAgent)).start(request(dryRun: false));
      await untilAwaiting();
      expect(screenWake.held, isTrue);

      controller.dispose();
      await started;

      expect(screenWake.held, isFalse);
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
