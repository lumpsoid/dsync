import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/serve/serve_controller.dart';
import 'package:dsync/app/features/serve/serve_view_state.dart';
import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/write_path_stats.dart';
import 'package:test/test.dart';

import '../../../support/fake_screen_wake.dart';

/// The Serve controller over a real `AgentListener.bindSecure` on an
/// ephemeral loopback port and a real `AppController` in a temporary
/// directory — the socket is the thing this feature owns, so faking it away
/// would leave nothing worth testing. What the fake [_Bind] adds is a hold
/// on the arguments the listener was given: the `onSessionError` handler and
/// the `buildAgent` closure are the two seams the listener would otherwise
/// only call from a real peer's connection, and both have observable
/// behaviour of their own.
///
/// What a peer connecting actually gets is `head_to_head_e2e_test.dart`'s
/// business, not this file's.
void main() {
  late Directory tempDir;
  late AppController app;
  late FakeScreenWake screenWake;
  late _Bind bind;
  late ServeController controller;

  /// Set by the one test that disposes the controller itself, so the
  /// tearDown does not dispose a `ChangeNotifier` twice.
  var disposed = false;

  ServeController build({
    Future<InternetAddress> Function()? bindAddress,
    Future<String?> Function()? advertisableAddress,
    Map<String, String> environment = const {},
  }) {
    return ServeController(
      app,
      bind: bind.call,
      bindAddress: bindAddress ?? (() async => InternetAddress.loopbackIPv4),
      environment: environment,
      screenWake: screenWake,
      advertisableAddress: advertisableAddress ?? (() async => '10.0.0.5'),
      // Ephemeral: this suite must not depend on 28771 being free on the
      // machine it runs on, and the controller reads the port it actually
      // landed on back off the socket for exactly this case.
      port: 0,
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('serve_controller_test');
    app = AppController(() async => AppPaths(tempDir.path), now: DateTime.now);
    screenWake = FakeScreenWake();
    bind = _Bind();
    disposed = false;
    controller = build();
  });

  tearDown(() async {
    if (!disposed) controller.dispose();
    app.dispose();
    await tempDir.delete(recursive: true);
  });

  test('start binds and reports where to dial this device', () async {
    await controller.start();

    final status = controller.state.status;
    expect(status, isA<ServeListening>());
    expect(controller.boundPort, isNotNull);
    // The wildcard-free chain `PairShowController` uses for the pairing
    // payload: a bind to one interface settles the host itself, and only a
    // wildcard falls through to this device's own guess.
    expect(
      (status as ServeListening).address,
      '127.0.0.1:${controller.boundPort}',
    );
    expect(screenWake.held, isTrue);
  });

  test('a wildcard bind advertises this device\'s own address', () async {
    controller = build(
      bindAddress: () async => InternetAddress.anyIPv4,
      advertisableAddress: () async => '10.0.0.5',
    );

    await controller.start();

    expect(
      (controller.state.status as ServeListening).address,
      '10.0.0.5:${controller.boundPort}',
    );
  });

  test('a port already held is a refusal naming it, not a throw', () async {
    bind.failure = const SocketException(
      'Failed to create server socket',
      osError: OSError('Address already in use', 98),
    );
    await controller.start();

    final status = controller.state.status;
    expect(status, isA<ServeFailed>());
    expect((status as ServeFailed).message, contains('Address already in use'));
    expect(status.message, contains('dsync agent --serve'));
    // The wakelock must not survive a bind that never happened.
    expect(screenWake.held, isFalse);
    expect(controller.boundPort, isNull);
  });

  test('stop closes the listener, and a second stop is a no-op', () async {
    await controller.start();
    final port = controller.boundPort!;

    await controller.stop();

    expect(controller.state.status, isA<ServeStopped>());
    expect(screenWake.held, isFalse);
    expect(controller.boundPort, isNull);
    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, port),
      throwsA(isA<SocketException>()),
    );

    await controller.stop();
    expect(controller.state.status, isA<ServeStopped>());
  });

  test('a second start while listening binds nothing more', () async {
    await controller.start();
    final port = controller.boundPort;

    await controller.start();

    expect(bind.calls, 1);
    expect(controller.boundPort, port);
  });

  test('dispose while listening closes the socket', () async {
    await controller.start();
    final port = controller.boundPort!;

    controller.dispose();
    disposed = true;
    // The close is fired without being awaited (a `dispose` is
    // synchronous), so give the event loop the turn it needs.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, port),
      throwsA(isA<SocketException>()),
    );
    expect(screenWake.held, isFalse);
  });

  test('the session log is bounded however many probes arrive', () async {
    await controller.start();

    for (var i = 0; i < 100; i++) {
      bind.onSessionError!(HandshakeException('probe $i'), StackTrace.empty);
    }

    expect(controller.state.sessions, hasLength(ServeViewState.maxSessions));
    // Newest first: the last probe is the one a user is looking for.
    expect(controller.state.sessions.first, contains('probe 99'));
    expect(controller.state.sessions.first, contains('Refused'));
  });

  test('an authorized root is expanded against this head\'s environment '
      'and logged as served', () async {
    controller = build(environment: const {'HOME': '/home/me'});
    await controller.start();

    final agent = bind.buildAgent!(
      const ReplicaSpec(
        rootPath: '~/notes',
        profileId: 'p1',
        side: 'b',
        jobs: 2,
      ),
    );

    expect(agent, isA<LocalAgent>());
    expect((agent as LocalAgent).rootPath, '/home/me/notes');
    expect(controller.state.sessions.single, contains('/home/me/notes'));
  });

  test('a fresh bind starts from an empty log', () async {
    await controller.start();
    bind.onSessionError!(HandshakeException('old'), StackTrace.empty);
    await controller.stop();

    await controller.start();

    expect(controller.state.sessions, isEmpty);
  });

  test('devices granted nothing are named, because their refusal says '
      'nothing (SPEC §4.4)', () async {
    final store = PairedDeviceStore(
      File('${tempDir.path}/dsync/paired-devices.json'),
    );
    await store.add(
      PairedDevice(
        certificatePem: generateDeviceIdentity(commonName: 'phone-b')
            .certificatePem,
        name: 'phone-b',
        agreedReplicaRoots: const {},
        pairedAt: DateTime.utc(2026, 9, 15),
        lastKnownAddress: PeerAddress(host: '10.0.0.7', port: 28771),
      ),
    );
    await app.refreshDevices();

    expect(controller.devicesReachingNothing, ['phone-b']);
    expect(controller.folders, isEmpty);

    await app.grantRoot(
      (await store.byName('phone-b'))!.deviceId,
      '/home/me/notes',
    );

    expect(controller.devicesReachingNothing, isEmpty);
    expect(controller.folders.single.rootPath, '/home/me/notes');
  });
}

/// The [BindAgentListener] this suite hands the controller: remembers what
/// it was called with, then binds the real listener on loopback — or throws
/// [failure] when the test is about a bind that could not happen.
class _Bind {
  SocketException? failure;
  int calls = 0;
  SessionErrorHandler? onSessionError;
  Agent Function(ReplicaSpec spec)? buildAgent;

  Future<AgentListener> call(
    InternetAddress address,
    int port, {
    required DeviceIdentity ownIdentity,
    required PairedDeviceStore pairedDeviceStore,
    required Agent Function(ReplicaSpec spec) buildAgent,
    required SessionErrorHandler onSessionError,
    required Map<String, String> environment,
    required WritePathStats? Function(Agent agent)? writePath,
  }) async {
    calls++;
    this.onSessionError = onSessionError;
    this.buildAgent = buildAgent;
    final failure = this.failure;
    if (failure != null) throw failure;
    return AgentListener.bindSecure(
      address,
      port,
      ownIdentity: ownIdentity,
      pairedDeviceStore: pairedDeviceStore,
      buildAgent: buildAgent,
      onSessionError: onSessionError,
      environment: environment,
      writePath: writePath,
    );
  }
}
