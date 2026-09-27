import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/models/paired_device_info.dart';
import 'package:dsync/app/features/device_detail/device_detail_controller.dart';
import 'package:dsync/app/features/device_detail/device_detail_view_state.dart';
import 'package:dsync/app/features/run_setup/folder_picker.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
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

  /// The paired phone as the core lists it.
  PairedDeviceInfo phone({
    String name = 'phone',
    List<String> roots = const ['/home/me/notes'],
    String address = '10.0.0.7:28771',
    DateTime? verifiedAt,
  }) => pairedDevice(
    deviceId: 'phone-id',
    name: name,
    grantedRoots: roots,
    address: address,
    verifiedAt: verifiedAt,
  );

  /// The core's answer: the device list holding [device] alone.
  wire.ReplyResult only(PairedDeviceInfo device) => devicesReply([device]);

  Future<String> selectPhone({
    List<String> roots = const ['/home/me/notes'],
  }) async {
    core.reply<wire.CoreCommandListDevices>(only(phone(roots: roots)));
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
      core.reply<wire.CoreCommandRevokeDevice>(devicesReply(const []));

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
    test('sends the name trimmed, and the core\'s answer relabels the '
        'device and the list', () async {
      await selectPhone();
      core.reply<wire.CoreCommandRenameDevice>(only(phone(name: 'work phone')));

      await controller.rename('  work phone  ');

      expect(
        core.sent<wire.CoreCommandRenameDevice>().single.name,
        'work phone',
      );
      expect(controller.device!.name, 'work phone');
      expect(app.state.devices.single.name, 'work phone');
    });

    test('a name another device holds is the core\'s own refusal', () async {
      await selectPhone();
      core.reply<wire.CoreCommandRenameDevice>(
        failed('a device named "laptop" is already paired'),
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
      expect(core.sent<wire.CoreCommandRenameDevice>(), isEmpty);
    });
  });

  group('grantRoot', () {
    test('hands the typed path to the core, trimmed, and records it', () async {
      await selectPhone(roots: const []);
      // The core expands `~` the way `dsync pair grant` does.
      core.reply<wire.CoreCommandGrantRoot>(
        only(phone(roots: ['/home/me/photos'])),
      );

      await controller.grantRoot('  ~/photos ');

      expect(core.sent<wire.CoreCommandGrantRoot>(), const [
        wire.CoreCommandGrantRoot(deviceId: 'phone-id', path: '~/photos'),
      ]);
      expect(controller.device!.agreedRoots, ['/home/me/photos']);
      expect(
        (controller.state.outcome as DeviceDetailDone).message,
        'Sharing ~/photos with this device.',
      );
    });

    test('a path the core will not take is its refusal', () async {
      await selectPhone(roots: const []);
      core.reply<wire.CoreCommandGrantRoot>(failed('not an absolute path'));

      await controller.grantRoot('photos');

      expect(failure(), 'not an absolute path');
      expect(controller.device!.agreedRoots, isEmpty);
    });

    test('the rows are the core\'s list, in its order', () async {
      await selectPhone(roots: const ['/home/me/notes']);
      core.reply<wire.CoreCommandGrantRoot>(
        only(phone(roots: ['/home/me/archive', '/home/me/notes'])),
      );

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
      expect(core.sent<wire.CoreCommandGrantRoot>(), isEmpty);
    });

    test('the chooser fills the path when the user picks one', () async {
      await selectPhone(roots: const []);
      picker.picked = '/media/usb/sync';
      core.reply<wire.CoreCommandGrantRoot>(
        only(phone(roots: ['/media/usb/sync'])),
      );

      await controller.grantPickedRoot();

      expect(
        core.sent<wire.CoreCommandGrantRoot>().single.path,
        '/media/usb/sync',
      );
      expect(controller.device!.agreedRoots, ['/media/usb/sync']);
    });

    test('a dismissed chooser grants nothing and says nothing', () async {
      await selectPhone(roots: const []);
      picker.picked = null;

      await controller.grantPickedRoot();

      expect(core.sent<wire.CoreCommandGrantRoot>(), isEmpty);
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
    test('sends a typed host:port, trimmed, and records the core\'s '
        'answer', () async {
      await selectPhone();
      core.reply<wire.CoreCommandSetDeviceAddress>(
        only(phone(address: '10.0.0.9:9100')),
      );

      await controller.updateAddress(' 10.0.0.9:9100 ');

      expect(
        core.sent<wire.CoreCommandSetDeviceAddress>().single.address,
        '10.0.0.9:9100',
      );
      expect(controller.device!.address, '10.0.0.9:9100');
      expect(
        (controller.state.outcome as DeviceDetailDone).message,
        contains('10.0.0.9:9100'),
      );
    });

    test('an address the core will not read is its refusal, and nothing '
        'is written', () async {
      await selectPhone();
      core.reply<wire.CoreCommandSetDeviceAddress>(
        failed('"10.0.0.9:http" has no valid port'),
      );

      await controller.updateAddress('10.0.0.9:http');

      expect(failure(), contains('has no valid port'));
      expect(controller.device!.address, '10.0.0.7:28771');
      // The list is re-read on the refusal path.
      expect(core.kinds.last, wire.CoreCommandListDevices);
    });

    test('blank text is refused before the store', () async {
      await selectPhone();

      await controller.updateAddress('   ');

      expect(failure(), 'Give an address, as host or host:port.');
      expect(controller.device!.address, '10.0.0.7:28771');
      expect(core.sent<wire.CoreCommandSetDeviceAddress>(), isEmpty);
    });
  });

  group('testConnection', () {
    test('asks the core to probe this device', () async {
      await selectPhone();
      core.reply<wire.CoreCommandProbePeer>(reached('10.0.0.7:28771'));

      await controller.testConnection();

      expect(
        core.sent<wire.CoreCommandProbePeer>().single.deviceId,
        'phone-id',
      );
    });

    test('a reachable peer records the address it answered at', () async {
      await selectPhone();
      core
        ..reply<wire.CoreCommandProbePeer>(reached('10.0.0.9:9100'))
        ..reply<wire.CoreCommandSetDeviceAddress>(
          only(phone(address: '10.0.0.9:9100')),
        );

      await controller.testConnection();

      expect(
        (controller.state.outcome as DeviceDetailDone).message,
        'Reached phone at 10.0.0.9:9100.',
      );
      // Where it answered is recorded as where it is reached.
      expect(core.sent<wire.CoreCommandSetDeviceAddress>(), const [
        wire.CoreCommandSetDeviceAddress(
          deviceId: 'phone-id',
          address: '10.0.0.9:9100',
        ),
      ]);
      expect(controller.device!.address, '10.0.0.9:9100');
    });

    test(
      'an address that does not answer names the address, not the pin',
      () async {
        await selectPhone();
        core.reply<wire.CoreCommandProbePeer>(
          const wire.ReplyResultPeerProbed(
            value: wire.ProbeOutcomeUnreachable(message: 'Connection refused'),
          ),
        );

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
        core.reply<wire.CoreCommandProbePeer>(
          const wire.ReplyResultPeerProbed(
            value: wire.ProbeOutcomeRefused(message: 'unknown certificate'),
          ),
        );

        await controller.testConnection();

        expect(failure(), contains('Something answered at 10.0.0.7:28771'));
        expect(failure(), contains('did not present the certificate'));
        expect(failure(), isNot(contains('Could not reach')));
      },
    );

    test('a probe the core refuses outright is shown', () async {
      await selectPhone();
      core.reply<wire.CoreCommandProbePeer>(failed('no identity'));

      await controller.testConnection();

      expect(failure(), 'no identity');
    });
  });

  group('verification', () {
    test('confirming asks the core, and its answer shows on the row', () async {
      await selectPhone();
      core.reply<wire.CoreCommandVerifyDevice>(
        only(phone(verifiedAt: DateTime.utc(2026, 6))),
      );

      await controller.confirmDeviceId();

      expect(core.sent<wire.CoreCommandVerifyDevice>(), const [
        wire.CoreCommandVerifyDevice(deviceId: 'phone-id'),
      ]);
      expect(controller.device!.verifiedAt, isNotNull);
      expect(controller.device!.isVerified, isTrue);
      expect(
        (controller.state.outcome as DeviceDetailDone).message,
        'Device id confirmed.',
      );
    });

    test('clearing asks the core, and its answer shows on the row', () async {
      core.reply<wire.CoreCommandListDevices>(
        only(phone(verifiedAt: DateTime.utc(2026, 6))),
      );
      await app.bootstrap();
      controller.select('phone-id');
      expect(controller.device!.isVerified, isTrue);
      core.reply<wire.CoreCommandClearVerification>(only(phone()));

      await controller.clearVerification();

      expect(core.sent<wire.CoreCommandClearVerification>(), const [
        wire.CoreCommandClearVerification(deviceId: 'phone-id'),
      ]);
      expect(controller.device!.verifiedAt, isNull);
      expect(controller.device!.agreedRoots, ['/home/me/notes']);
    });

    test('a mismatch writes nothing and says what to do', () async {
      await selectPhone();

      controller.reportDeviceIdMismatch();

      expect(core.sent<wire.CoreCommandVerifyDevice>(), isEmpty);
      expect(failure(), contains('revoke it below and pair again'));
    });

    test('a device revoked elsewhere is refused, not confirmed', () async {
      await selectPhone();
      core
        ..reply<wire.CoreCommandVerifyDevice>(
          failed('no paired device with id phone-id'),
        )
        ..reply<wire.CoreCommandListDevices>(devicesReply(const []));

      await controller.confirmDeviceId();

      expect(failure(), 'no paired device with id phone-id');
      // The stale row goes with the message.
      expect(controller.device, isNull);
    });
  });

  group('revokeRoot', () {
    test('withdraws one root and keeps the pairing', () async {
      await selectPhone(roots: const ['/home/me/notes', '/home/me/photos']);
      core.reply<wire.CoreCommandWithdrawGrant>(
        only(phone(roots: ['/home/me/photos'])),
      );

      await controller.revokeRoot('/home/me/notes');

      expect(core.sent<wire.CoreCommandWithdrawGrant>(), const [
        wire.CoreCommandWithdrawGrant(
          deviceId: 'phone-id',
          root: '/home/me/notes',
        ),
      ]);
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

  @override
  bool get asksForFileAccess => false;

  @override
  bool get picksFilesNatively => false;

  @override
  Future<String?> pickFile() async => throw UnimplementedError();
}
