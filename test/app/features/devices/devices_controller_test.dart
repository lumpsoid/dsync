import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/fake_core_link.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/device_identity_info.dart';
import 'package:dsync/app/features/devices/devices_controller.dart';
import 'package:dsync/app/format_path.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:test/test.dart';

import '../../support/fake_head.dart';

/// The Devices controller over a real `AppController` and a
/// `FakeCoreLink`: every outcome it renders comes from the core's answers
/// and refusals.
void main() {
  late FakeCoreLink core;
  late AppController app;
  late DevicesController controller;

  setUp(() {
    core = FakeCoreLink(devices: [pairedDevice(name: 'phone')]);
    app = fakeApp(core);
    controller = DevicesController(app);
  });

  tearDown(() => controller.dispose());

  Iterable<String> listedNames() => app.state.devices.map((d) => d.name);

  group('refresh', () {
    test('renders a refusal as an error and keeps the rows', () async {
      await app.bootstrap();
      core.failNext = const CoreFailure(
        'paired-devices.json at /state is damaged',
      );

      await controller.refresh();

      expect(controller.state.error, contains('/state'));
      expect(listedNames(), ['phone']);
    });

    test('a later good read clears the error and shows the rows', () async {
      await app.bootstrap();
      core.failNext = const CoreFailure('damaged');
      await controller.refresh();
      expect(controller.state.error, isNotNull);

      core.devices.add(pairedDevice(deviceId: 'other', name: 'laptop'));
      await controller.refresh();

      expect(controller.state.error, isNull);
      expect(listedNames(), ['phone', 'laptop']);
    });

    test('notifies the view state on each outcome', () async {
      await app.bootstrap();
      var notified = 0;
      controller.state.addListener(() => notified++);
      core.failNext = const CoreFailure('damaged');

      await controller.refresh();
      expect(notified, 1);

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
      core.identity = DeviceIdentityInfo(
        deviceId: 'fake-device-id',
        commonName: 'this-device',
        issuedAt: DateTime.utc(2016),
        expiresAt: DateTime.utc(2026, 6, 11),
        expiryNote: 'certificate for this host expires in 10 days',
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
      profileId: id,
      peerDeviceId: peerDeviceId,
      peerName: 'phone',
      localRootPath: '/on-device/notes',
      remoteRootPath: '~/notes',
      localRootLabel: PathLabel.of('/on-device/notes'),
      remoteRootLabel: PathLabel.of('~/notes'),
      breakage: null,
      lastRunUnfinished: false,
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
}
