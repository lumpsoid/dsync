import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/pair_show/pair_show_controller.dart';
import 'package:dsync/app/features/pair_show/pair_show_view_state.dart';
import 'package:dsync/dsync_core/identity/enrolment_client.dart';
import 'package:dsync/dsync_core/identity/enrolment_listener.dart';
import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// The Show-this-device's-code controller over a real `AppController`, a
/// real `PairedDeviceStore` in a temporary directory, and a real
/// `EnrolmentListener` — bound on loopback rather than every interface,
/// which is the one thing the [BindEnrolmentListener] seam exists to let a
/// test say. The peer is the real `enrolWithPeer`, in this process, over its
/// own identity and store: this is the exchange the head is showing a code
/// for, not a fake of it.
void main() {
  late Directory tempDir;
  late Directory peerDir;
  late AppController app;
  late PairShowController controller;
  late DeviceIdentity peerIdentity;
  late PairedDeviceStore peerStore;

  /// How long an exchange over loopback gets before the test fails with a
  /// message of its own rather than the suite timing out around it.
  const deadline = Duration(seconds: 30);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pair_show_controller');
    peerDir = await Directory.systemTemp.createTemp('pair_show_peer');
    app = AppController(() async => AppPaths(tempDir.path), now: DateTime.now);
    await app.bootstrap();
    peerIdentity = generateDeviceIdentity(commonName: 'peer');
    peerStore = PairedDeviceStore(File('${peerDir.path}/paired-devices.json'));
    controller = PairShowController(
      app,
      bind: _bindOnLoopback,
      bindAddress: InternetAddress.loopbackIPv4,
      advertisableAddress: _loopback,
    );
  });

  tearDown(() async {
    controller.dispose();
    app.dispose();
    await tempDir.delete(recursive: true);
    await peerDir.delete(recursive: true);
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

  Future<PairingOfferPayload> openWindow() async {
    unawaited(controller.show(peerName: 'peer laptop'));
    final waiting = await statusWhere(
      (status) => status is PairShowWaiting,
    ) as PairShowWaiting;
    return PairingOfferPayload(
      PairingPayload.decode(waiting.offer.payloadLine),
      waiting.offer.address,
    );
  }

  test(
    'offers a payload that decodes to this device and the bound port',
    () async {
      final offered = await openWindow();

      final identity = await app.loadOrCreateIdentity();
      expect(offered.payload.certificateDer, identity.certificateDer);
      expect(offered.payload.address.host, isNotEmpty);
      expect(offered.payload.address.port, greaterThan(0));
      // The address the pairing leaves behind is the serving port, never the
      // one-shot endpoint the token is redeemed against.
      expect(offered.payload.serviceAddress.port, PeerAddress.defaultPort);
      expect(
        offered.payload.serviceAddress.port,
        isNot(offered.payload.address.port),
      );
    },
  );

  test('advertises the address the endpoint was bound to, not this device\'s '
      'interface guess (task 2b26ac)', () async {
    // The head's equivalent of `dsync pair show --bind`: a non-wildcard
    // bind answers at exactly one address, so that address is what the
    // payload names. The seam below returns a deliberately wrong one — if
    // it were consulted anyway, the code on screen would send the other
    // device somewhere nothing is listening.
    controller.dispose();
    controller = PairShowController(
      app,
      bind: _bindOnLoopback,
      bindAddress: InternetAddress.loopbackIPv4,
      advertisableAddress: () async => '203.0.113.7',
    );

    final offered = await openWindow();

    expect(offered.payload.address.host, InternetAddress.loopbackIPv4.address);
    expect(offered.address, '127.0.0.1:${offered.payload.address.port}');
  });

  test('renders the payload as a symbol as well as a line', () async {
    unawaited(controller.show(peerName: 'peer laptop'));
    final waiting = await statusWhere(
      (status) => status is PairShowWaiting,
    ) as PairShowWaiting;

    expect(waiting.offer.symbol, isNotNull);
    expect(waiting.offer.payloadLine, startsWith('dsync-pair:v2:'));
  });

  /// Waits for the question the controller puts up once a code has been
  /// redeemed, and answers it the way the operator would once they have
  /// compared the two ids (task 23344d). Returns what was asked, so a test
  /// about the question itself can assert on it.
  Future<PairShowConfirming> answerConfirmation({
    required bool confirmed,
  }) async {
    final asked = await statusWhere(
      (status) => status is PairShowConfirming,
    ) as PairShowConfirming;
    controller.answerConfirmation(confirmed: confirmed);
    return asked;
  }

  test('a peer that redeems the code is paired and listed', () async {
    final offered = await openWindow();

    // Not awaited before the answer: `enrolWithPeer` does not return until
    // this side has decided, which is the whole shape of task 23344d.
    final enrolment = enrolWithPeer(
      payload: offered.payload,
      ownIdentity: peerIdentity,
      localName: 'phone',
      pairedDeviceStore: peerStore,
    );
    final asked = await answerConfirmation(confirmed: true);
    await enrolment;

    expect(asked.deviceId, peerIdentity.deviceId);
    expect(asked.peerName, 'peer laptop');

    final paired = await statusWhere(
      (status) => status is PairShowPaired,
    ) as PairShowPaired;
    expect(paired.deviceName, 'peer laptop');
    // The list the page leaves onto already holds the new row.
    expect(app.state.devices.single.name, 'peer laptop');
    expect((await (await app.pairedDevices).load()).single.name, 'peer laptop');
  });

  test('a wrong token is turned away without closing the window', () async {
    final offered = await openWindow();

    await expectLater(
      enrolWithPeer(
        payload: PairingPayload(
          certificateDer: offered.payload.certificateDer,
          address: offered.payload.address,
          servicePort: offered.payload.serviceAddress.port,
          token: Uint8List(offered.payload.token.length),
        ),
        ownIdentity: peerIdentity,
        localName: 'phone',
        pairedDeviceStore: peerStore,
      ),
      throwsA(isA<EnrolmentRefusedException>()),
    );

    // Still open: a stranger's failed guess must not end a window the real
    // peer has not reached yet, and the real one still works.
    expect(controller.state.status, isA<PairShowWaiting>());
    final enrolment = enrolWithPeer(
      payload: offered.payload,
      ownIdentity: peerIdentity,
      localName: 'phone',
      pairedDeviceStore: peerStore,
    );
    await answerConfirmation(confirmed: true);
    await enrolment;
    expect(
      await statusWhere((status) => status is PairShowPaired),
      isA<PairShowPaired>(),
    );
  });

  test('a device the operator does not recognise is never recorded', () async {
    // The leaked-payload race, as SPEC §4.4 describes it: whoever redeemed
    // the code is not necessarily the device the operator meant, and this
    // is where that is caught — before the store write, not after it.
    final offered = await openWindow();

    final enrolment = enrolWithPeer(
      payload: offered.payload,
      ownIdentity: peerIdentity,
      localName: 'phone',
      pairedDeviceStore: peerStore,
    );
    await answerConfirmation(confirmed: false);
    await expectLater(enrolment, throwsA(isA<EnrolmentRefusedException>()));

    expect(
      await statusWhere((status) => status is PairShowDeclined),
      isA<PairShowDeclined>(),
    );
    expect(app.state.devices, isEmpty);
    expect(await (await app.pairedDevices).load(), isEmpty);
  });

  test(
    'a code redeemed just before it runs out is not reported as expired',
    () async {
      // The expiry arm stops applying the moment a code is redeemed: "nothing
      // used this code" has stopped being true, and the outcome is whatever
      // the operator answers.
      controller = PairShowController(
        app,
        bind: _bindOnLoopback,
        bindAddress: InternetAddress.loopbackIPv4,
        advertisableAddress: _loopback,
        window: const Duration(milliseconds: 300),
      );
      final offered = await openWindow();

      final enrolment = enrolWithPeer(
        payload: offered.payload,
        ownIdentity: peerIdentity,
        localName: 'phone',
        pairedDeviceStore: peerStore,
      );
      await answerConfirmation(confirmed: true);
      await enrolment;

      expect(
        await statusWhere((status) => status is PairShowPaired),
        isA<PairShowPaired>(),
      );
    },
  );

  test(
    'leaving the page mid-question refuses rather than hanging the peer',
    () async {
      final offered = await openWindow();

      final enrolment = enrolWithPeer(
        payload: offered.payload,
        ownIdentity: peerIdentity,
        localName: 'phone',
        pairedDeviceStore: peerStore,
      );
      await statusWhere((status) => status is PairShowConfirming);

      await controller.stop();

      // The far end gets a reply now rather than waiting out the window, and
      // nothing was recorded on the strength of a question nobody answered.
      await expectLater(enrolment, throwsA(isA<EnrolmentRefusedException>()));
      expect(await (await app.pairedDevices).load(), isEmpty);
    },
  );

  test('a window nothing redeems expires', () async {
    controller = PairShowController(
      app,
      bind: _bindOnLoopback,
      bindAddress: InternetAddress.loopbackIPv4,
      advertisableAddress: _loopback,
      window: const Duration(milliseconds: 50),
    );

    await controller.show(peerName: 'peer laptop');

    expect(controller.state.status, isA<PairShowExpired>());
  });

  test('the endpoint is closed once the window ends', () async {
    controller = PairShowController(
      app,
      bind: _bindOnLoopback,
      bindAddress: InternetAddress.loopbackIPv4,
      advertisableAddress: _loopback,
      window: const Duration(milliseconds: 50),
    );
    unawaited(controller.show(peerName: 'peer laptop'));
    final offered = await statusWhere(
      (status) => status is PairShowWaiting,
    ) as PairShowWaiting;
    final port = PairingPayload.decode(offered.offer.payloadLine).address.port;

    await statusWhere((status) => status is PairShowExpired);

    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, port),
      throwsA(isA<SocketException>()),
    );
  });

  test('leaving the page closes the endpoint and records nothing', () async {
    final offered = await openWindow();

    await controller.stop();

    expect(controller.state.status, isA<PairShowWaiting>());
    await expectLater(
      Socket.connect(
        InternetAddress.loopbackIPv4,
        offered.payload.address.port,
      ),
      throwsA(isA<SocketException>()),
    );
  });

  test('an endpoint that cannot be bound is reported, not thrown', () async {
    controller = PairShowController(
      app,
      bindAddress: InternetAddress.loopbackIPv4,
      bind: ({
        required address,
        required ownIdentity,
        required peerName,
        required token,
        required tokenExpiresAt,
        required pairedDeviceStore,
        required confirm,
        required onError,
      }) async => throw const SocketException('Address already in use'),
    );

    await controller.show(peerName: 'peer laptop');

    final failed = controller.state.status as PairShowFailed;
    expect(failed.message, contains('Address already in use'));
    expect(failed.message, contains('Pair the other way round'));
  });
}

/// The address hint a test advertises: the interface `_bindOnLoopback`
/// actually bound, so the peer half of the exchange dials what the payload
/// says rather than this machine's real network.
Future<String?> _loopback() async => InternetAddress.loopbackIPv4.address;

/// A bound endpoint at whatever [address] the controller was configured
/// with — a test pins that to loopback rather than the production
/// `InternetAddress.anyIPv4`, which is the only thing this seam is faked
/// for.
Future<EnrolmentListener> _bindOnLoopback({
  required InternetAddress address,
  required DeviceIdentity ownIdentity,
  required String peerName,
  required Uint8List token,
  required DateTime tokenExpiresAt,
  required PairedDeviceStore pairedDeviceStore,
  required ConfirmEnrolment confirm,
  required EnrolmentErrorHandler onError,
}) => EnrolmentListener.bind(
  address,
  0,
  ownIdentity: ownIdentity,
  peerName: peerName,
  token: token,
  tokenExpiresAt: tokenExpiresAt,
  pairedDeviceStore: pairedDeviceStore,
  confirm: confirm,
  onError: onError,
);

/// What a test reads back off an open window: the decoded payload and the
/// address the page shows beside it.
class PairingOfferPayload {
  PairingOfferPayload(this.payload, this.address);

  final PairingPayload payload;
  final String address;
}
