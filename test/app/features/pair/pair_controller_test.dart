import 'dart:async';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/models/pair_code_reading.dart';
import 'package:dsync/app/features/pair/pair_code.dart';
import 'package:dsync/app/features/pair/pair_controller.dart';
import 'package:dsync/app/features/pair/pair_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// `PairController` over a real `AppController` and a `FakeHub`: what
/// the page shows for a code, when it asks the core to redeem one, and how
/// the core's answer lands. Reading a payload and the exchange itself are
/// the core's (native/domain `pair_code`, native/hub `pairing`).
void main() {
  late FakeHub core;
  late AppController app;
  late PairController controller;

  const readable = ReadPairCode(
    desktopName: 'desktop',
    address: '10.0.0.9:28771',
    deviceId: 'dddd-eeee-ffff-0000',
  );
  const payloadText = 'dsync-pair:1.0:fake';

  /// The device the core records for the redeemed code, under [name].
  wire.ReplyResult paired(String name) => wire.ReplyResultDevice(
    value: wireDevice(
      pairedDevice(
        deviceId: readable.deviceId!,
        name: name,
        address: readable.address,
      ),
    ),
  );

  setUp(() {
    core = FakeHub()
      ..reply<wire.CoreCommandReadPairCode>(
        wire.ReplyResultPairCode(value: wirePairCode(readable)),
      )
      ..reply<wire.CoreCommandAcceptPairing>(paired('desktop'));
    app = fakeApp(core);
    controller = PairController(app);
  });

  tearDown(() {
    controller.dispose();
    app.dispose();
  });

  int acceptCalls() => core.sent<wire.CoreCommandAcceptPairing>().length;

  /// Enters the code and submits under [localName].
  Future<void> submit({String localName = 'desktop'}) async {
    await controller.codeEntered(payloadText);
    await controller.submitPayload(localName: localName);
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
        await submit(localName: '   ');

        expect(controller.state.localNameError, isNotNull);
        expect(controller.state.outcome, isA<PairIdle>());
        expect(acceptCalls(), 0);
      },
    );

    test('a valid name clears an earlier field error', () async {
      await submit(localName: '');
      expect(controller.state.localNameError, isNotNull);

      core.reply<wire.CoreCommandAcceptPairing>(failed('refused'));
      await submit();

      expect(controller.state.localNameError, isNull);
    });

    test('an edit is validated where it stands, without a submit', () {
      controller.localNameEdited('  ');

      expect(controller.state.localNameError, isNotNull);
      expect(controller.state.outcome, isA<PairIdle>());

      controller.localNameEdited(' studio ');

      expect(controller.state.localNameError, isNull);
    });

    test('a keystroke that leaves the line as it was notifies nobody', () {
      var notified = 0;
      controller.state.addListener(() => notified++);

      controller.localNameEdited('s');
      controller.localNameEdited('st');
      controller.localNameEdited('stu');

      expect(notified, 0);
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

    test('a payload shows what the core read: the device and the address it '
        'will be reached at, and keeps the line to redeem', () async {
      await controller.codeEntered(payloadText);

      expect(core.sent<wire.CoreCommandReadPairCode>(), const [
        wire.CoreCommandReadPairCode(text: payloadText),
      ]);
      expect(core.kinds, [wire.CoreCommandReadPairCode]);
      expect(readCode().desktopName, 'desktop');
      expect(readCode().address, '10.0.0.9:28771');
      expect(readCode().payload, payloadText);
    });

    test('an unreadable code carries the core\'s own message, and is not a '
        'failed pairing', () async {
      core.reply<wire.CoreCommandReadPairCode>(
        const wire.ReplyResultPairCode(
          value: wire.PairCodeViewUnreadable(
            message: 'Not a dsync pairing payload',
          ),
        ),
      );

      await controller.codeEntered('hello world');

      final code = controller.state.code;
      expect(code, isA<PairCodeUnreadable>());
      expect(
        (code as PairCodeUnreadable).message,
        contains('Not a dsync pairing payload'),
      );
      // Nothing was attempted, so there is no verdict to render either.
      expect(controller.state.outcome, isA<PairIdle>());
    });

    test('a refused reading is unreadable too', () async {
      core.reply<wire.CoreCommandReadPairCode>(
        failed('the core is not initialised'),
      );

      await controller.codeEntered(payloadText);

      expect(
        (controller.state.code as PairCodeUnreadable).message,
        'the core is not initialised',
      );
      expect(controller.state.outcome, isA<PairIdle>());
    });

    test('no code means no exchange, whatever the name says', () async {
      await controller.submitPayload(localName: 'desktop');

      expect(failedMessage(), contains('Scan or paste'));
      expect(acceptCalls(), 0);
    });

    test('an unreadable code is no code to redeem', () async {
      core.reply<wire.CoreCommandReadPairCode>(
        const wire.ReplyResultPairCode(
          value: wire.PairCodeViewUnreadable(message: 'nope'),
        ),
      );
      await controller.codeEntered('hello');

      await controller.submitPayload(localName: 'desktop');

      expect(failedMessage(), contains('Scan or paste'));
      expect(acceptCalls(), 0);
    });

    test('clearing puts the page back to having nothing', () async {
      await controller.codeEntered(payloadText);
      controller.state.recordOutcome(const PairFailed('stale'));

      controller.clearCode();

      expect(controller.state.code, isA<PairCodeMissing>());
      // The verdict of an attempt on the code that has just gone does not
      // sit over the one that replaces it.
      expect(controller.state.outcome, isA<PairIdle>());
    });

    test(
      'a fresh visit clears the code, the verdict and the field line',
      () async {
        await controller.codeEntered(payloadText);
        controller.state.recordOutcome(const PairFailed('stale'));
        controller.state.recordLocalNameError('local missing');

        controller.beginPairing();

        expect(controller.state.code, isA<PairCodeMissing>());
        expect(controller.state.outcome, isA<PairIdle>());
        expect(controller.state.localNameError, isNull);
      },
    );

    test('a new code clears the last attempt\'s verdict', () async {
      controller.state.recordOutcome(const PairFailed('stale'));

      await controller.codeEntered(payloadText);

      expect(controller.state.outcome, isA<PairIdle>());
    });
  });

  test('a refused exchange is shown in the core\'s own words', () async {
    core.reply<wire.CoreCommandAcceptPairing>(
      failed('the other device refused this pairing: token expired at 11:21'),
    );

    await submit();

    expect(
      failedMessage(),
      'the other device refused this pairing: token expired at 11:21',
    );
    expect(app.state.devices, isEmpty);
  });

  group('success', () {
    test('redeems the held line under the trimmed name, then shows the new '
        'row', () async {
      expect(app.state.devices, isEmpty);
      core
        ..reply<wire.CoreCommandAcceptPairing>(paired('my desktop'))
        ..reply<wire.CoreCommandListDevices>(
          devicesReply([
            pairedDevice(deviceId: readable.deviceId!, name: 'my desktop'),
          ]),
        );

      await submit(localName: ' my desktop ');

      expect(core.sent<wire.CoreCommandAcceptPairing>(), const [
        wire.CoreCommandAcceptPairing(code: payloadText, name: 'my desktop'),
      ]);
      expect(controller.state.outcome, isA<PairSucceeded>());
      expect(
        (controller.state.outcome as PairSucceeded).deviceName,
        'my desktop',
      );
      // `refreshDevices()` ran: the row the core recorded is now listed.
      expect(app.state.devices.map((d) => d.name), ['my desktop']);
      expect(app.state.devices.single.deviceId, readable.deviceId);
    });

    test(
      'a list that cannot be re-read after the add is "paired, but"',
      () async {
        core.reply<wire.CoreCommandListDevices>(
          failed('paired-devices.json is damaged'),
        );

        await submit();

        final message = failedMessage();
        expect(message, startsWith('Paired, but'));
        expect(message, contains('paired-devices.json'));
      },
    );

    test('moves through submitting before the verdict', () async {
      // The outcome as it stood at each notification, with repeats dropped:
      // the state notifies for everything it holds, and the id recorded on
      // the way into the exchange lands while the outcome is still
      // submitting.
      final seen = <PairOutcome>[];
      controller.state.addListener(() {
        final outcome = controller.state.outcome;
        if (seen.isEmpty || seen.last != outcome) seen.add(outcome);
      });
      core.reply<wire.CoreCommandAcceptPairing>(failed('refused'));

      await submit();

      expect(seen.whereType<PairSubmitting>(), hasLength(1));
      expect(seen.last, isA<PairFailed>());
    });
  });

  /// The other half of the far end's confirmation: it asks whoever is
  /// standing there to match the id it was presented against the one this
  /// device shows, so this device has to show one (task 23344d, SPEC §4.4).
  group("this device's own id", () {
    test('is not on screen before anything is sent', () async {
      await controller.codeEntered(payloadText);

      expect(controller.state.ownDeviceId, isNull);
    });

    test('is recorded before the exchange, not after it', () async {
      final exchange = Completer<void>();
      core.hold<wire.CoreCommandAcceptPairing>(exchange.future);

      await controller.codeEntered(payloadText);
      final submitted = controller.submitPayload(localName: 'desktop');
      // Let the controller reach the exchange, which the hold keeps open.
      while (acceptCalls() == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      // The far end asks its question the moment the token is redeemed, so
      // the id has to be on screen by now — not once the exchange is back.
      expect(controller.state.ownDeviceId, fakeIdentity.deviceId);

      exchange.complete();
      await submitted;
    });

    test('stays up after a refusal, which is when it is read out', () async {
      core.reply<wire.CoreCommandAcceptPairing>(failed('token already used'));

      await submit();

      expect(controller.state.ownDeviceId, fakeIdentity.deviceId);
    });

    test('is gone again on a fresh visit to the page', () async {
      core.reply<wire.CoreCommandAcceptPairing>(failed('refused'));
      await submit();
      expect(controller.state.ownDeviceId, isNotNull);

      controller.beginPairing();

      expect(controller.state.ownDeviceId, isNull);
    });
  });

  /// The camera: `ScanCodePage` hands raw text back and the page feeds it
  /// to [PairController.codeEntered], so a scan is the paste path's text
  /// arriving by another road — the only promise to test is that a scan on
  /// its own sends nothing.
  group('a payload from the camera', () {
    test('a scan fills the page in and starts no exchange by itself', () async {
      await controller.codeEntered(payloadText);

      expect(controller.state.code, isA<PairCodeRead>());
      expect(controller.state.outcome, isA<PairIdle>());
      expect(acceptCalls(), 0);
    });

    test('the same code read twice is still one exchange, because reading '
        'is not submitting', () async {
      // Every frame the code is in view, were the page not a route that
      // closes on the first one.
      await controller.codeEntered(payloadText);
      await controller.codeEntered(payloadText);
      await controller.codeEntered(payloadText);
      await controller.submitPayload(localName: 'desktop');

      expect(acceptCalls(), 1);
      expect(controller.state.outcome, isA<PairSucceeded>());
    });
  });
}
