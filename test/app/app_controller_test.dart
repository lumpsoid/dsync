import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/core_link.dart';
import 'package:dsync/app/core_link/models/core_dirs.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/device_identity_info.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/core_link/models/profile_entry.dart';
import 'package:dsync/app/profile_breakage.dart';
import 'package:test/test.dart';

import 'support/fake_hub.dart';
import 'support/fake_head.dart';

void main() {
  late FakeHub core;
  late AppController controller;

  setUp(() {
    core = FakeHub();
    controller = fakeApp(core);
  });

  tearDown(() => controller.dispose());

  group('init', () {
    test('is sent once, with the support dir and the device name', () async {
      var asked = 0;
      final app = AppController(
        CoreLink(core),
        supportDir: () async {
          asked++;
          return '/data/app/files';
        },
        now: fixedNow,
      );

      await app.dirs;
      await app.dirs;
      await app.bootstrap();

      expect(asked, 1);
      expect(core.calls.where((call) => call == 'init'), hasLength(1));
      expect(core.initialised, (
        supportDir: '/data/app/files',
        deviceName: AppController.deviceName,
      ));
      app.dispose();
    });

    test('is sent again after it failed', () async {
      core.failNext = const CoreFailure('no support dir');
      await expectLater(controller.dirs, throwsA(isA<CoreFailure>()));

      final dirs = await controller.dirs;

      expect(dirs.stateDir, '/fake/state');
      expect(core.calls.where((call) => call == 'init'), hasLength(2));
    });

    test('settings.json lives in the core\'s state dir', () async {
      core.dirs = const CoreDirs(
        stateDir: '/elsewhere/dsync',
        profilesDir: '/elsewhere/dsync/profiles',
      );
      // The store is only a path until it is read, so nothing is created.
      final settings = await controller.settings;
      expect(settings, isNotNull);
      expect(core.calls, ['init']);
    });
  });

  group('bootstrap', () {
    test('starts loading and lands ready with the core\'s identity', () async {
      expect(controller.state.bootstrap, isA<AppBootstrapLoading>());

      await controller.bootstrap();

      final ready = controller.state.bootstrap as AppBootstrapReady;
      expect(ready.identity.deviceId, FakeHub.fakeIdentity.deviceId);
      expect(ready.identity.name, 'this-device');
      expect(ready.identity.certificateWarning, isNull);
      expect(controller.state.devices, isEmpty);
      expect(core.calls, ['init', 'showIdentity', 'listDevices']);
    });

    test('notifies listeners on each transition', () async {
      final seen = <Type>[];
      controller.state.addListener(
        () => seen.add(controller.state.bootstrap.runtimeType),
      );

      await controller.bootstrap();

      expect(seen.first, AppBootstrapLoading);
      expect(seen.last, AppBootstrapReady);
    });

    test('renders the paired devices the core lists', () async {
      core.devices.add(pairedDevice(name: 'phone'));

      await controller.bootstrap();

      expect(controller.state.devices.map((d) => d.name), ['phone']);
    });

    test("shows the core's expiry warning for this device", () async {
      core.identity = DeviceIdentityInfo(
        deviceId: 'fake-device-id',
        commonName: 'this-device',
        issuedAt: DateTime.utc(2016),
        expiresAt: DateTime.utc(2026, 6, 11),
        expiryNote: 'certificate for this host expires in 10 days',
      );

      await controller.bootstrap();

      final ready = controller.state.bootstrap as AppBootstrapReady;
      expect(
        ready.identity.certificateWarning,
        'certificate for this host expires in 10 days',
      );
    });

    test('fails with the core\'s own words on a refusal', () async {
      core.failNext = const CoreFailure(
        'the identity at /state/identity.crt is half-written',
      );

      await controller.bootstrap();

      final failed = controller.state.bootstrap as AppBootstrapFailed;
      expect(failed.message, contains('/state/identity.crt'));
      expect(controller.state.devices, isEmpty);
    });

    test('a retry after a failure lands ready', () async {
      core.failNext = const CoreFailure('damaged');
      await controller.bootstrap();
      expect(controller.state.bootstrap, isA<AppBootstrapFailed>());

      await controller.bootstrap();

      expect(controller.state.bootstrap, isA<AppBootstrapReady>());
    });
  });

  group('renewIdentity', () {
    test('records the re-issued identity on the gate', () async {
      await controller.bootstrap();

      final failure = await controller.renewIdentity(commonName: 'pocket');

      expect(failure, isNull);
      final ready = controller.state.bootstrap as AppBootstrapReady;
      expect(ready.identity.name, 'pocket');
    });

    test('renders a refusal as the message', () async {
      await controller.bootstrap();
      core.failNext = const CoreFailure('no identity to renew');

      expect(await controller.renewIdentity(), 'no identity to renew');
      expect(controller.state.bootstrap, isA<AppBootstrapReady>());
    });
  });

  group('refreshDevices', () {
    test('picks up a device the core lists since', () async {
      await controller.bootstrap();
      expect(controller.state.devices, isEmpty);

      core.devices.add(pairedDevice(name: 'phone'));
      await controller.refreshDevices();

      expect(controller.state.devices.map((d) => d.name), ['phone']);
    });

    test('renders a row from the core\'s values', () async {
      core.devices.add(
        pairedDevice(
          deviceId: 'abcd-ef01',
          name: 'phone',
          address: '10.0.0.7:28771',
          pairedAt: DateTime.utc(2026, 9, 15, 11, 21),
          grantedRoots: ['/home/me/notes'],
        ),
      );

      await controller.refreshDevices();

      final row = controller.state.devices.single;
      expect(row.deviceId, 'abcd-ef01');
      expect(row.address, '10.0.0.7:28771');
      expect(row.pairedAt.toUtc(), DateTime.utc(2026, 9, 15, 11, 21));
      expect(row.agreedRootCount, 1);
      expect(row.certificateWarning, isNull);
    });

    test('rethrows a refusal for the caller to surface', () async {
      await controller.bootstrap();
      core.failNext = const CoreFailure('paired-devices.json is damaged');

      await expectLater(
        controller.refreshDevices(),
        throwsA(isA<CoreFailure>()),
      );
    });
  });

  group('device writes', () {
    setUp(() async {
      core.devices
        ..add(pairedDevice(deviceId: 'phone-id', name: 'phone'))
        ..add(pairedDevice(deviceId: 'laptop-id', name: 'laptop'));
      await controller.bootstrap();
    });

    test('revoke removes the row and keeps the others', () async {
      final failure = await controller.revoke('phone-id');

      expect(failure, isNull);
      // Positive control: 'laptop' still present, so an empty list — a
      // broken query — could not pass this.
      expect(controller.state.devices.map((d) => d.name), ['laptop']);
    });

    test(
      'an unknown id renders as a message, and the list is re-read',
      () async {
        final failure = await controller.revoke('dead beef');

        expect(failure, contains('dead beef'));
        expect(controller.state.devices.map((d) => d.name), [
          'phone',
          'laptop',
        ]);
        expect(core.calls.last, 'listDevices');
      },
    );

    test('rename, grant, address and verification land on the rows', () async {
      expect(await controller.renameDevice('phone-id', 'pocket'), isNull);
      expect(await controller.grantRoot('phone-id', '/srv/notes'), isNull);
      expect(
        await controller.updateDeviceAddress('phone-id', '10.0.0.9'),
        isNull,
      );
      expect(await controller.markDeviceVerified('phone-id'), isNull);

      final row = controller.state.devices.first;
      expect(row.name, 'pocket');
      expect(row.agreedRoots, ['/srv/notes']);
      expect(row.address, '10.0.0.9:28771');
      expect(row.isVerified, isTrue);

      expect(await controller.clearDeviceVerification('phone-id'), isNull);
      expect(await controller.revokeRoot('phone-id', '/srv/notes'), isNull);
      final cleared = controller.state.devices.first;
      expect(cleared.isVerified, isFalse);
      expect(cleared.agreedRoots, isEmpty);
    });
  });

  group('profiles', () {
    test('refreshProfiles renders the head\'s profiles as rows', () async {
      core.profiles.add(headProfile(name: 'weekly', profileId: 'p1'));

      await controller.refreshProfiles();

      final row = controller.state.profiles.single;
      expect(row.name, 'weekly');
      expect(row.profileId, 'p1');
      expect(row.peerName, 'desktop');
      expect(row.remoteRootPath, '~/notes');
      expect(row.breakage, isNull);
      expect(row.lastRunUnfinished, isFalse);
    });

    test('a run marker still there renders the last run unfinished', () async {
      core.profiles.add(headProfile(lastRunUnfinished: true));

      await controller.refreshProfiles();

      expect(controller.state.profiles.single.lastRunUnfinished, isTrue);
    });

    test('an unpaired device renders the profile broken, not gone, and '
        'not also offered to run again', () async {
      core.profiles.add(headProfile(peerName: null, lastRunUnfinished: true));

      await controller.refreshProfiles();

      final row = controller.state.profiles.single;
      expect(row.breakage, isA<ProfileDeviceUnpaired>());
      expect(row.lastRunUnfinished, isFalse);
    });

    test('a local root the core refuses renders the profile broken', () async {
      core.profiles.add(headProfile(localRootRefusal: 'no access'));

      await controller.refreshProfiles();

      expect(
        controller.state.profiles.single.breakage,
        isA<ProfileLocalRootUnusable>(),
      );
    });

    test('rethrows a refusal', () async {
      core.failNext = const CoreFailure('profiles unreadable');

      await expectLater(
        controller.refreshProfiles(),
        throwsA(isA<CoreFailure>()),
      );
    });

    test('a save lands on the rendered list at once', () async {
      core.devices.add(pairedDevice());

      await controller.saveProfile(
        'weekly',
        const ProfileDraft(
          localRoot: '/sdcard/Notes',
          peerDeviceId: 'aaaa-bbbb-cccc-dddd',
          remoteRoot: '~/notes',
        ),
      );

      expect(controller.state.profiles.single.name, 'weekly');
    });

    test('a save replacing another name renames it first', () async {
      core.devices.add(pairedDevice());
      core.profiles.add(headProfile(name: 'old'));

      await controller.saveProfile(
        'new',
        const ProfileDraft(
          localRoot: '/sdcard/Notes',
          peerDeviceId: 'aaaa-bbbb-cccc-dddd',
          remoteRoot: '~/notes',
        ),
        replacing: 'old',
      );

      expect(core.calls, ['renameProfile', 'saveProfile']);
      expect(controller.state.profiles.map((p) => p.name), ['new']);
    });

    test('relocate keeps the rest of the profile', () async {
      core.devices.add(pairedDevice());
      core.profiles.add(
        headProfile(name: 'weekly', ignorePatterns: ['**/.git'], jobs: 3),
      );

      final failure = await controller.relocateProfile(
        'weekly',
        localRootPath: '/sdcard/Moved',
      );

      expect(failure, isNull);
      final saved = core.profiles.single as HeadProfile;
      expect(saved.localRoot, '/sdcard/Moved');
      expect(saved.ignorePatterns, ['**/.git']);
      expect(saved.jobs, 3);
      expect(saved.remoteRoot, '~/notes');
    });

    test('relocating a profile that is gone is a message', () async {
      final failure = await controller.relocateProfile(
        'gone',
        localRootPath: '/sdcard/Moved',
      );

      expect(failure, contains('gone'));
    });

    test('delete removes the row and keeps the others', () async {
      core.profiles
        ..add(headProfile(name: 'a'))
        ..add(headProfile(name: 'b'));

      expect(await controller.deleteProfile('a'), isNull);

      // Positive control: 'b' still on the list, so an empty list — a
      // broken query — could not pass this.
      expect(controller.state.profiles.map((p) => p.name), ['b']);
    });

    test(
      'deleting an unknown name renders a message, not an exception',
      () async {
        core.profiles.add(headProfile(name: 'weekly'));

        final failure = await controller.deleteProfile('gone');

        expect(failure, contains('gone'));
        expect(controller.state.profiles.map((p) => p.name), ['weekly']);
      },
    );
  });
}
