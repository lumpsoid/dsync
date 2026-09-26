import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/core_link.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/device_identity_info.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/profile_breakage.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
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
      expect(core.sent<wire.CoreCommandInit>(), [
        const wire.CoreCommandInit(
          supportDir: '/data/app/files',
          deviceName: AppController.deviceName,
        ),
      ]);
      app.dispose();
    });

    test('is sent again after it failed', () async {
      core.reply<wire.CoreCommandInit>(failed('no support dir'));
      await expectLater(controller.dirs, throwsA(isA<CoreFailure>()));

      core.reply<wire.CoreCommandInit>(
        const wire.ReplyResultInitialised(
          value: wire.DirsView(
            stateDir: '/data/state',
            profilesDir: '/data/state/profiles',
          ),
        ),
      );
      final dirs = await controller.dirs;

      expect(dirs.stateDir, '/data/state');
      expect(core.sent<wire.CoreCommandInit>(), hasLength(2));
    });

    test('settings.json lives in the core\'s state dir', () async {
      core.reply<wire.CoreCommandInit>(
        const wire.ReplyResultInitialised(
          value: wire.DirsView(
            stateDir: '/elsewhere/dsync',
            profilesDir: '/elsewhere/dsync/profiles',
          ),
        ),
      );
      // The store is only a path until it is read, so nothing is created.
      final settings = await controller.settings;
      expect(settings, isNotNull);
      expect(core.kinds, [wire.CoreCommandInit]);
    });
  });

  group('bootstrap', () {
    test('starts loading and lands ready with the core\'s identity', () async {
      expect(controller.state.bootstrap, isA<AppBootstrapLoading>());

      await controller.bootstrap();

      final ready = controller.state.bootstrap as AppBootstrapReady;
      expect(ready.identity.deviceId, fakeIdentity.deviceId);
      expect(ready.identity.name, 'this-device');
      expect(ready.identity.certificateWarning, isNull);
      expect(controller.state.devices, isEmpty);
      expect(core.kinds, [
        wire.CoreCommandInit,
        wire.CoreCommandShowIdentity,
        wire.CoreCommandListDevices,
      ]);
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
      core.reply<wire.CoreCommandListDevices>(
        devicesReply([pairedDevice(name: 'phone')]),
      );

      await controller.bootstrap();

      expect(controller.state.devices.map((d) => d.name), ['phone']);
    });

    test("shows the core's expiry warning for this device", () async {
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

      await controller.bootstrap();

      final ready = controller.state.bootstrap as AppBootstrapReady;
      expect(
        ready.identity.certificateWarning,
        'certificate for this host expires in 10 days',
      );
    });

    test('fails with the core\'s own words on a refusal', () async {
      core.reply<wire.CoreCommandShowIdentity>(
        failed('the identity at /state/identity.crt is half-written'),
      );

      await controller.bootstrap();

      final refused = controller.state.bootstrap as AppBootstrapFailed;
      expect(refused.message, contains('/state/identity.crt'));
      expect(controller.state.devices, isEmpty);
    });

    test('a retry after a failure lands ready', () async {
      core.reply<wire.CoreCommandShowIdentity>(failed('damaged'));
      await controller.bootstrap();
      expect(controller.state.bootstrap, isA<AppBootstrapFailed>());

      core.reply<wire.CoreCommandShowIdentity>(identityReply(fakeIdentity));

      await controller.bootstrap();

      expect(controller.state.bootstrap, isA<AppBootstrapReady>());
    });
  });

  group('renewIdentity', () {
    test('asks for the new name and records the re-issued identity on the '
        'gate', () async {
      await controller.bootstrap();
      core.reply<wire.CoreCommandRenewIdentity>(
        identityReply(
          DeviceIdentityInfo(
            deviceId: fakeIdentity.deviceId,
            commonName: 'pocket',
            issuedAt: DateTime.utc(2026, 6),
            expiresAt: DateTime.utc(2036, 6),
            expiryNote: null,
          ),
        ),
      );

      final failure = await controller.renewIdentity(commonName: 'pocket');

      expect(failure, isNull);
      expect(core.sent<wire.CoreCommandRenewIdentity>(), [
        const wire.CoreCommandRenewIdentity(commonName: 'pocket'),
      ]);
      final ready = controller.state.bootstrap as AppBootstrapReady;
      expect(ready.identity.name, 'pocket');
    });

    test('renders a refusal as the message', () async {
      await controller.bootstrap();
      core.reply<wire.CoreCommandRenewIdentity>(failed('no identity to renew'));

      expect(await controller.renewIdentity(), 'no identity to renew');
      expect(controller.state.bootstrap, isA<AppBootstrapReady>());
    });
  });

  group('refreshDevices', () {
    test('picks up a device the core lists since', () async {
      await controller.bootstrap();
      expect(controller.state.devices, isEmpty);

      core.reply<wire.CoreCommandListDevices>(
        devicesReply([pairedDevice(name: 'phone')]),
      );
      await controller.refreshDevices();

      expect(controller.state.devices.map((d) => d.name), ['phone']);
    });

    test('renders a row from the core\'s values', () async {
      core.reply<wire.CoreCommandListDevices>(
        devicesReply([
          pairedDevice(
            deviceId: 'abcd-ef01',
            name: 'phone',
            address: '10.0.0.7:28771',
            pairedAt: DateTime.utc(2026, 9, 15, 11, 21),
            grantedRoots: ['/home/me/notes'],
          ),
        ]),
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
      core.reply<wire.CoreCommandListDevices>(
        failed('paired-devices.json is damaged'),
      );

      await expectLater(
        controller.refreshDevices(),
        throwsA(isA<CoreFailure>()),
      );
    });
  });

  group('device writes', () {
    final phone = pairedDevice(deviceId: 'phone-id', name: 'phone');
    final laptop = pairedDevice(deviceId: 'laptop-id', name: 'laptop');

    setUp(() async {
      core.reply<wire.CoreCommandListDevices>(devicesReply([phone, laptop]));
      await controller.bootstrap();
    });

    test('revoke sends the id, and the list the core answers is the '
        'rows', () async {
      core.reply<wire.CoreCommandRevokeDevice>(devicesReply([laptop]));

      final failure = await controller.revoke('phone-id');

      expect(failure, isNull);
      expect(core.sent<wire.CoreCommandRevokeDevice>(), [
        const wire.CoreCommandRevokeDevice(deviceId: 'phone-id'),
      ]);
      expect(controller.state.devices.map((d) => d.name), ['laptop']);
    });

    test('a refusal renders as the core\'s message, and the list is '
        're-read', () async {
      core
        ..reply<wire.CoreCommandRevokeDevice>(
          failed('no paired device with id dead beef'),
        )
        ..reply<wire.CoreCommandListDevices>(devicesReply([laptop]));

      final failure = await controller.revoke('dead beef');

      expect(failure, 'no paired device with id dead beef');
      expect(core.kinds.last, wire.CoreCommandListDevices);
      // Positive control: the re-read list, not the one from before.
      expect(controller.state.devices.map((d) => d.name), ['laptop']);
    });

    test('rename, grant, address and verification send what they were '
        'given, and each answer lands on the rows', () async {
      final changed = pairedDevice(
        deviceId: 'phone-id',
        name: 'pocket',
        grantedRoots: ['/srv/notes'],
        address: '10.0.0.9:28771',
        verifiedAt: DateTime.utc(2026, 6),
      );
      core
        ..reply<wire.CoreCommandRenameDevice>(devicesReply([changed]))
        ..reply<wire.CoreCommandGrantRoot>(devicesReply([changed]))
        ..reply<wire.CoreCommandSetDeviceAddress>(devicesReply([changed]))
        ..reply<wire.CoreCommandVerifyDevice>(devicesReply([changed]));

      expect(await controller.renameDevice('phone-id', 'pocket'), isNull);
      expect(await controller.grantRoot('phone-id', '/srv/notes'), isNull);
      expect(
        await controller.updateDeviceAddress('phone-id', '10.0.0.9'),
        isNull,
      );
      expect(await controller.markDeviceVerified('phone-id'), isNull);

      final row = controller.state.devices.single;
      expect(row.name, 'pocket');
      expect(row.agreedRoots, ['/srv/notes']);
      expect(row.address, '10.0.0.9:28771');
      expect(row.isVerified, isTrue);

      final cleared = pairedDevice(deviceId: 'phone-id', name: 'pocket');
      core
        ..reply<wire.CoreCommandClearVerification>(devicesReply([cleared]))
        ..reply<wire.CoreCommandWithdrawGrant>(devicesReply([cleared]));
      expect(await controller.clearDeviceVerification('phone-id'), isNull);
      expect(await controller.revokeRoot('phone-id', '/srv/notes'), isNull);
      expect(controller.state.devices.single.isVerified, isFalse);
      expect(controller.state.devices.single.agreedRoots, isEmpty);

      expect(core.commands.skip(3), const [
        wire.CoreCommandRenameDevice(deviceId: 'phone-id', name: 'pocket'),
        wire.CoreCommandGrantRoot(deviceId: 'phone-id', path: '/srv/notes'),
        wire.CoreCommandSetDeviceAddress(
          deviceId: 'phone-id',
          address: '10.0.0.9',
        ),
        wire.CoreCommandVerifyDevice(deviceId: 'phone-id'),
        wire.CoreCommandClearVerification(deviceId: 'phone-id'),
        wire.CoreCommandWithdrawGrant(deviceId: 'phone-id', root: '/srv/notes'),
      ]);
    });
  });

  group('profiles', () {
    test('refreshProfiles renders the head\'s profiles as rows', () async {
      core.reply<wire.CoreCommandListProfiles>(
        profilesReply([headProfile(name: 'weekly', profileId: 'p1')]),
      );

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
      core.reply<wire.CoreCommandListProfiles>(
        profilesReply([headProfile(lastRunUnfinished: true)]),
      );

      await controller.refreshProfiles();

      expect(controller.state.profiles.single.lastRunUnfinished, isTrue);
    });

    test('an unpaired device renders the profile broken, not gone, and '
        'not also offered to run again', () async {
      core.reply<wire.CoreCommandListProfiles>(
        profilesReply([headProfile(peerName: null, lastRunUnfinished: true)]),
      );

      await controller.refreshProfiles();

      final row = controller.state.profiles.single;
      expect(row.breakage, isA<ProfileDeviceUnpaired>());
      expect(row.lastRunUnfinished, isFalse);
    });

    test('a local root the core refuses renders the profile broken', () async {
      core.reply<wire.CoreCommandListProfiles>(
        profilesReply([headProfile(localRootRefusal: 'no access')]),
      );

      await controller.refreshProfiles();

      expect(
        controller.state.profiles.single.breakage,
        isA<ProfileLocalRootUnusable>(),
      );
    });

    test('rethrows a refusal', () async {
      core.reply<wire.CoreCommandListProfiles>(failed('profiles unreadable'));

      await expectLater(
        controller.refreshProfiles(),
        throwsA(isA<CoreFailure>()),
      );
    });

    test('a save sends the draft, and the list the core answers lands on '
        'the rows at once', () async {
      core.reply<wire.CoreCommandSaveProfile>(
        profilesReply([headProfile(name: 'weekly')]),
      );

      await controller.saveProfile(
        'weekly',
        const ProfileDraft(
          localRoot: '/sdcard/Notes',
          peerDeviceId: 'aaaa-bbbb-cccc-dddd',
          remoteRoot: '~/notes',
        ),
      );

      expect(core.sent<wire.CoreCommandSaveProfile>(), const [
        wire.CoreCommandSaveProfile(
          name: 'weekly',
          draft: wire.ProfileDraft(
            localRoot: '/sdcard/Notes',
            peerDeviceId: 'aaaa-bbbb-cccc-dddd',
            remoteRoot: '~/notes',
            jobs: null,
            ignore: [],
          ),
        ),
      ]);
      expect(controller.state.profiles.single.name, 'weekly');
    });

    test('a save replacing another name renames it first', () async {
      core.reply<wire.CoreCommandSaveProfile>(
        profilesReply([headProfile(name: 'new')]),
      );

      await controller.saveProfile(
        'new',
        const ProfileDraft(
          localRoot: '/sdcard/Notes',
          peerDeviceId: 'aaaa-bbbb-cccc-dddd',
          remoteRoot: '~/notes',
        ),
        replacing: 'old',
      );

      expect(core.commands, [
        const wire.CoreCommandRenameProfile(from: 'old', to: 'new'),
        isA<wire.CoreCommandSaveProfile>().having((c) => c.name, 'name', 'new'),
      ]);
      expect(controller.state.profiles.map((p) => p.name), ['new']);
    });

    test('relocate keeps the rest of the profile', () async {
      core.reply<wire.CoreCommandListProfiles>(
        profilesReply([
          headProfile(name: 'weekly', ignorePatterns: ['**/.git'], jobs: 3),
        ]),
      );

      final failure = await controller.relocateProfile(
        'weekly',
        localRootPath: '/sdcard/Moved',
      );

      expect(failure, isNull);
      expect(core.sent<wire.CoreCommandSaveProfile>(), const [
        wire.CoreCommandSaveProfile(
          name: 'weekly',
          draft: wire.ProfileDraft(
            localRoot: '/sdcard/Moved',
            peerDeviceId: 'aaaa-bbbb-cccc-dddd',
            remoteRoot: '~/notes',
            jobs: 3,
            ignore: ['**/.git'],
          ),
        ),
      ]);
    });

    test('relocating a profile that is gone is a message', () async {
      final failure = await controller.relocateProfile(
        'gone',
        localRootPath: '/sdcard/Moved',
      );

      expect(failure, contains('gone'));
      expect(core.sent<wire.CoreCommandSaveProfile>(), isEmpty);
    });

    test('delete sends the name, and the list the core answers is the '
        'rows', () async {
      core.reply<wire.CoreCommandDeleteProfile>(
        profilesReply([headProfile(name: 'b')]),
      );

      expect(await controller.deleteProfile('a'), isNull);
      expect(core.sent<wire.CoreCommandDeleteProfile>(), const [
        wire.CoreCommandDeleteProfile(name: 'a'),
      ]);

      // Positive control: 'b' still on the list, so an empty list — a
      // broken query — could not pass this.
      expect(controller.state.profiles.map((p) => p.name), ['b']);
    });

    test(
      'a refused delete renders the core\'s message, not an exception',
      () async {
        core
          ..reply<wire.CoreCommandListProfiles>(
            profilesReply([headProfile(name: 'weekly')]),
          )
          ..reply<wire.CoreCommandDeleteProfile>(
            failed('no profile named "gone"'),
          );

        final failure = await controller.deleteProfile('gone');

        expect(failure, 'no profile named "gone"');
        expect(controller.state.profiles.map((p) => p.name), ['weekly']);
      },
    );
  });
}
