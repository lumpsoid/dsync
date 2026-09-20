import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/pair/pair_code.dart';
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
    app = AppController(() async => AppPaths(tempDir.path), now: DateTime.now);
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

  PairingPayload payload({
    String host = '192.168.1.5',
    int port = 51234,
    int servicePort = 28771,
  }) => PairingPayload(
    certificateDer: certificateDerFromPem(desktopCertificatePem),
    address: PeerAddress(host: host, port: port),
    servicePort: servicePort,
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

  /// The page's two steps, as every test that pairs takes them: a code is
  /// read in first, and only then is anything submitted.
  Future<void> submit({
    String? payloadText,
    String localName = 'desktop',
    String proposedName = 'phone',
  }) {
    controller.codeEntered(payloadText ?? payload().encode());
    return controller.submitPayload(
      localName: localName,
      proposedName: proposedName,
    );
  }

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

  group('a code coming in', () {
    /// What the page shows for the code it is holding, as a read one.
    PairCodeRead readCode() {
      final code = controller.state.code;
      expect(code, isA<PairCodeRead>());
      return code as PairCodeRead;
    }

    test('nothing has been read until something is', () {
      expect(controller.state.code, isA<PairCodeMissing>());
    });

    test(
      'a payload names the device and the address it will be reached at',
      () {
        // The serving address, not the enrolment endpoint this pairing is
        // redeemed against: the card shows the address the pairing leaves
        // behind.
        controller.codeEntered(
          payload(host: '10.0.0.9', port: 4242, servicePort: 28771).encode(),
        );

        expect(readCode().desktopName, 'desktop');
        expect(readCode().address, '10.0.0.9:28771');
      },
    );

    test('a malformed payload is unreadable, not a failed pairing', () {
      controller.codeEntered('hello world');

      final code = controller.state.code;
      expect(code, isA<PairCodeUnreadable>());
      expect(
        (code as PairCodeUnreadable).message,
        contains('Not a dsync pairing payload'),
      );
      // Nothing was attempted, so there is no verdict to render either.
      expect(controller.state.outcome, isA<PairIdle>());
    });

    test('a wrong version says so, distinctly', () {
      controller.codeEntered(payload().encode().replaceFirst(':v2:', ':v1:'));

      final message = (controller.state.code as PairCodeUnreadable).message;
      expect(message, contains('Unsupported pairing payload version "v1"'));
      expect(message, contains('v2'));
      expect(message, isNot(contains('Not a dsync pairing payload')));
    });

    test('no code means no exchange, whatever the names say', () async {
      var called = false;
      enrol = ({
        required payload,
        required ownIdentity,
        required proposedName,
        required localName,
        required pairedDeviceStore,
      }) async => called = true;

      await controller.submitPayload(
        localName: 'desktop',
        proposedName: 'phone',
      );

      expect(failedMessage(), contains('Scan or paste'));
      expect(called, isFalse);
    });

    test('clearing puts the page back to having nothing', () {
      controller.codeEntered(payload().encode());
      controller.state.recordOutcome(const PairFailed('stale'));

      controller.clearCode();

      expect(controller.state.code, isA<PairCodeMissing>());
      // The verdict of an attempt on the code that has just gone does not
      // sit over the one that replaces it.
      expect(controller.state.outcome, isA<PairIdle>());
    });

    test('a new code clears the last attempt\'s verdict', () {
      controller.state.recordOutcome(const PairFailed('stale'));

      controller.codeEntered(payload().encode());

      expect(controller.state.outcome, isA<PairIdle>());
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

  /// The camera, over the same fakes. `ScanCodePage` hands raw text back
  /// and the page feeds it to [PairController.codeEntered], so a scan is
  /// the paste path's text arriving by another road — there is no second
  /// implementation of the exchange to test, only the promise that a scan
  /// on its own sends nothing.
  group('a payload from the camera', () {
    test('a scan fills the page in and starts no exchange by itself', () async {
      var called = false;
      enrol = ({
        required payload,
        required ownIdentity,
        required proposedName,
        required localName,
        required pairedDeviceStore,
      }) async => called = true;

      controller.codeEntered(payload().encode());

      expect(controller.state.code, isA<PairCodeRead>());
      expect(controller.state.outcome, isA<PairIdle>());
      expect(called, isFalse);
    });

    test('the same code read twice is still one exchange, because reading '
        'is not submitting', () async {
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

      // Every frame the code is in view, were the page not a route that
      // closes on the first one.
      controller.codeEntered(payload().encode());
      controller.codeEntered(payload().encode());
      controller.codeEntered(payload().encode());
      await controller.submitPayload(
        localName: 'desktop',
        proposedName: 'phone',
      );

      expect(calls, 1);
      expect(controller.state.outcome, isA<PairSucceeded>());
    });
  });
}
