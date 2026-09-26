import 'dart:async';
import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_settings.dart';
import 'package:dsync/app/app_settings_store.dart';
import 'package:dsync/app/features/pair_show/pair_show_controller.dart';
import 'package:dsync/app/features/pair_show/pair_show_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// The Show-this-device's-code controller over a real `AppController` and
/// a `FakeHub` whose pairing window the test drives with the core's views:
/// what the page shows for each, what it tells the core, and that a window
/// it has left writes nothing. The endpoint, the token and
/// the exchange are the core's (native/hub/tests/hub/pairing.rs).
void main() {
  late FakeHub core;
  late AppController app;
  late PairShowController controller;

  /// How long a step gets before the test fails with a message of its own
  /// rather than the suite timing out around it.
  const deadline = Duration(seconds: 5);

  const peerId = 'eeee-ffff-0000-1111';

  setUp(() async {
    core = FakeHub();
    app = fakeApp(core);
    await app.bootstrap();
    controller = PairShowController(app, bindAddress: _loopbackBind);
  });

  tearDown(() {
    controller.dispose();
    app.dispose();
  });

  /// Waits for the status the caller is about to assert on, so a test never
  /// races the controller's own `await`s.
  Future<PairShowStatus> statusWhere(
    bool Function(PairShowStatus status) matches,
  ) {
    if (matches(controller.state.status)) {
      return Future.value(controller.state.status);
    }
    final found = Completer<PairShowStatus>();
    void listener() {
      if (!found.isCompleted && matches(controller.state.status)) {
        found.complete(controller.state.status);
      }
    }

    controller.state.addListener(listener);
    return found.future
        .timeout(deadline)
        .whenComplete(() => controller.state.removeListener(listener));
  }

  /// The window the fake opened last.
  int session() => core.sessionOf<wire.CoreCommandShowPairing>();

  /// How many windows the page asked the core for.
  int windows() => core.sent<wire.CoreCommandShowPairing>().length;

  /// The windows the page cancelled, in order.
  List<int> cancelled() => [
    for (final cancel in core.sent<wire.CoreCommandCancelPairing>())
      cancel.session.toInt(),
  ];

  /// The operator's answers, as sent: (window, accepted).
  List<(int, bool)> answers() => [
    for (final answer in core.sent<wire.CoreCommandConfirmPairing>())
      (answer.session.toInt(), answer.accept),
  ];

  /// When the core says the payload stops being redeemable.
  final expiresAt = DateTime.now().add(const Duration(minutes: 5));

  /// Opens a window as [peerName], delivers the core's first view of it,
  /// and waits for its offer; the future of [show] itself, which ends when
  /// the window does, is returned beside it.
  Future<({PairShowWaiting waiting, Future<void> shown})> openWindow({
    String peerName = 'peer laptop',
  }) async {
    final opened = windows();
    final shown = controller.show(peerName: peerName);
    while (windows() == opened) {
      await Future<void>.delayed(Duration.zero);
    }
    core.emitPairing(
      session(),
      wire.PairingViewWaiting(
        payload: 'dsync-pair:fake',
        deviceId: 'fake-device-id',
        endpoint: '127.0.0.1:51234',
        expiresAtMs: expiresAt.millisecondsSinceEpoch,
      ),
      last: false,
    );
    final waiting = await statusWhere(
      (status) => status is PairShowWaiting,
    ) as PairShowWaiting;
    return (waiting: waiting, shown: shown);
  }

  void redeemed() => core.emitPairing(
    session(),
    const wire.PairingViewConfirming(deviceId: peerId, name: 'peer laptop'),
    last: false,
  );

  void ended(wire.PairingView view) =>
      core.emitPairing(session(), view, last: true);

  test('asks the core for a window on the stored bind address, under the '
      'name this side chose, advertising the serving port', () async {
    await openWindow();

    expect(core.sent<wire.CoreCommandShowPairing>(), [
      wire.CoreCommandShowPairing(
        name: 'peer laptop',
        bind: InternetAddress.loopbackIPv4.address,
        // The core decides what to advertise from the bind address.
        advertise: null,
        // The address the pairing leaves behind is the serving port, never
        // the one-shot endpoint the token is redeemed against.
        servicePort: defaultPeerPort,
      ),
    ]);
  });

  test('offers the core\'s payload as a line, a symbol and an address, and '
      'the core\'s deadline', () async {
    final (:waiting, shown: _) = await openWindow();

    expect(waiting.offer.payloadLine, 'dsync-pair:fake');
    expect(waiting.offer.symbol, isNotNull);
    expect(waiting.offer.address, '127.0.0.1:51234');
    expect(
      waiting.offer.expiresAt.millisecondsSinceEpoch,
      expiresAt.millisecondsSinceEpoch,
    );
  });

  test('a device that redeems the code is asked about, then paired and '
      'listed once the operator confirms', () async {
    final (waiting: _, :shown) = await openWindow();

    redeemed();
    final asked = await statusWhere(
      (status) => status is PairShowConfirming,
    ) as PairShowConfirming;
    expect(asked.deviceId, peerId);
    expect(asked.peerName, 'peer laptop');

    controller.answerConfirmation(confirmed: true);
    await Future<void>.delayed(Duration.zero);
    expect(answers(), [(session(), true)]);

    // What the core does on a confirmed device: records it, then ends.
    final device = pairedDevice(deviceId: peerId, name: 'peer laptop');
    core.reply<wire.CoreCommandListDevices>(devicesReply([device]));
    ended(wire.PairingViewEnrolled(value: wireDevice(device)));
    await shown;

    final paired = controller.state.status as PairShowPaired;
    expect(paired.deviceName, 'peer laptop');
    // The list the page leaves onto already holds the new row.
    expect(app.state.devices.single.name, 'peer laptop');
  });

  test('a device the operator does not recognise is declined, and nothing '
      'is listed', () async {
    final (waiting: _, :shown) = await openWindow();
    redeemed();
    await statusWhere((status) => status is PairShowConfirming);

    controller.answerConfirmation(confirmed: false);
    await Future<void>.delayed(Duration.zero);
    expect(answers(), [(session(), false)]);
    ended(const wire.PairingViewDeclined(deviceId: peerId));
    await shown;

    expect(controller.state.status, isA<PairShowDeclined>());
    expect(app.state.devices, isEmpty);
  });

  test('an answer with no window open is not sent', () async {
    controller.answerConfirmation(confirmed: true);
    await Future<void>.delayed(Duration.zero);

    expect(answers(), isEmpty);
  });

  test('an answer the core does not take — nothing is waiting — changes '
      'nothing', () async {
    await openWindow();
    core.reply<wire.CoreCommandConfirmPairing>(
      failed('no device is waiting to be confirmed'),
    );

    controller.answerConfirmation(confirmed: true);
    await Future<void>.delayed(Duration.zero);

    expect(core.kinds.last, wire.CoreCommandConfirmPairing);
    expect(controller.state.status, isA<PairShowWaiting>());
  });

  test(
    'a window nothing redeems expires, saying for how long codes last',
    () async {
      final (waiting: _, :shown) = await openWindow();

      ended(
        wire.PairingViewExpired(windowSeconds: wire.Uint64(BigInt.from(300))),
      );
      await shown;

      final expired = controller.state.status as PairShowExpired;
      expect(expired.window, const Duration(minutes: 5));
    },
  );

  test(
    'a question nobody answered in time is a failure that says so',
    () async {
      final (waiting: _, :shown) = await openWindow();
      redeemed();

      ended(const wire.PairingViewUnconfirmed(deviceId: peerId));
      await shown;

      expect(
        (controller.state.status as PairShowFailed).message,
        contains('Nobody answered'),
      );
    },
  );

  test('a confirmed device the store would not take is reported in the '
      'core\'s words', () async {
    final (waiting: _, :shown) = await openWindow();

    ended(
      const wire.PairingViewNotStored(
        deviceId: peerId,
        message: 'a device named "peer laptop" is already paired',
      ),
    );
    await shown;

    final outcome = controller.state.status as PairShowFailed;
    expect(outcome.message, contains('could not be recorded here'));
    expect(outcome.message, contains('already paired'));
  });

  test('a listener that fails ends the window as a failure', () async {
    final (waiting: _, :shown) = await openWindow();

    ended(const wire.PairingViewFailed(message: 'accept: too many open files'));
    await shown;

    final outcome = controller.state.status as PairShowFailed;
    expect(outcome.message, contains('too many open files'));
    expect(outcome.message, contains('show a new one'));
  });

  test('leaving the page cancels the window and records nothing', () async {
    final (waiting: _, :shown) = await openWindow();

    await controller.stop();

    expect(cancelled(), [session()]);
    // What the core answers a cancel with, arriving after the page left.
    ended(const wire.PairingViewCancelled());
    await shown;
    expect(controller.state.status, isA<PairShowWaiting>());
  });

  test('leaving the page mid-question writes nothing afterwards', () async {
    final (waiting: _, :shown) = await openWindow();
    redeemed();
    await statusWhere((status) => status is PairShowConfirming);

    await controller.stop();
    // A late outcome from the window the page left is dropped.
    ended(const wire.PairingViewUnconfirmed(deviceId: peerId));
    await shown;

    expect(cancelled(), [session()]);
    expect(controller.state.status, isA<PairShowConfirming>());
  });

  test('a fresh window closes the one before it', () async {
    await openWindow();
    final first = session();

    unawaited(openWindow(peerName: 'another'));
    await statusWhere((status) => status is PairShowWaiting && windows() == 2);

    expect(cancelled(), [first]);
  });

  test('a window the core cannot open is reported, not thrown', () async {
    core.reply<wire.CoreCommandShowPairing>(
      failed('could not bind 127.0.0.1:0: Address already in use'),
    );

    await controller.show(peerName: 'peer laptop');

    final outcome = controller.state.status as PairShowFailed;
    expect(outcome.message, contains('Address already in use'));
    expect(outcome.message, contains('Pair the other way round'));
  });

  test('a damaged settings file refuses the window rather than binding the '
      'defaults', () async {
    controller.dispose();
    controller = PairShowController(
      app,
      bindAddress: () async =>
          throw const AppSettingsStoreCorruptException('/s.json', 'bad'),
    );

    await controller.show(peerName: 'peer laptop');

    final outcome = controller.state.status as PairShowFailed;
    expect(outcome.message, contains('/s.json'));
    expect(core.sent<wire.CoreCommandShowPairing>(), isEmpty);
  });
}

/// The bind address every controller in this file is built with. A
/// callback because the production one is a settings read.
Future<InternetAddress> _loopbackBind() async => InternetAddress.loopbackIPv4;
