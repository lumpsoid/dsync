import 'dart:async';
import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_settings.dart';
import 'package:dsync/app/app_settings_store.dart';
import 'package:dsync/app/features/serve/serve_controller.dart';
import 'package:dsync/app/features/serve/serve_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../../support/fake_screen_wake.dart';
import '../../support/fake_head.dart';

/// The Serve controller over a real `AppController` and a `FakeHub`
/// whose serving session the test drives with the core's views: when it
/// asks the core to serve and to stop, what it shows for each view, and
/// the wakelock it holds meanwhile. What a peer connecting actually gets is the core's
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
    Future<bool> Function()? keepScreenAwake,
    int port = defaultPeerPort,
  }) => ServeController(
    app,
    bindAddress: bindAddress ?? (() async => InternetAddress.loopbackIPv4),
    screenWake: screenWake,
    keepScreenAwake: keepScreenAwake ?? () async => true,
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

  int serveCalls() => core.sent<wire.CoreCommandStartServe>().length;

  /// The session the fake opened last.
  int session() => core.sessionOf<wire.CoreCommandStartServe>();

  /// The sessions the page stopped, in order.
  List<int> stopped() => [
    for (final stop in core.sent<wire.CoreCommandStopServe>())
      stop.session.toInt(),
  ];

  /// Lets the controller render what the fake just emitted.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// 12:00:00 today, where the fake's lines happened.
  final noon = DateTime(2026, 6, 1, 12).millisecondsSinceEpoch;

  wire.ServeView view({
    wire.ServePhaseView phase = const wire.ServePhaseViewListening(
      advertised: '192.168.1.5:$defaultPeerPort',
    ),
    List<wire.ServeEventView> newestFirst = const [],
  }) => wire.ServeView(
    phase: phase,
    lines: [
      for (final event in newestFirst)
        wire.ServeLineView(atMs: noon, event: event),
    ],
  );

  /// What the hub does with a stop, as the test scripts it: the session's
  /// last view — stopped, keeping [newestFirst] — goes out before the
  /// reply.
  void stopsWith([List<wire.ServeEventView> newestFirst = const []]) =>
      core.answer<wire.CoreCommandStopServe>((stop) {
        core.emitServe(
          stop.session.toInt(),
          view(
            phase: const wire.ServePhaseViewStopped(),
            newestFirst: newestFirst,
          ),
          last: true,
        );
        return const wire.ReplyResultDone();
      });

  setUp(stopsWith);

  /// Starts serving and delivers the core's first view of it.
  Future<void> serve() async {
    await controller.start();
    core.emitServe(session(), view(), last: false);
    await settle();
  }

  test('start asks the core to serve on the stored bind address and the '
      'default port, and shows where to dial this device', () async {
    await serve();

    expect(core.sent<wire.CoreCommandStartServe>(), const [
      wire.CoreCommandStartServe(bind: '127.0.0.1', port: defaultPeerPort),
    ]);
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
      core.reply<wire.CoreCommandStartServe>(failed('Address already in use'));

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
    await serve();

    await controller.stop();

    expect(stopped(), [session()]);
    expect(controller.state.status, isA<ServeStopped>());
    expect(screenWake.held, isFalse);
    expect(controller.boundPort, isNull);

    await controller.stop();
    expect(stopped(), [session()]);
    expect(controller.state.status, isA<ServeStopped>());
  });

  test('stop keeps listening: the page shows the core\'s last view of '
      'serving, its lines included', () async {
    const probe = wire.ServeEventViewRefused(
      from: '10.0.0.66:1',
      message: 'probe',
    );
    await serve();
    core.emitServe(session(), view(newestFirst: const [probe]), last: false);
    await settle();
    stopsWith(const [probe]);

    final stopping = controller.stop();
    // Asked, not yet answered: still what the core last said.
    expect(controller.state.status, isA<ServeListening>());
    expect(screenWake.held, isFalse);
    await stopping;

    expect(controller.state.status, isA<ServeStopped>());
    expect(controller.state.sessions, ['12:00:00  Refused 10.0.0.66:1: probe']);
  });

  test('a start while the last session is still stopping serves afresh, '
      'and that session\'s last view is not shown', () async {
    await serve();
    final first = session();
    final stopping = Completer<void>();
    core.hold<wire.CoreCommandStopServe>(stopping.future);
    unawaited(controller.stop());
    await settle();

    await controller.start();
    stopping.complete();
    await settle();

    expect(stopped(), [first]);
    expect(serveCalls(), 2);
    expect(controller.state.status, isA<ServeStarting>());
    core.emitServe(session(), view(), last: false);
    await settle();
    expect(controller.state.status, isA<ServeListening>());
    expect(screenWake.held, isTrue);
  });

  group('the keep-awake setting', () {
    test('off: serving never holds the screen', () async {
      controller.dispose();
      controller = build(keepScreenAwake: () async => false);

      await serve();

      expect(controller.state.status, isA<ServeListening>());
      expect(screenWake.calls, isEmpty);
    });

    test(
      'is read at each start, so a change applies to the next serve',
      () async {
        var keepAwake = true;
        controller.dispose();
        controller = build(keepScreenAwake: () async => keepAwake);
        await serve();
        expect(screenWake.held, isTrue);
        await controller.stop();
        await settle();
        expect(screenWake.held, isFalse);

        keepAwake = false;
        await serve();

        expect(controller.state.status, isA<ServeListening>());
        expect(screenWake.calls, [true, false]);
      },
    );

    test('a settings file it cannot be read from holds the screen, as '
        'before the setting existed', () async {
      controller.dispose();
      controller = build(
        keepScreenAwake: () async =>
            throw const AppSettingsStoreCorruptException('/s.json', 'bad'),
      );

      await serve();

      expect(screenWake.held, isTrue);
    });
  });

  test('a second start while serving asks for nothing more', () async {
    await serve();

    await controller.start();

    expect(serveCalls(), 1);
  });

  test('a stop while the core is still binding stops what it bound', () async {
    final binding = Completer<void>();
    core.hold<wire.CoreCommandStartServe>(binding.future);
    final started = controller.start();
    await settle();

    await controller.stop();
    binding.complete();
    await started;

    expect(stopped(), [session()]);
    expect(controller.state.status, isA<ServeStopped>());
    expect(screenWake.held, isFalse);
  });

  test(
    'dispose while serving stops the core and releases the screen',
    () async {
      await serve();

      controller.dispose();
      disposed = true;
      // The stop is fired without being awaited (a `dispose` is
      // synchronous), so give the event loop the turn it needs.
      await settle();

      expect(stopped(), [session()]);
      expect(screenWake.held, isFalse);
    },
  );

  test('each line the core kept is timestamped, newest first', () async {
    await serve();

    core.emitServe(
      session(),
      view(
        newestFirst: const [
          wire.ServeEventViewEnded(
            from: '10.0.0.7:5001',
            deviceId: 'dddd',
            name: 'phone-b',
            failure: 'connection reset',
          ),
          wire.ServeEventViewEnded(
            from: '10.0.0.7:5000',
            deviceId: 'dddd',
            name: 'phone-b',
            failure: null,
          ),
          wire.ServeEventViewServing(root: '/home/me/notes'),
          wire.ServeEventViewStarted(
            from: '10.0.0.7:5000',
            deviceId: 'dddd',
            name: 'phone-b',
          ),
          wire.ServeEventViewRefused(
            from: '10.0.0.66:1',
            message: 'bad handshake',
          ),
        ],
      ),
      last: false,
    );
    await settle();

    expect(controller.state.sessions, [
      '12:00:00  phone-b: connection reset',
      '12:00:00  phone-b disconnected',
      '12:00:00  Serving /home/me/notes',
      '12:00:00  phone-b connected from 10.0.0.7:5000',
      '12:00:00  Refused 10.0.0.66:1: bad handshake',
    ]);
  });

  test('a fresh start shows the new session\'s lines, not the last '
      'one\'s', () async {
    await serve();
    core.emitServe(
      session(),
      view(
        newestFirst: const [
          wire.ServeEventViewRefused(from: '10.0.0.66:1', message: 'old'),
        ],
      ),
      last: false,
    );
    await settle();
    expect(controller.state.sessions, hasLength(1));
    await controller.stop();

    await serve();

    expect(controller.state.sessions, isEmpty);
  });

  test('a listener that fails on its own is the page\'s failure', () async {
    await serve();

    core.emitServe(
      session(),
      view(
        phase: const wire.ServePhaseViewFailed(
          message: 'accept: too many open files',
        ),
      ),
      last: true,
    );
    await settle();

    expect(
      (controller.state.status as ServeFailed).message,
      'accept: too many open files',
    );
    expect(screenWake.held, isFalse);
    expect(controller.boundPort, isNull);
  });

  test('a view that arrives after this page stopped is not shown', () async {
    await serve();
    final serving = session();

    await controller.stop();
    core.emitServe(
      serving,
      view(phase: const wire.ServePhaseViewFailed(message: 'aborted')),
      last: true,
    );
    await settle();

    expect(controller.state.status, isA<ServeStopped>());
  });

  test('devices granted nothing are named, because their refusal says '
      'nothing (SPEC §4.4)', () async {
    core.reply<wire.CoreCommandListDevices>(
      devicesReply([pairedDevice(deviceId: 'dddd', name: 'phone-b')]),
    );
    await app.refreshDevices();

    expect(controller.devicesReachingNothing, ['phone-b']);
    expect(controller.folders, isEmpty);

    core.reply<wire.CoreCommandGrantRoot>(
      devicesReply([
        pairedDevice(
          deviceId: 'dddd',
          name: 'phone-b',
          grantedRoots: ['/home/me/notes'],
        ),
      ]),
    );
    await app.grantRoot('dddd', '/home/me/notes');

    expect(controller.devicesReachingNothing, isEmpty);
    expect(controller.folders.single.rootPath, '/home/me/notes');
  });
}
