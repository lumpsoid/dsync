import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/device_detail/device_detail_controller.dart';
import 'package:dsync/app/features/device_detail/device_detail_view_state.dart';
import 'package:dsync/app/features/device_detail/peer_probe.dart';
import 'package:dsync/app/features/run_setup/folder_picker.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// The Device controller over a real `AppController` and a real
/// `PairedDeviceStore` in a temporary directory — the same setup
/// `devices_controller_test.dart` uses — so every refusal it renders is the
/// store's own.
///
/// The folder chooser is the one thing faked: it is a platform channel, the
/// condition that earns an abstraction, and the interface already exists
/// (`FolderPicker`).
void main() {
  late Directory tempDir;
  late AppController app;
  late DeviceDetailController controller;
  late _FakePicker picker;
  late _FakeProbe probe;
  late String certA;
  late String certB;

  setUpAll(() {
    certA = generateDeviceIdentity(commonName: 'phone-a').certificatePem;
    certB = generateDeviceIdentity(commonName: 'phone-b').certificatePem;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('device_detail_test');
    app = AppController(() async => AppPaths(tempDir.path), now: DateTime.now);
    picker = _FakePicker();
    probe = _FakeProbe();
    controller = DeviceDetailController(
      app,
      environment: const {'HOME': '/home/me'},
      picker: picker,
      probe: probe,
    );
  });

  tearDown(() async {
    controller.dispose();
    app.dispose();
    await tempDir.delete(recursive: true);
  });

  PairedDeviceStore store() =>
      PairedDeviceStore(File('${tempDir.path}/dsync/paired-devices.json'));

  PairedDevice device(
    String certificatePem, {
    required String name,
    Set<String> roots = const {'/home/me/notes'},
  }) => PairedDevice(
    certificatePem: certificatePem,
    name: name,
    agreedReplicaRoots: roots,
    pairedAt: DateTime.utc(2026, 9, 15, 11, 21),
    lastKnownAddress: PeerAddress(host: '10.0.0.7', port: 28771),
  );

  Future<String> selectPhone({
    Set<String> roots = const {'/home/me/notes'},
  }) async {
    final phone = device(certA, name: 'phone', roots: roots);
    await store().add(phone);
    await app.bootstrap();
    controller.select(phone.deviceId);
    return phone.deviceId;
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

    test('a name another device holds is the store\'s own refusal', () async {
      await selectPhone();
      await store().add(device(certB, name: 'laptop'));
      await app.refreshDevices();

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
    test('expands ~ the way `dsync pair grant` does, and records it', () async {
      await selectPhone(roots: const {});

      await controller.grantRoot('~/photos');

      expect(controller.device!.agreedRoots, ['/home/me/photos']);
      expect(
        (controller.state.outcome as DeviceDetailDone).message,
        contains('/home/me/photos'),
      );
    });

    test('is additive, and the list stays sorted', () async {
      await selectPhone(roots: const {'/home/me/notes'});

      await controller.grantRoot('/home/me/archive');

      expect(controller.device!.agreedRoots, [
        '/home/me/archive',
        '/home/me/notes',
      ]);
    });

    test('an empty path is refused before the store', () async {
      await selectPhone(roots: const {});

      await controller.grantRoot('  ');

      expect(failure(), 'Give a folder to share.');
      expect(controller.device!.agreedRoots, isEmpty);
    });

    test('the chooser fills the path when the user picks one', () async {
      await selectPhone(roots: const {});
      picker.picked = '/media/usb/sync';

      await controller.grantPickedRoot();

      expect(controller.device!.agreedRoots, ['/media/usb/sync']);
    });

    test('a dismissed chooser grants nothing and says nothing', () async {
      await selectPhone(roots: const {});
      picker.picked = null;

      await controller.grantPickedRoot();

      expect(controller.device!.agreedRoots, isEmpty);
      expect(controller.state.outcome, isA<DeviceDetailIdle>());
    });

    test('a chooser that will not open is reported, not thrown', () async {
      await selectPhone(roots: const {});
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

    test('a bare host keeps PeerAddress\'s default port', () async {
      await selectPhone();

      await controller.updateAddress('desktop.local');

      expect(controller.device!.address, 'desktop.local:28771');
    });

    test(
      'an unreadable port is a field error, and nothing is written',
      () async {
        await selectPhone();

        await controller.updateAddress('10.0.0.9:http');

        expect(failure(), contains('Not a valid address'));
        expect(controller.device!.address, '10.0.0.7:28771');
      },
    );

    test(
      'a port out of range comes back as PeerAddress\'s own refusal',
      () async {
        await selectPhone();

        await controller.updateAddress('10.0.0.9:99999');

        expect(failure(), contains('Not a valid address'));
        expect(controller.device!.address, '10.0.0.7:28771');
      },
    );

    test('blank text is refused before the store', () async {
      await selectPhone();

      await controller.updateAddress('   ');

      expect(failure(), 'Give an address, as host or host:port.');
      expect(controller.device!.address, '10.0.0.7:28771');
    });
  });

  group('testConnection', () {
    test('dials the address on file, pinned to this device\'s id', () async {
      final id = await selectPhone();
      await controller.updateAddress('10.0.0.9:9100');

      await controller.testConnection();

      expect(probe.dialed!.host, '10.0.0.9');
      expect(probe.dialed!.port, 9100);
      expect(probe.pinnedTo, id);
    });

    test('a reachable peer records the address it answered at', () async {
      await selectPhone();
      await controller.updateAddress('10.0.0.9:9100');

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
        probe.result = const PeerUnreachable('Connection refused');

        await controller.testConnection();

        expect(failure(), contains('Could not reach phone at 10.0.0.7:28771'));
        expect(failure(), contains('Connection refused'));
      },
    );

    test(
      'a certificate that is not the pinned one is its own answer',
      () async {
        await selectPhone();
        probe.result = const PeerCertificateRefused('unknown certificate');

        await controller.testConnection();

        expect(failure(), contains('Something answered at 10.0.0.7:28771'));
        expect(failure(), contains('did not present the certificate'));
        expect(failure(), isNot(contains('Could not reach')));
      },
    );
  });

  group('verification', () {
    test('confirming records the date and shows on the row', () async {
      final id = await selectPhone();

      await controller.confirmDeviceId();

      expect(controller.device!.verifiedAt, isNotNull);
      expect(controller.device!.isVerified, isTrue);
      expect((await store().byDeviceId(id))!.verifiedAt, isNotNull);
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
      expect((await store().byDeviceId(id))!.agreedReplicaRoots, {
        '/home/me/notes',
      });
    });

    test('a mismatch writes nothing and says what to do', () async {
      final id = await selectPhone();

      controller.reportDeviceIdMismatch();

      expect((await store().byDeviceId(id))!.verifiedAt, isNull);
      expect(failure(), contains('revoke it below and pair again'));
    });

    test('a device revoked elsewhere is refused, not confirmed', () async {
      final id = await selectPhone();
      await store().revoke(id);

      await controller.confirmDeviceId();

      expect(failure(), contains('No paired device'));
    });
  });

  group('revokeRoot', () {
    test('withdraws one root and keeps the pairing', () async {
      await selectPhone(roots: const {'/home/me/notes', '/home/me/photos'});

      await controller.revokeRoot('/home/me/notes');

      expect(controller.device!.agreedRoots, ['/home/me/photos']);
      expect(controller.device!.name, 'phone');
    });
  });
}

/// A `PeerProbe` that answers with whatever the test set and records what
/// it was asked to dial — the socket the real one opens is exactly what a
/// unit test cannot run, which is what earns the interface.
class _FakeProbe implements PeerProbe {
  PeerProbeResult result = const PeerReachable();
  PeerAddress? dialed;
  String? pinnedTo;

  @override
  Future<PeerProbeResult> probe({
    required PeerAddress address,
    required String expectedPeerDeviceId,
    required DeviceIdentity ownIdentity,
    required DateTime now,
  }) async {
    dialed = address;
    pinnedTo = expectedPeerDeviceId;
    return result;
  }
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
