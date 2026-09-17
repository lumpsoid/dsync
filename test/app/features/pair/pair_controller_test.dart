import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/pair/pair_controller.dart';
import 'package:dsync/app/features/pair/pair_view_state.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// The Pair controller over a real `AppController` and a real
/// `PairedDeviceStore` in a temporary directory, with the enrolment exchange
/// itself faked: each test's fake throws one of `enrolWithPeer`'s
/// documented failures and the test asserts the line the user is shown for
/// it. The happy path against a live `EnrolmentListener` is the e2e test's.
void main() {
  late Directory tempDir;
  late AppController app;
  late PairController controller;
  late EnrolWithPeer enrol;
  late String desktopCertificatePem;

  setUpAll(() {
    desktopCertificatePem = generateDeviceIdentity(commonName: 'desktop')
        .certificatePem;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pair_controller_test');
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
    await app.bootstrap();
    // Each test swaps `enrol` before submitting; a test that forgets gets a
    // loud failure rather than a silent success.
    enrol = ({
      required payload,
      required ownIdentity,
      required proposedName,
      required localName,
      required pairedDeviceStore,
    }) async => fail('enrol fake not set');
    controller = PairController(
      app,
      enrol:
          ({
            required payload,
            required ownIdentity,
            required proposedName,
            required localName,
            required pairedDeviceStore,
          }) => enrol(
            payload: payload,
            ownIdentity: ownIdentity,
            proposedName: proposedName,
            localName: localName,
            pairedDeviceStore: pairedDeviceStore,
          ),
    );
  });

  tearDown(() async {
    controller.dispose();
    app.dispose();
    await tempDir.delete(recursive: true);
  });

  PairingPayload payload({String host = '192.168.1.5', int port = 28771}) =>
      PairingPayload(
        certificateDer: certificateDerFromPem(desktopCertificatePem),
        address: PeerAddress(host: host, port: port),
        token: Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8]),
      );

  /// A fake that throws [error] on every call.
  void enrolThrows(Object error) {
    enrol = ({
      required payload,
      required ownIdentity,
      required proposedName,
      required localName,
      required pairedDeviceStore,
    }) async => throw error;
  }

  Future<void> submit({
    String? payloadText,
    String localName = 'desktop',
    String proposedName = 'phone',
  }) => controller.submitPayload(
    payloadText: payloadText ?? payload().encode(),
    localName: localName,
    proposedName: proposedName,
  );

  String failedMessage() {
    final outcome = controller.state.outcome;
    expect(outcome, isA<PairFailed>());
    return (outcome as PairFailed).message;
  }

  group('name validation', () {
    test(
      'an empty local name is a field error and starts no exchange',
      () async {
        var called = false;
        enrol = ({
          required payload,
          required ownIdentity,
          required proposedName,
          required localName,
          required pairedDeviceStore,
        }) async => called = true;

        await submit(localName: '   ');

        expect(controller.state.localNameError, isNotNull);
        expect(controller.state.proposedNameError, isNull);
        expect(controller.state.outcome, isA<PairIdle>());
        expect(called, isFalse);
      },
    );

    test('an empty proposed name is a field error on that field', () async {
      await submit(proposedName: '');

      expect(controller.state.proposedNameError, isNotNull);
      expect(controller.state.localNameError, isNull);
      expect(controller.state.outcome, isA<PairIdle>());
    });

    test('valid names clear an earlier field error', () async {
      await submit(localName: '');
      expect(controller.state.localNameError, isNotNull);

      enrolThrows(const SocketException('refused'));
      await submit();

      expect(controller.state.localNameError, isNull);
      expect(controller.state.proposedNameError, isNull);
    });

    test('an edit is validated where it stands, without a submit', () {
      controller.localNameEdited('  ');

      expect(controller.state.localNameError, isNotNull);
      // One field's edit moves one field's line: the other has not been
      // looked at.
      expect(controller.state.proposedNameError, isNull);
      expect(controller.state.outcome, isA<PairIdle>());

      controller.localNameEdited(' studio ');

      expect(controller.state.localNameError, isNull);
    });

    test('the proposed name is validated the same way', () {
      controller.proposedNameEdited('');

      expect(controller.state.proposedNameError, isNotNull);
      expect(controller.state.localNameError, isNull);

      controller.proposedNameEdited('phone');

      expect(controller.state.proposedNameError, isNull);
    });
  });

  group('FormatException', () {
    test('a malformed payload renders as not a dsync payload', () async {
      await submit(payloadText: 'hello world');

      final message = failedMessage();
      expect(message, contains('Not a dsync pairing payload'));
      expect(message, isNot(contains('version')));
    });

    test('a wrong version renders its own, distinct message', () async {
      final v2 = payload().encode().replaceFirst(':v1:', ':v2:');

      await submit(payloadText: v2);

      final message = failedMessage();
      expect(message, contains('Unsupported pairing payload version "v2"'));
      expect(message, contains('v1'));
      expect(message, isNot(contains('Not a dsync pairing payload')));
    });

    test('never reaches the exchange', () async {
      var called = false;
      enrol = ({
        required payload,
        required ownIdentity,
        required proposedName,
        required localName,
        required pairedDeviceStore,
      }) async => called = true;

      await submit(payloadText: 'dsync-pair:v1:not-base64!');

      expect(failedMessage(), contains('base64'));
      expect(called, isFalse);
    });
  });

  test('SocketException names the address hint', () async {
    enrolThrows(const SocketException('Connection refused'));

    await submit(payloadText: payload(host: '10.0.0.9', port: 4242).encode());

    final message = failedMessage();
    expect(message, contains('10.0.0.9:4242'));
    expect(message, contains('Connection refused'));
  });

  test(
    'HandshakeException says the answering device is not the pinned one',
    () async {
      enrolThrows(const HandshakeException('CERTIFICATE_VERIFY_FAILED'));

      await submit(payloadText: payload(host: '10.0.0.9', port: 4242).encode());

      final message = failedMessage();
      expect(message, contains('10.0.0.9:4242'));
      expect(message, contains('not the one this payload names'));
      expect(message, contains('dsync pair show'));
    },
  );

  test("EnrolmentRefusedException carries the far end's reason", () async {
    enrolThrows(const EnrolmentRefusedException('token expired at 11:21'));

    await submit();

    final message = failedMessage();
    expect(message, contains('refused'));
    expect(message, contains('token expired at 11:21'));
  });

  test(
    'PairedDeviceCollisionException says half-done and names the fix',
    () async {
      enrolThrows(
        const PairedDeviceCollisionException('a device named "desktop" exists'),
      );

      await submit();

      final message = failedMessage();
      expect(message, contains('half-done'));
      expect(message, contains('desktop accepted'));
      expect(message, contains('a device named "desktop" exists'));
      expect(message, contains('different name'));
      expect(message, contains('dsync pair show'));
    },
  );

  test('anything else propagates as a defect', () async {
    enrolThrows(StateError('bug'));

    await expectLater(submit(), throwsStateError);
  });

  group('success', () {
    test('calls the exchange with the trimmed names, this identity and the '
        'shared store, then shows the new row', () async {
      PairingPayload? seenPayload;
      DeviceIdentity? seenIdentity;
      String? seenLocal;
      String? seenProposed;
      enrol =
          ({
            required payload,
            required ownIdentity,
            required proposedName,
            required localName,
            required pairedDeviceStore,
          }) async {
            seenPayload = payload;
            seenIdentity = ownIdentity;
            seenLocal = localName;
            seenProposed = proposedName;
            // What the real exchange does last: record the far end here.
            await pairedDeviceStore.add(
              PairedDevice(
                certificatePem: desktopCertificatePem,
                name: localName,
                agreedReplicaRoots: const {},
                pairedAt: DateTime.utc(2026, 9, 16),
                lastKnownAddress: payload.address,
              ),
            );
          };
      expect(app.state.devices, isEmpty);

      await submit(localName: ' my desktop ', proposedName: ' my phone ');

      expect(seenLocal, 'my desktop');
      expect(seenProposed, 'my phone');
      expect(seenPayload?.address.host, '192.168.1.5');
      expect(
        seenIdentity?.certificatePem,
        (await app.loadOrCreateIdentity()).certificatePem,
      );
      expect(controller.state.outcome, isA<PairSucceeded>());
      // `refreshDevices()` ran: the row the fake added is now listed.
      expect(app.state.devices.map((d) => d.name), ['my desktop']);
    });

    test('a store that went corrupt after the add is "paired, but"', () async {
      final storeFile = File('${tempDir.path}/dsync/paired-devices.json');
      enrol =
          ({
            required payload,
            required ownIdentity,
            required proposedName,
            required localName,
            required pairedDeviceStore,
          }) async {
            storeFile.parent.createSync(recursive: true);
            storeFile.writeAsStringSync('not json');
          };

      await submit();

      final message = failedMessage();
      expect(message, startsWith('Paired, but'));
      expect(message, contains(storeFile.path));
    });

    test('moves through submitting before the verdict', () async {
      final seen = <PairOutcome>[];
      controller.state.addListener(() => seen.add(controller.state.outcome));
      enrolThrows(const SocketException('refused'));

      await submit();

      expect(seen.whereType<PairSubmitting>(), hasLength(1));
      expect(seen.last, isA<PairFailed>());
    });
  });

  /// The camera's entry point, over the same fakes: `onPayloadScanned` is
  /// `submitPayload` plus the guard a source that fires on every frame needs,
  /// so each case here is either "it is the same path" or "the repeat was
  /// dropped", and never a second implementation of the exchange.
  group('a payload from the camera', () {
    Future<void> scan({
      String? payloadText,
      String localName = 'desktop',
      String proposedName = 'phone',
    }) => controller.onPayloadScanned(
      payloadText ?? payload().encode(),
      localName: localName,
      proposedName: proposedName,
    );

    test('redeems through the same path the pasted line takes', () async {
      PairingPayload? seenPayload;
      String? seenLocal;
      enrol =
          ({
            required payload,
            required ownIdentity,
            required proposedName,
            required localName,
            required pairedDeviceStore,
          }) async {
            seenPayload = payload;
            seenLocal = localName;
            await pairedDeviceStore.add(
              PairedDevice(
                certificatePem: desktopCertificatePem,
                name: localName,
                agreedReplicaRoots: const {},
                pairedAt: DateTime.utc(2026, 9, 16),
                lastKnownAddress: payload.address,
              ),
            );
          };

      await scan(localName: ' my desktop ', proposedName: ' my phone ');

      expect(seenLocal, 'my desktop');
      expect(seenPayload?.address.port, 28771);
      expect(controller.state.outcome, isA<PairSucceeded>());
      expect(app.state.devices.map((d) => d.name), ['my desktop']);
    });

    test('a scan while one is in flight starts no second exchange', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var calls = 0;
      enrol =
          ({
            required payload,
            required ownIdentity,
            required proposedName,
            required localName,
            required pairedDeviceStore,
          }) async {
            calls++;
            started.complete();
            await release.future;
          };

      final first = scan();
      await started.future;
      expect(controller.state.outcome, isA<PairSubmitting>());

      // The camera keeps reporting the same code while the exchange runs;
      // a second attempt would carry a token the desktop has just burned.
      await scan();
      expect(calls, 1);

      release.complete();
      await first;
      expect(controller.state.outcome, isA<PairSucceeded>());
    });

    test('a scan of an already-paired payload does not dial again', () async {
      var calls = 0;
      enrol =
          ({
            required payload,
            required ownIdentity,
            required proposedName,
            required localName,
            required pairedDeviceStore,
          }) async {
            calls++;
          };

      await scan();
      expect(controller.state.outcome, isA<PairSucceeded>());
      expect(calls, 1);

      // Every frame after the successful one: dropped before anything
      // starts, so the far end's refusal of the burned token is never even
      // provoked — which is what "ignored" has to mean to be worth anything.
      final seen = <PairOutcome>[];
      controller.state.addListener(() => seen.add(controller.state.outcome));

      await scan();

      expect(calls, 1);
      expect(seen, isEmpty);
    });

    test('a refusal does not latch: a later scan is submitted', () async {
      enrolThrows(const EnrolmentRefusedException('token expired at 11:21'));
      await scan();
      expect(
        (controller.state.outcome as PairFailed).message,
        contains('token expired at 11:21'),
      );

      // A fresh code after a refusal is exactly the retry the rendered
      // message asks for, so the guard must not be holding it back.
      var calls = 0;
      enrol =
          ({
            required payload,
            required ownIdentity,
            required proposedName,
            required localName,
            required pairedDeviceStore,
          }) async {
            calls++;
          };
      await scan();

      expect(calls, 1);
      expect(controller.state.outcome, isA<PairSucceeded>());
    });

    test(
      'a scan with no names is a field error, like the paste path',
      () async {
        var called = false;
        enrol = ({
          required payload,
          required ownIdentity,
          required proposedName,
          required localName,
          required pairedDeviceStore,
        }) async => called = true;

        await scan(localName: '   ');

        expect(controller.state.localNameError, isNotNull);
        expect(controller.state.proposedNameError, isNull);
        expect(controller.state.outcome, isA<PairIdle>());
        expect(called, isFalse);
      },
    );

    test(
      'scanned text that is not a payload is refused by the same decode',
      () async {
        var called = false;
        enrol = ({
          required payload,
          required ownIdentity,
          required proposedName,
          required localName,
          required pairedDeviceStore,
        }) async => called = true;

        await scan(payloadText: 'https://example.com/not-a-payload');

        expect(
          (controller.state.outcome as PairFailed).message,
          contains('Not a dsync pairing payload'),
        );
        expect(called, isFalse);
      },
    );
  });
}
