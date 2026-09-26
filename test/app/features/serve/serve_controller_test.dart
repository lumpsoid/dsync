import 'dart:async';
import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_settings.dart';
import 'package:dsync/app/app_settings_store.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/serve_update.dart' as core_update;
import 'package:dsync/app/features/serve/serve_controller.dart';
import 'package:dsync/app/features/serve/serve_view_state.dart';
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../../support/fake_screen_wake.dart';
import '../../support/fake_head.dart';

/// The Serve controller over a real `AppController` and a `FakeHub`
/// whose serving session the test drives: when it asks the core to serve
/// and to stop, what it shows for the core's story, and the wakelock it
/// holds meanwhile. What a peer connecting actually gets is the core's
/// (native/hub/tests/hub/pairing.rs, native/cli/tests).
void main() {
  late FakeHub core;
  late AppController app;
  late FakeScreenWake screenWake;
  late ServeController controller;

  /// Set by the one test that disposes the controller itself, so the
  /// tearDown does not dispose a `ChangeNotifier` twice.
  var disposed = false;

  ServeController build({
    Future<InternetAddress> Function()? bindAddress,
    int port = defaultPeerPort,
  }) => ServeController(
    app,
    bindAddress: bindAddress ?? (() async => InternetAddress.loopbackIPv4),
    screenWake: screenWake,
    port: port,
  );

  setUp(() {
    core = FakeHub();
    app = fakeApp(core);
    screenWake = FakeScreenWake();
    disposed = false;
    controller = build();
  });

  tearDown(() {
    if (!disposed) controller.dispose();
    app.dispose();
  });

  int serveCalls() => core.calls.where((c) => c == 'startServe').length;

  /// The session the fake opened last.
  int session() => core.serveStarts.last;

  /// Lets the controller fold what the fake just emitted.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('start asks the core to serve on the stored bind address and the '
      'default port, and shows where to dial this device', () async {
    await controller.start();

    expect(core.servedOn, (bind: '127.0.0.1', port: defaultPeerPort));
    final status = controller.state.status;
    expect(status, isA<ServeListening>());
    // What to type on the other device is the core's own advertisement.
    expect((status as ServeListening).address, '192.168.1.5:$defaultPeerPort');
    expect(controller.boundPort, defaultPeerPort);
    expect(screenWake.held, isTrue);
  });

  test(
    'a port the core cannot bind is a refusal naming it, not a throw',
    () async {
      core.failures['startServe'] = const CoreFailure('Address already in use');

      await controller.start();

      final status = controller.state.status;
      expect(status, isA<ServeFailed>());
      expect(
        (status as ServeFailed).message,
        contains('Address already in use'),
      );
      expect(status.message, contains('127.0.0.1:$defaultPeerPort'));
      expect(status.message, contains('dsync agent --serve'));
      // The wakelock must not survive a bind that never happened.
      expect(screenWake.held, isFalse);
      expect(controller.boundPort, isNull);
    },
  );

  test('a damaged settings file refuses rather than serving on the '
      'defaults', () async {
    controller = build(
      bindAddress: () async =>
          throw const AppSettingsStoreCorruptException('/s.json', 'bad'),
    );

    await controller.start();

    expect(
      (controller.state.status as ServeFailed).message,
      contains('/s.json'),
    );
    expect(serveCalls(), 0);
    expect(screenWake.held, isFalse);
  });

  test('stop asks the core to stop, and a second stop is a no-op', () async {
    await controller.start();

    await controller.stop();

    expect(core.stopped, [session()]);
    expect(controller.state.status, isA<ServeStopped>());
    expect(screenWake.held, isFalse);
    expect(controller.boundPort, isNull);

    await controller.stop();
    expect(core.stopped, [session()]);
    expect(controller.state.status, isA<ServeStopped>());
  });

  test('a second start while serving asks for nothing more', () async {
    await controller.start();

    await controller.start();

    expect(serveCalls(), 1);
  });

  test('a stop while the core is still binding stops what it bound', () async {
    final binding = Completer<void>();
    core.holds['startServe'] = binding.future;
    final started = controller.start();
    await settle();

    await controller.stop();
    binding.complete();
    await started;

    expect(core.stopped, [session()]);
    expect(controller.state.status, isA<ServeStopped>());
    expect(screenWake.held, isFalse);
  });

  test(
    'dispose while serving stops the core and releases the screen',
    () async {
      await controller.start();

      controller.dispose();
      disposed = true;
      // The stop is fired without being awaited (a `dispose` is
      // synchronous), so give the event loop the turn it needs.
      await settle();

      expect(core.stopped, [session()]);
      expect(screenWake.held, isFalse);
    },
  );

  test('each connection event is a timestamped line, newest first', () async {
    await controller.start();

    core
      ..emitServe(
        session(),
        const core_update.ServeSessionStarted(
          from: '10.0.0.7:5000',
          deviceId: 'dddd',
          name: 'phone-b',
        ),
      )
      ..emitServe(session(), const core_update.ServeServing('/home/me/notes'))
      ..emitServe(
        session(),
        const core_update.ServeSessionEnded(
          from: '10.0.0.7:5000',
          deviceId: 'dddd',
          name: 'phone-b',
          failure: null,
        ),
      )
      ..emitServe(
        session(),
        const core_update.ServeSessionEnded(
          from: '10.0.0.7:5001',
          deviceId: 'dddd',
          name: 'phone-b',
          failure: 'connection reset',
        ),
      );
    await settle();

    expect(controller.state.sessions, [
      '12:00:00  phone-b: connection reset',
      '12:00:00  phone-b disconnected',
      '12:00:00  Serving /home/me/notes',
      '12:00:00  phone-b connected from 10.0.0.7:5000',
    ]);
  });

  test('the session log is bounded however many probes arrive', () async {
    await controller.start();

    for (var i = 0; i < 100; i++) {
      core.emitServe(
        session(),
        core_update.ServeRefused(from: '10.0.0.66:$i', message: 'probe $i'),
      );
    }
    await settle();

    expect(controller.state.sessions, hasLength(ServeViewState.maxSessions));
    // Newest first: the last probe is the one a user is looking for.
    expect(controller.state.sessions.first, contains('probe 99'));
    expect(controller.state.sessions.first, contains('Refused'));
  });

  test('a fresh start begins from an empty log', () async {
    await controller.start();
    core.emitServe(
      session(),
      const core_update.ServeRefused(from: '10.0.0.66:1', message: 'old'),
    );
    await settle();
    await controller.stop();

    await controller.start();

    expect(controller.state.sessions, isEmpty);
  });

  test('a listener that fails on its own is the page\'s failure', () async {
    await controller.start();

    core.emitServe(
      session(),
      const core_update.ServeStopped('accept: too many open files'),
    );
    await settle();

    expect(
      (controller.state.status as ServeFailed).message,
      'accept: too many open files',
    );
    expect(screenWake.held, isFalse);
    expect(controller.boundPort, isNull);
  });

  test('the stop this page asked for is not reported as a failure', () async {
    await controller.start();
    final serving = session();

    await controller.stop();
    core.emitServe(serving, const core_update.ServeStopped('aborted'));
    await settle();

    expect(controller.state.status, isA<ServeStopped>());
  });

  test('devices granted nothing are named, because their refusal says '
      'nothing (SPEC §4.4)', () async {
    core.devices.add(pairedDevice(deviceId: 'dddd', name: 'phone-b'));
    await app.refreshDevices();

    expect(controller.devicesReachingNothing, ['phone-b']);
    expect(controller.folders, isEmpty);

    await app.grantRoot('dddd', '/home/me/notes');

    expect(controller.devicesReachingNothing, isEmpty);
    expect(controller.folders.single.rootPath, '/home/me/notes');
  });
}
