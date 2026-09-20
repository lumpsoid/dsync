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
    peerStore = PairedDeviceStore(
      File('${peerDir.path}/paired-devices.json'),
    );
    controller = PairShowController(
      app,
      bind: _bindOnLoopback,
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
    unawaited(controller.show());
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

  test('renders the payload as a symbol as well as a line', () async {
    unawaited(controller.show());
    final waiting = await statusWhere(
      (status) => status is PairShowWaiting,
    ) as PairShowWaiting;

    expect(waiting.offer.symbol, isNotNull);
    expect(waiting.offer.payloadLine, startsWith('dsync-pair:v2:'));
  });

  test('a peer that redeems the code is paired and listed', () async {
    final offered = await openWindow();

    await enrolWithPeer(
      payload: offered.payload,
      ownIdentity: peerIdentity,
      proposedName: 'peer laptop',
      localName: 'phone',
      pairedDeviceStore: peerStore,
    );

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
        proposedName: 'stranger',
        localName: 'phone',
        pairedDeviceStore: peerStore,
      ),
      throwsA(isA<EnrolmentRefusedException>()),
    );

    // Still open: a stranger's failed guess must not end a window the real
    // peer has not reached yet, and the real one still works.
    expect(controller.state.status, isA<PairShowWaiting>());
    await enrolWithPeer(
      payload: offered.payload,
      ownIdentity: peerIdentity,
      proposedName: 'peer laptop',
      localName: 'phone',
      pairedDeviceStore: peerStore,
    );
    expect(
      await statusWhere((status) => status is PairShowPaired),
      isA<PairShowPaired>(),
    );
  });

  test('a window nothing redeems expires', () async {
    controller = PairShowController(
      app,
      bind: _bindOnLoopback,
      advertisableAddress: _loopback,
      window: const Duration(milliseconds: 50),
    );

    await controller.show();

    expect(controller.state.status, isA<PairShowExpired>());
  });

  test('the endpoint is closed once the window ends', () async {
    controller = PairShowController(
      app,
      bind: _bindOnLoopback,
      advertisableAddress: _loopback,
      window: const Duration(milliseconds: 50),
    );
    unawaited(controller.show());
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
      bind: ({
        required ownIdentity,
        required token,
        required tokenExpiresAt,
        required pairedDeviceStore,
        required onError,
      }) async => throw const SocketException('Address already in use'),
    );

    await controller.show();

    final failed = controller.state.status as PairShowFailed;
    expect(failed.message, contains('Address already in use'));
    expect(failed.message, contains('Pair the other way round'));
  });
}

/// The address hint a test advertises: the interface `_bindOnLoopback`
/// actually bound, so the peer half of the exchange dials what the payload
/// says rather than this machine's real network.
Future<String?> _loopback() async => InternetAddress.loopbackIPv4.address;

/// A bound endpoint on the loopback interface — the production factory's
/// `InternetAddress.anyIPv4` narrowed to what a test may bind, and the only
/// thing this seam is faked for.
Future<EnrolmentListener> _bindOnLoopback({
  required DeviceIdentity ownIdentity,
  required Uint8List token,
  required DateTime tokenExpiresAt,
  required PairedDeviceStore pairedDeviceStore,
  required EnrolmentErrorHandler onError,
}) => EnrolmentListener.bind(
  InternetAddress.loopbackIPv4,
  0,
  ownIdentity: ownIdentity,
  token: token,
  tokenExpiresAt: tokenExpiresAt,
  pairedDeviceStore: pairedDeviceStore,
  onError: onError,
);

/// What a test reads back off an open window: the decoded payload and the
/// address the page shows beside it.
class PairingOfferPayload {
  PairingOfferPayload(this.payload, this.address);

  final PairingPayload payload;
  final String address;
}
