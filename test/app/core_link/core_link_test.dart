import 'package:dsync/app/core_link/core_link.dart';
import 'package:dsync/app/core_link/models/action_choice.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/paired_device_info.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/core_link/models/profile_entry.dart';
import 'package:dsync/app/core_link/models/run_intent.dart';
import 'package:dsync/app/core_link/models/run_phase.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/core_link/models/run_view.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter_test/flutter_test.dart';

import '../features/run/run_fixtures.dart';
import '../support/fake_hub.dart';

/// The [CoreLink] the head's controller tests run on, over the fake hub:
/// the fake's state changes as the core's does, its sessions are the
/// test's to drive, and every answer is decoded by the link the app runs.
void main() {
  PairedDeviceInfo phone() => PairedDeviceInfo(
    deviceId: 'phone-id',
    name: 'phone',
    commonName: 'phone',
    grantedRoots: const [],
    address: '192.168.1.5:28771',
    pairedAt: DateTime.utc(2026),
    verifiedAt: null,
    issuedAt: DateTime.utc(2026),
    expiresAt: DateTime.utc(2036),
    expiryNote: null,
  );

  test('devices change as the core changes them, and an unknown one is '
      'refused', () async {
    final hub = FakeHub(devices: [phone()]);
    final link = CoreLink(hub);
    final renamed = await link.renameDevice('phone-id', 'pocket');
    expect(renamed.single.name, 'pocket');
    final granted = await link.grantRoot('phone-id', '/home/me/notes');
    expect(granted.single.grantedRoots, ['/home/me/notes']);
    final withdrawn = await link.withdrawGrant('phone-id', '/home/me/notes');
    expect(withdrawn.single.grantedRoots, isEmpty);
    await expectLater(
      link.revokeDevice('stranger'),
      throwsA(isA<CoreFailure>()),
    );
    expect(await link.revokeDevice('phone-id'), isEmpty);
    expect(hub.calls, [
      'renameDevice',
      'grantRoot',
      'withdrawGrant',
      'revokeDevice',
      'revokeDevice',
    ]);
  });

  test(
    'a saved profile names its peer and carries a set folder refusal',
    () async {
      final hub = FakeHub(devices: [phone()]);
      final link = CoreLink(hub);
      hub.folderRefusals['/gone'] = 'dsync cannot use /gone';
      final saved = await link.saveProfile(
        'Notes',
        const ProfileDraft(
          localRoot: '/gone',
          peerDeviceId: 'phone-id',
          remoteRoot: '/sdcard/notes',
        ),
      );
      final notes = saved.single as HeadProfile;
      expect(notes.peerName, 'phone');
      expect(notes.localRootRefusal, 'dsync cannot use /gone');
      expect((await link.renameProfile('Notes', 'Old')).single.name, 'Old');
      expect(await link.deleteProfile('Old'), isEmpty);
    },
  );

  test('a run session\'s views are the hub\'s snapshots, decoded, and '
      'its intents are sent as they are', () async {
    final hub = FakeHub();
    final link = CoreLink(hub);
    final run = await link.startRun(
      const DraftTarget(
        ProfileDraft(localRoot: '/a', peerDeviceId: 'x', remoteRoot: '/b'),
      ),
      dryRun: false,
    );
    final views = <RunView>[];
    final listening = run.views.listen(views.add);
    hub.emitRun(run.session, runView(phase: reviewing(apply: 2)));
    await link.steerRun(run.session, const ChooseAction(1, ActionChoice.skipped));
    await link.steerRun(run.session, const ConfirmReview());
    await Future<void>.delayed(Duration.zero);

    expect(views.single.phase, isA<RunReviewing>());
    expect((views.single.phase as RunReviewing).summary.apply, 2);
    expect(hub.runIntents[run.session], const [
      wire.RunIntentChooseAction(
        index: 1,
        choice: wire.ActionChoiceView.skipped,
      ),
      wire.RunIntentConfirm(),
    ]);

    // Once nobody listens, the session is forgotten: what arrives for it
    // is dropped.
    await listening.cancel();
    hub.emitRun(run.session, runView(phase: applying));
    await Future<void>.delayed(Duration.zero);
    expect(views, hasLength(1));
  });

  test('failNext fails the next call only', () async {
    final hub = FakeHub()..failNext = const CoreFailure('refused');
    final link = CoreLink(hub);
    await expectLater(link.listDevices(), throwsA(isA<CoreFailure>()));
    expect(await link.listDevices(), isEmpty);
  });

  test('init answers with the core\'s directories and records its '
      'arguments', () async {
    final hub = FakeHub();
    final link = CoreLink(hub);
    final dirs = await link.init(
      supportDir: '/data/files',
      deviceName: 'pixel',
    );
    expect(dirs.stateDir, '/fake/state');
    expect(dirs.profilesDir, '/fake/state/profiles');
    expect(hub.initialised, (supportDir: '/data/files', deviceName: 'pixel'));
  });

  test('an address, and a confirmation, are set and cleared on the '
      'device', () async {
    final hub = FakeHub(devices: [phone()])
      ..verifiedNow = DateTime.utc(2026, 7);
    final link = CoreLink(hub);
    final bare = await link.setDeviceAddress('phone-id', '10.0.0.9');
    expect(bare.single.address, '10.0.0.9:28771');
    final ported = await link.setDeviceAddress('phone-id', '10.0.0.9:4000');
    expect(ported.single.address, '10.0.0.9:4000');
    final verified = await link.verifyDevice('phone-id');
    expect(verified.single.verifiedAt?.toUtc(), DateTime.utc(2026, 7));
    final cleared = await link.clearVerification('phone-id');
    expect(cleared.single.verifiedAt, isNull);
    // Positive control for the clear: the rest of the device is unchanged.
    expect(cleared.single.address, '10.0.0.9:4000');
    await expectLater(
      link.verifyDevice('stranger'),
      throwsA(isA<CoreFailure>()),
    );
  });

  test('an ignore pattern is refused only when told to', () async {
    final hub = FakeHub();
    final link = CoreLink(hub);
    hub.patternRefusals['[bad'] = 'unclosed [';
    await link.checkIgnorePattern('**/*.tmp');
    await expectLater(
      link.checkIgnorePattern('[bad'),
      throwsA(
        isA<CoreFailure>().having((f) => f.message, 'message', 'unclosed ['),
      ),
    );
  });
}
