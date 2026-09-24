import 'package:dsync/app/core_link/fake_core_link.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/paired_device_info.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/core_link/models/profile_entry.dart';
import 'package:dsync/app/core_link/models/run_decision.dart';
import 'package:dsync/app/core_link/models/run_end.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/core_link/models/run_update.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fake the head's controller tests will run on: its state changes as
/// the core's does, and its sessions are the test's to drive.
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
    final link = FakeCoreLink(devices: [phone()]);
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
    expect(link.calls, [
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
      final link = FakeCoreLink(devices: [phone()]);
      link.folderRefusals['/gone'] = 'dsync cannot use /gone';
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

  test(
    'a run session is the test\'s to drive, and closes on its end',
    () async {
      final link = FakeCoreLink();
      final run = await link.startRun(
        const DraftTarget(
          ProfileDraft(localRoot: '/a', peerDeviceId: 'x', remoteRoot: '/b'),
        ),
        dryRun: false,
      );
      link.emitRun(
        run.session,
        const RunPlan(
          actions: [],
          conflicts: [],
          bytesToTransfer: 0,
          exceedsWarnSize: false,
          awaitingDecision: true,
        ),
      );
      await link.decideRun(run.session, RunDecision.acceptAll(0));
      link.emitRun(run.session, const RunEnded(RunStoppedConnecting()));
      final updates = await run.updates.toList();
      expect(updates, hasLength(2));
      expect(updates.last, isA<RunEnded>());
      expect(link.decisions[run.session], hasLength(1));
    },
  );

  test('failNext fails the next call only', () async {
    final link = FakeCoreLink()..failNext = const CoreFailure('refused');
    await expectLater(link.listDevices(), throwsA(isA<CoreFailure>()));
    expect(await link.listDevices(), isEmpty);
  });
}
