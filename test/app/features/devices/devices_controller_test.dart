import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/models/last_run.dart';
import 'package:dsync/app/core_link/models/device_identity_info.dart';
import 'package:dsync/app/features/devices/devices_controller.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:dsync/app/core_link/models/root_kind.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// The Devices controller over a real `AppController` and a
/// `FakeHub`: every outcome it renders comes from the core's answers
/// and refusals.
void main() {
  late FakeHub core;
  late AppController app;
  late DevicesController controller;

  setUp(() {
    core = FakeHub()
      ..reply<wire.CoreCommandListDevices>(
        devicesReply([pairedDevice(name: 'phone')]),
      );
    app = fakeApp(core);
    controller = DevicesController(app);
  });

  tearDown(() => controller.dispose());

  Iterable<String> listedNames() => app.state.devices.map((d) => d.name);

  group('refresh', () {
    test('renders a refusal as an error and keeps the rows', () async {
      await app.bootstrap();
      core.reply<wire.CoreCommandListDevices>(
        failed('paired-devices.json at /state is damaged'),
      );

      await controller.refresh();

      expect(controller.state.error, contains('/state'));
      expect(listedNames(), ['phone']);
    });

    test('a later good read clears the error and shows the rows', () async {
      await app.bootstrap();
      core.reply<wire.CoreCommandListDevices>(failed('damaged'));
      await controller.refresh();
      expect(controller.state.error, isNotNull);

      core.reply<wire.CoreCommandListDevices>(
        devicesReply([
          pairedDevice(name: 'phone'),
          pairedDevice(deviceId: 'other', name: 'laptop'),
        ]),
      );
      await controller.refresh();

      expect(controller.state.error, isNull);
      expect(listedNames(), ['phone', 'laptop']);
    });

    test('notifies the view state on each outcome', () async {
      await app.bootstrap();
      var notified = 0;
      controller.state.addListener(() => notified++);
      core.reply<wire.CoreCommandListDevices>(failed('damaged'));

      await controller.refresh();
      expect(notified, 1);

      core.reply<wire.CoreCommandListDevices>(devicesReply(const []));
      await controller.refresh();
      expect(notified, 2);
    });
  });

  group('ownCertificateWarning', () {
    test('is null before bootstrap', () {
      expect(app.state.bootstrap, isA<AppBootstrapLoading>());
      expect(controller.ownCertificateWarning, isNull);
    });

    test('is null when the core notes nothing', () async {
      await app.bootstrap();

      expect(app.state.bootstrap, isA<AppBootstrapReady>());
      expect(controller.ownCertificateWarning, isNull);
    });

    test("carries the core's line and names the This device page", () async {
      core.reply<wire.CoreCommandShowIdentity>(
        identityReply(
          DeviceIdentityInfo(
            deviceId: 'fake-device-id',
            commonName: 'this-device',
            issuedAt: DateTime.utc(2016),
            expiresAt: DateTime.utc(2026, 6, 11),
            expiryNote: 'certificate for this host expires in 10 days',
          ),
        ),
      );
      await app.bootstrap();

      final warning = controller.ownCertificateWarning;

      expect(warning, contains('certificate for this host expires in 10 days'));
      // The remedy is on this head: it owns the identity it would re-issue.
      expect(warning, contains('Renew it under This device.'));
    });
  });

  group('savedRunLines', () {
    ProfileRow profile(String id, {required String peerDeviceId}) => ProfileRow(
      name: 'run $id',
      peerDeviceId: peerDeviceId,
      peerName: 'phone',
      entries: [
        ProfileEntryRow(
          entryId: id,
          kind: RootKind.folder,
          localRootPath: '/on-device/notes',
          remoteRootPath: '~/notes',
          localRootRefusal: null,
        ),
      ],
      breakage: null,
      lastRun: LastRun.settled,
    );

    test('counts the saved runs that name each device', () {
      app.state.recordProfiles([
        profile('p1', peerDeviceId: 'aaaa'),
        profile('p2', peerDeviceId: 'aaaa'),
        profile('p3', peerDeviceId: 'bbbb'),
      ]);

      expect(controller.savedRunLines, {
        'aaaa': '2 saved runs',
        'bbbb': '1 saved run',
      });
    });

    test('a device no saved run names has no line at all', () {
      app.state.recordProfiles([profile('p1', peerDeviceId: 'aaaa')]);

      // Absent, not "no saved runs": the row's run action already says
      // there is nothing yet.
      expect(controller.savedRunLines['bbbb'], isNull);
    });

    test('an empty home list leaves every device without a line', () {
      app.state.recordProfiles(const []);

      expect(controller.savedRunLines, isEmpty);
    });

    test('the line follows the home list without a device refresh', () {
      app.state.recordProfiles([profile('p1', peerDeviceId: 'aaaa')]);
      expect(controller.savedRunLines['aaaa'], '1 saved run');

      app.state.recordProfiles([
        profile('p1', peerDeviceId: 'aaaa'),
        profile('p2', peerDeviceId: 'aaaa'),
      ]);

      expect(controller.savedRunLines['aaaa'], '2 saved runs');
    });
  });

  group('deviceBeside', () {
    PairedDeviceRow row(String deviceId) => PairedDeviceRow(
      name: deviceId,
      deviceId: deviceId,
      address: '10.0.0.7:28771',
      pairedAt: DateTime(2026, 9, 15),
      agreedRoots: const [],
      certificateIssuedAt: DateTime(2026, 1, 1),
      certificateExpiresAt: DateTime(2027, 1, 1),
      certificateWarning: null,
      verifiedAt: null,
    );

    setUp(() => app.state.recordDevices([row('a'), row('b'), row('c')]));

    test('steps along the list in its order', () {
      expect(controller.deviceBeside('b', 1), 'c');
      expect(controller.deviceBeside('b', -1), 'a');
    });

    test('stops at either end rather than wrapping', () {
      expect(controller.deviceBeside('c', 1), isNull);
      expect(controller.deviceBeside('a', -1), isNull);
    });

    test('starts at the first row from nothing selected, either way', () {
      expect(controller.deviceBeside(null, 1), 'a');
      expect(controller.deviceBeside(null, -1), 'a');
    });

    test('starts at the first row from a device no longer listed', () {
      expect(controller.deviceBeside('revoked', 1), 'a');
    });

    test('has nowhere to go on an empty list', () {
      app.state.recordDevices(const []);

      expect(controller.deviceBeside(null, 1), isNull);
    });
  });
}
