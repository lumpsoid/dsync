import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/peer_probe_outcome.dart';
import 'package:dsync/app/features/device_detail/device_detail_controller.dart';
import 'package:dsync/app/features/device_detail/device_detail_view_state.dart';
import 'package:dsync/app/features/run_setup/folder_picker.dart';
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// The Device controller over a real `AppController` and a `FakeHub`,
/// so every refusal it renders is the core's own words.
///
/// The folder chooser is the other thing faked: it is a platform channel,
/// the condition that earns an abstraction, and the interface already
/// exists (`FolderPicker`).
void main() {
  late FakeHub core;
  late AppController app;
  late DeviceDetailController controller;
  late _FakePicker picker;

  setUp(() {
    core = FakeHub();
    app = fakeApp(core);
    picker = _FakePicker();
    controller = DeviceDetailController(app, picker: picker);
  });

  tearDown(() {
    controller.dispose();
    app.dispose();
  });

  Future<String> selectPhone({
    List<String> roots = const ['/home/me/notes'],
  }) async {
    core.devices.add(
      pairedDevice(
        deviceId: 'phone-id',
        name: 'phone',
        grantedRoots: roots,
        address: '10.0.0.7:28771',
      ),
    );
    await app.bootstrap();
    controller.select('phone-id');
    return 'phone-id';
  }

  String failure() => (controller.state.outcome as DeviceDetailFailed).message;

  group('device', () {
    test('reads the row back by the selected id', () async {
      await selectPhone();

      expect(controller.device!.name, 'phone');
      expect(controller.device!.agreedRoots, ['/home/me/notes']);
    });

    test('goes null once the device is revoked', () async {
      await selectPhone();

      await controller.revoke();

      expect(controller.device, isNull);
      expect(controller.state.outcome, isA<DeviceDetailDone>());
    });

    test('select clears the previous device\'s outcome', () async {
      final id = await selectPhone();
      await controller.rename('');
      expect(controller.state.outcome, isA<DeviceDetailFailed>());

      controller.select(id);

      expect(controller.state.outcome, isA<DeviceDetailIdle>());
    });
  });

  group('rename', () {
    test('relabels the device and re-renders the list', () async {
      await selectPhone();

      await controller.rename('  work phone  ');

      expect(controller.device!.name, 'work phone');
      expect(app.state.devices.single.name, 'work phone');
    });

    test('a name another device holds is the core\'s own refusal', () async {
      await selectPhone();
      core.failNext = const CoreFailure(
        'a device named "laptop" is already paired',
      );

      await controller.rename('laptop');

      expect(failure(), contains('already paired'));
      expect(controller.device!.name, 'phone');
    });

    test('a blank name is refused before the store', () async {
      await selectPhone();

      await controller.rename('   ');

      expect(failure(), 'Give the device a name.');
      expect(controller.device!.name, 'phone');
    });
  });

  group('grantRoot', () {
    test('hands the typed path to the core, trimmed, and records it', () async {
      await selectPhone(roots: const []);

      // The core expands `~` the way `dsync pair grant` does; the fake
      // stores it as given.
      await controller.grantRoot('  ~/photos ');

      expect(controller.device!.agreedRoots, ['~/photos']);
      expect(
        (controller.state.outcome as DeviceDetailDone).message,
        'Sharing ~/photos with this device.',
      );
    });

    test('a path the core will not take is its refusal', () async {
      await selectPhone(roots: const []);
      core.failNext = const CoreFailure('not an absolute path');

      await controller.grantRoot('photos');

      expect(failure(), 'not an absolute path');
      expect(controller.device!.agreedRoots, isEmpty);
    });

    test('is additive, and the list stays sorted', () async {
      await selectPhone(roots: const ['/home/me/notes']);

      await controller.grantRoot('/home/me/archive');

      expect(controller.device!.agreedRoots, [
        '/home/me/archive',
        '/home/me/notes',
      ]);
    });

    test('an empty path is refused before the store', () async {
      await selectPhone(roots: const []);

      await controller.grantRoot('  ');

      expect(failure(), 'Give a folder to share.');
      expect(controller.device!.agreedRoots, isEmpty);
    });

    test('the chooser fills the path when the user picks one', () async {
      await selectPhone(roots: const []);
      picker.picked = '/media/usb/sync';

      await controller.grantPickedRoot();

      expect(controller.device!.agreedRoots, ['/media/usb/sync']);
    });

    test('a dismissed chooser grants nothing and says nothing', () async {
      await selectPhone(roots: const []);
      picker.picked = null;

      await controller.grantPickedRoot();

      expect(controller.device!.agreedRoots, isEmpty);
      expect(controller.state.outcome, isA<DeviceDetailIdle>());
    });

    test('a chooser that will not open is reported, not thrown', () async {
      await selectPhone(roots: const []);
      picker.throws = true;

      await controller.grantPickedRoot();

      expect(failure(), contains('Could not open the folder chooser'));
    });
  });

  group('updateAddress', () {
    test('records a typed host:port as where the device is reached', () async {
      await selectPhone();

      await controller.updateAddress(' 10.0.0.9:9100 ');

      expect(controller.device!.address, '10.0.0.9:9100');
      expect(
        (controller.state.outcome as DeviceDetailDone).message,
        contains('10.0.0.9:9100'),
      );
    });

    test('an address the core will not read is its refusal, and nothing '
        'is written', () async {
      await selectPhone();
      core.failNext = const CoreFailure('"10.0.0.9:http" has no valid port');

      await controller.updateAddress('10.0.0.9:http');

      expect(failure(), contains('has no valid port'));
      expect(controller.device!.address, '10.0.0.7:28771');
      // The list is re-read on the refusal path.
      expect(core.calls.last, 'listDevices');
    });

    test('blank text is refused before the store', () async {
      await selectPhone();

      await controller.updateAddress('   ');

      expect(failure(), 'Give an address, as host or host:port.');
      expect(controller.device!.address, '10.0.0.7:28771');
    });
  });

  group('testConnection', () {
    test('asks the core to probe this device', () async {
      await selectPhone();

      await controller.testConnection();

      expect(core.calls, contains('probePeer'));
    });

    test('a reachable peer records the address it answered at', () async {
      await selectPhone();
      core.probeOutcome = const PeerReachable('10.0.0.9:9100');

      await controller.testConnection();

      expect(
        (controller.state.outcome as DeviceDetailDone).message,
        'Reached phone at 10.0.0.9:9100.',
      );
      expect(controller.device!.address, '10.0.0.9:9100');
    });

    test(
      'an address that does not answer names the address, not the pin',
      () async {
        await selectPhone();
        core.probeOutcome = const PeerUnreachable('Connection refused');

        await controller.testConnection();

        expect(failure(), contains('Could not reach phone at 10.0.0.7:28771'));
        expect(failure(), contains('Connection refused'));
        expect(controller.device!.address, '10.0.0.7:28771');
      },
    );

    test(
      'a certificate that is not the pinned one is its own answer',
      () async {
        await selectPhone();
        core.probeOutcome = const PeerRefused('unknown certificate');

        await controller.testConnection();

        expect(failure(), contains('Something answered at 10.0.0.7:28771'));
        expect(failure(), contains('did not present the certificate'));
        expect(failure(), isNot(contains('Could not reach')));
      },
    );

    test('a probe the core refuses outright is shown', () async {
      await selectPhone();
      core.failNext = const CoreFailure('no identity');

      await controller.testConnection();

      expect(failure(), 'no identity');
    });
  });

  group('verification', () {
    test('confirming records the date and shows on the row', () async {
      final id = await selectPhone();

      await controller.confirmDeviceId();

      expect(controller.device!.verifiedAt, isNotNull);
      expect(controller.device!.isVerified, isTrue);
      expect(
        core.devices.singleWhere((d) => d.deviceId == id).verifiedAt,
        isNotNull,
      );
      expect(
        (controller.state.outcome as DeviceDetailDone).message,
        'Device id confirmed.',
      );
    });

    test('clearing takes it back off without touching the pairing', () async {
      final id = await selectPhone();
      await controller.confirmDeviceId();

      await controller.clearVerification();

      expect(controller.device!.verifiedAt, isNull);
      expect(core.devices.singleWhere((d) => d.deviceId == id).grantedRoots, [
        '/home/me/notes',
      ]);
    });

    test('a mismatch writes nothing and says what to do', () async {
      final id = await selectPhone();

      controller.reportDeviceIdMismatch();

      expect(
        core.devices.singleWhere((d) => d.deviceId == id).verifiedAt,
        isNull,
      );
      expect(core.calls, isNot(contains('verifyDevice')));
      expect(failure(), contains('revoke it below and pair again'));
    });

    test('a device revoked elsewhere is refused, not confirmed', () async {
      final id = await selectPhone();
      core.devices.removeWhere((d) => d.deviceId == id);

      await controller.confirmDeviceId();

      expect(failure(), contains('not paired'));
      // The stale row goes with the message.
      expect(controller.device, isNull);
    });
  });

  group('revokeRoot', () {
    test('withdraws one root and keeps the pairing', () async {
      await selectPhone(roots: const ['/home/me/notes', '/home/me/photos']);

      await controller.revokeRoot('/home/me/notes');

      expect(controller.device!.agreedRoots, ['/home/me/photos']);
      expect(controller.device!.name, 'phone');
    });
  });
}

/// A `FolderPicker` that answers with whatever the test set — the platform
/// channel the real one wraps cannot run in a test, which is the condition
/// that earns the interface.
class _FakePicker implements FolderPicker {
  String? picked;
  bool throws = false;

  @override
  Future<String?> pick() async {
    if (throws) throw const FileSystemException('no chooser');
    return picked;
  }

  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<void> openSettings() async {}
}
