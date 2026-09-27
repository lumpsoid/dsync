import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/archive_row.dart';
import 'package:dsync/app/core_link/models/archive_info.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/features/archives/archives_controller.dart';
import 'package:dsync/app/features/archives/archives_view_state.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:dsync/app/core_link/models/root_kind.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
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

  /// What the core lists, as the test built it with [log].
  late List<ArchiveInfo> listed;

  setUp(() {
    listed = [];
    core = FakeHub();
    app = fakeApp(core);
    controller = ArchivesController(app);
  });

  tearDown(() => controller.dispose());

  /// Adds [entryId]'s log on [side] to what the core lists.
  String log(String entryId, [ReplicaSide side = ReplicaSide.a]) {
    final info = archiveInfo(entryId: entryId, side: side);
    listed.add(info);
    core.reply<wire.CoreCommandListArchives>(archivesReply([...listed]));
    return info.logPath;
  }

  /// The core's answer to a clear: the logs of [entryIds] still listed.
  wire.ReplyResult left(List<String> entryIds) => archivesReply([
    for (final info in listed)
      if (entryIds.contains(info.entryId)) info,
  ]);

  /// Each clear's answer, by the archive id it names.
  void answerClears(Map<String, wire.ReplyResult> byProfile) =>
      core.answer<wire.CoreCommandClearArchive>(
        (clear) => byProfile[clear.entryId]!,
      );

  List<String> cleared() => [
    for (final clear in core.sent<wire.CoreCommandClearArchive>())
      clear.entryId,
  ];

  ProfileEntryRow entry(String id) => ProfileEntryRow(
    entryId: id,
    kind: RootKind.folder,
    localRootPath: '/on-device/notes',
    remoteRootPath: '~/notes',
    localRootRefusal: null,
  );

  ProfileRow profile(
    String id,
    String name, {
    String? peerName = 'desktop',
    List<String> moreIds = const [],
  }) => ProfileRow(
    name: name,
    peerDeviceId: 'a1b2:c3d4',
    peerName: peerName,
    entries: [entry(id), for (final more in moreIds) entry(more)],
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

  test('every entry\'s archives are named after the one saved run', () async {
    log('p1');
    log('p2');
    log('p3');
    app.state.recordProfiles([
      profile('p1', 'weekly notes', moreIds: ['p2']),
    ]);

    await controller.refresh();

    // The third id belongs to no saved run: the join is by id, not a
    // blanket match.
    expect(titles(), ['weekly notes', 'weekly notes', 'p3']);
  });

  test(
    'clearing a two-entry run\'s archives clears each entry id once',
    () async {
      log('p1');
      log('p1', ReplicaSide.b);
      log('p2');
      app.state.recordProfiles([
        profile('p1', 'weekly notes', moreIds: ['p2']),
      ]);
      await controller.refresh();
      answerClears({
        'p1': left(['p2']),
        'p2': left(const []),
      });

      await controller.deleteAll();

      expect(cleared(), ['p1', 'p2']);
      expect(rows(), isEmpty);
    },
  );

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
    core.reply<wire.CoreCommandListArchives>(failed('state dir unreadable'));

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
    core.reply<wire.CoreCommandClearArchive>(left(['p2']));

    await controller.delete(gone);

    expect(cleared(), ['p1']);
    expect(titles(), ['p2']);
    expect(controller.state.error, isNull);
  });

  test('deleting one side clears both sides of its history', () async {
    // The core clears per archive id, both sides as one decision.
    final a = log('p1', ReplicaSide.a);
    log('p1', ReplicaSide.b);
    log('p2');
    await controller.refresh();
    core.reply<wire.CoreCommandClearArchive>(left(['p2']));

    await controller.delete(a);

    expect(cleared(), ['p1']);
    expect(titles(), ['p2']);
  });

  test(
    'deleting everything leaves the device as if it had never synced',
    () async {
      log('p1', ReplicaSide.a);
      log('p1', ReplicaSide.b);
      log('p2');
      await controller.refresh();
      answerClears({
        'p1': left(['p2']),
        'p2': left([]),
      });

      await controller.deleteAll();

      expect(cleared(), ['p1', 'p2']);
      expect(rows(), isEmpty);
    },
  );

  test('a run keeps its history from being deleted', () async {
    final held = log('p1');
    await controller.refresh();
    core.reply<wire.CoreCommandClearArchive>(failed(busy));

    await controller.delete(held);

    expect(controller.state.error, busy);
    expect(titles(), ['p1']);
  });

  test('deleting all stops at a log a run is using', () async {
    log('p1');
    log('p2');
    await controller.refresh();
    answerClears({
      'p1': failed(busy),
      'p2': left(['p1']),
    });

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
    answerClears({
      'p1': left(['p2', 'p3']),
      'p3': left(['p2']),
    });

    controller.toggleSelection(gone);
    controller.toggleSelection(alsoGone);
    await controller.deleteSelected();

    expect(cleared(), ['p1', 'p3']);
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
      answerClears({
        'p2': left(['p1']),
        'p1': failed(busy),
      });
      // The listing read after the refusal: p2 went before it.
      core.reply<wire.CoreCommandListArchives>(left(['p1']));

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

  test('a range and select all run over the list in its order', () async {
    final first = log('p1');
    log('p2');
    final third = log('p3');
    await controller.refresh();

    controller.toggleSelection(first);
    controller.selectRange(from: null, to: third);
    expect(controller.state.selected, hasLength(3));

    controller.clearSelection();
    expect(controller.state.isSelecting, isFalse);

    controller.selectAll();
    expect(controller.state.selected, hasLength(3));
  });

  test('Up and Down step through the rows and stop at the ends', () async {
    final first = log('p1');
    final second = log('p2');
    await controller.refresh();

    expect(controller.rowBeside(null, 1), first);
    expect(controller.rowBeside(null, -1), second);
    expect(controller.rowBeside(first, 1), second);
    expect(controller.rowBeside(second, 1), isNull);
    expect(controller.rowBeside(first, -1), isNull);
  });

  test('select all before the list is read ticks nothing', () async {
    log('p1');

    controller.selectAll();

    expect(controller.state.isSelecting, isFalse);
  });

  test('a row deleted from under a tick drops the tick', () async {
    final path = log('p1');
    await controller.refresh();
    controller.toggleSelection(path);

    core.reply<wire.CoreCommandListArchives>(archivesReply(const []));
    await controller.refresh();

    expect(controller.state.selected, isEmpty);
  });

  test(
    'deleting the ticked ones before the list is read does nothing',
    () async {
      log('p1');

      await controller.deleteSelected();

      expect(cleared(), isEmpty);
      expect(rows(), hasLength(1));
    },
  );

  test('deleting all before the list is read does nothing', () async {
    log('p1');

    await controller.deleteAll();

    // The listing was `ArchivesLoading`, so there was nothing to delete —
    // and the refresh that follows finds the log still there.
    expect(cleared(), isEmpty);
    expect(rows(), hasLength(1));
  });
}
