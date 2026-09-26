import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/archive_row.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/features/archives/archives_controller.dart';
import 'package:dsync/app/features/archives/archives_view_state.dart';
import 'package:dsync/app/format_path.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// [ArchivesController] over a [FakeHub]: the controller's job is to
/// join what the core lists with the saved runs the home list holds, and to
/// render the core's answer to a delete — the disk half is the core's.
void main() {
  late FakeHub core;
  late AppController app;
  late ArchivesController controller;

  setUp(() {
    core = FakeHub();
    app = fakeApp(core);
    controller = ArchivesController(app);
  });

  tearDown(() => controller.dispose());

  String log(String profileId, [ReplicaSide side = ReplicaSide.a]) {
    final info = archiveInfo(profileId: profileId, side: side);
    core.archives.add(info);
    return info.logPath;
  }

  ProfileRow profile(String id, String name, {String? peerName = 'desktop'}) =>
      ProfileRow(
        name: name,
        profileId: id,
        peerDeviceId: 'a1b2:c3d4',
        peerName: peerName,
        localRootPath: '/on-device/notes',
        remoteRootPath: '~/notes',
        localRootLabel: PathLabel.of('/on-device/notes'),
        remoteRootLabel: PathLabel.of('~/notes'),
        breakage: null,
        lastRunUnfinished: false,
      );

  List<ArchiveRow> rows() => (controller.state.listing as ArchivesReady).rows;

  List<String> titles() => [for (final row in rows()) row.title];

  const busy = 'A sync run is using this history right now.';

  test('an archive is named after the saved run that wrote it', () async {
    log('p1');
    app.state.recordProfiles([profile('p1', 'weekly notes')]);

    await controller.refresh();

    expect(titles(), ['weekly notes']);
    expect(rows().single.note, isNull);
  });

  test('an archive names the device its run syncs with', () async {
    log('p1');
    app.state.recordProfiles([profile('p1', 'weekly notes')]);

    await controller.refresh();

    expect(rows().single.peerLine, 'syncs with desktop');
  });

  test('a run whose device was revoked keeps the id as its peer', () async {
    log('p1');
    app.state.recordProfiles([profile('p1', 'weekly notes', peerName: null)]);

    await controller.refresh();

    expect(rows().single.peerLine, 'syncs with unpaired device a1b2:c3d4');
  });

  test('an archive no saved run points at has no device to name', () async {
    log('p9');
    app.state.recordProfiles(const []);

    await controller.refresh();

    expect(rows().single.peerLine, isNull);
  });

  test('an archive no saved run points at says so', () async {
    log('p9');
    app.state.recordProfiles(const []);

    await controller.refresh();

    expect(titles(), ['p9']);
    expect(rows().single.note, contains('No saved run'));
  });

  test('a device that has never synced reads as an empty list', () async {
    await controller.refresh();

    expect(controller.state.listing, isA<ArchivesReady>());
    expect(rows(), isEmpty);
  });

  test('a listing the core cannot read is the failure it names', () async {
    core.failNext = const CoreFailure('state dir unreadable');

    await controller.refresh();

    expect(
      controller.state.listing,
      isA<ArchivesFailed>().having(
        (f) => f.message,
        'message',
        'state dir unreadable',
      ),
    );
  });

  test('the total is what the logs cost together', () async {
    log('p1');
    log('p2');

    await controller.refresh();

    expect((controller.state.listing as ArchivesReady).totalBytes, 2 * 2048);
  });

  test('deleting one clears its history and re-renders the rest', () async {
    final gone = log('p1');
    log('p2');
    await controller.refresh();

    await controller.delete(gone);

    expect(core.calls, contains('clearArchive'));
    expect(titles(), ['p2']);
    expect(controller.state.error, isNull);
  });

  test('deleting one side clears both sides of its history', () async {
    // The core clears per archive id, both sides as one decision.
    final a = log('p1', ReplicaSide.a);
    log('p1', ReplicaSide.b);
    log('p2');
    await controller.refresh();

    await controller.delete(a);

    expect(titles(), ['p2']);
  });

  test(
    'deleting everything leaves the device as if it had never synced',
    () async {
      log('p1', ReplicaSide.a);
      log('p1', ReplicaSide.b);
      log('p2');
      await controller.refresh();

      await controller.deleteAll();

      expect(rows(), isEmpty);
      expect(core.archives, isEmpty);
    },
  );

  test('a run keeps its history from being deleted', () async {
    final held = log('p1');
    await controller.refresh();
    core.archiveRefusals['p1'] = busy;

    await controller.delete(held);

    expect(controller.state.error, busy);
    expect(titles(), ['p1']);
  });

  test('deleting all stops at a log a run is using', () async {
    log('p1');
    log('p2');
    await controller.refresh();
    core.archiveRefusals['p1'] = busy;

    await controller.deleteAll();

    // The locked one survived and the user was told — not left with a
    // shorter list and no idea what was kept.
    expect(controller.state.error, busy);
    expect(titles(), contains('p1'));
  });

  test('deleting the ticked ones leaves the rest alone', () async {
    final gone = log('p1');
    log('p2');
    final alsoGone = log('p3');
    await controller.refresh();

    controller.toggleSelection(gone);
    controller.toggleSelection(alsoGone);
    await controller.deleteSelected();

    expect(titles(), ['p2']);
    expect(controller.state.error, isNull);
    // Everything ticked is gone, so the page is out of selection mode with
    // no second thing to clear.
    expect(controller.state.isSelecting, isFalse);
  });

  test(
    'a ticked log a run is using stops the delete and stays ticked',
    () async {
      // Listed first, so the delete reaches it before the held one.
      final other = log('p2');
      final held = log('p1');
      await controller.refresh();
      core.archiveRefusals['p1'] = busy;

      controller.toggleSelection(held);
      controller.toggleSelection(other);
      await controller.deleteSelected();

      expect(controller.state.error, busy);
      // What is still ticked is exactly what was not deleted: trying again
      // after the run ends is the same button.
      expect(controller.state.selected, {held});
    },
  );

  test('unticking the last row leaves selection mode', () async {
    final path = log('p1');
    await controller.refresh();

    controller.toggleSelection(path);
    expect(controller.state.isSelecting, isTrue);
    controller.toggleSelection(path);

    expect(controller.state.isSelecting, isFalse);
  });

  test('a row deleted from under a tick drops the tick', () async {
    final path = log('p1');
    await controller.refresh();
    controller.toggleSelection(path);

    core.archives.clear();
    await controller.refresh();

    expect(controller.state.selected, isEmpty);
  });

  test(
    'deleting the ticked ones before the list is read does nothing',
    () async {
      log('p1');

      await controller.deleteSelected();

      expect(core.calls, isNot(contains('clearArchive')));
      expect(rows(), hasLength(1));
    },
  );

  test('deleting all before the list is read does nothing', () async {
    log('p1');

    await controller.deleteAll();

    // The listing was `ArchivesLoading`, so there was nothing to delete —
    // and the refresh that follows finds the log still there.
    expect(core.calls, isNot(contains('clearArchive')));
    expect(rows(), hasLength(1));
  });
}
