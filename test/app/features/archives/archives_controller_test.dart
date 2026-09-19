import 'dart:convert';
import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/archive_row.dart';
import 'package:dsync/app/features/archives/archives_controller.dart';
import 'package:dsync/app/features/archives/archives_view_state.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:flutter_test/flutter_test.dart';

/// [ArchivesController] over a real state directory: the controller's job is
/// to join what is on disk with the saved runs the home list holds, so the
/// disk half is real files in a temp directory and the other half is rows
/// written into `AppState`.
void main() {
  late Directory tempDir;
  late AppController app;
  late ArchivesController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dsync_archives_ctrl_');
    await Directory('${tempDir.path}/dsync').create(recursive: true);
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
    controller = ArchivesController(app);
  });

  tearDown(() async {
    controller.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<File> writeLog(
    String profileId,
    String side, {
    String rootPath = '/on-device/notes',
  }) async {
    final file = File('${tempDir.path}/dsync/$profileId-$side.jsonl');
    await file.writeAsString(
      '${jsonEncode({'op': 'header', 'schemaVersion': 2, 'profileId': profileId, 'rootPath': rootPath})}\n',
    );
    return file;
  }

  ProfileRow profile(String id, String name) => ProfileRow(
    id: id,
    name: name,
    peerDeviceId: 'a1b2:c3d4',
    peerName: 'desktop',
    localRootPath: '/on-device/notes',
    remoteRootPath: '~/notes',
    breakage: null,
  );

  List<ArchiveRow> rows() => (controller.state.listing as ArchivesReady).rows;

  List<String> titles() => [for (final row in rows()) row.title];

  test('an archive is named after the saved run that wrote it', () async {
    await writeLog('p1', 'a');
    app.state.recordProfiles([profile('p1', 'weekly notes')]);

    await controller.refresh();

    expect(titles(), ['weekly notes']);
    expect(rows().single.note, isNull);
  });

  test('an archive no saved run points at says so', () async {
    await writeLog('p9', 'a');
    app.state.recordProfiles(const []);

    await controller.refresh();

    expect(titles(), ['p9']);
    expect(rows().single.note, contains('No saved run'));
  });

  test('a device that has never synced reads as an empty list', () async {
    await controller.refresh();

    expect(controller.state.listing, isA<ArchivesReady>());
    expect((controller.state.listing as ArchivesReady).rows, isEmpty);
  });

  test('the total is what the logs cost together', () async {
    final one = await writeLog('p1', 'a');
    final two = await writeLog('p2', 'a');

    await controller.refresh();

    expect(
      (controller.state.listing as ArchivesReady).totalBytes,
      await one.length() + await two.length(),
    );
  });

  test('deleting one removes its log and re-renders the rest', () async {
    final gone = await writeLog('p1', 'a');
    await writeLog('p2', 'a');
    await controller.refresh();

    await controller.delete(gone.path);

    expect(await gone.exists(), isFalse);
    expect(titles(), ['p2']);
    expect(controller.state.error, isNull);
  });

  test(
    'deleting everything leaves the device as if it had never synced',
    () async {
      await writeLog('p1', 'a');
      await writeLog('p1', 'b');
      await writeLog('p2', 'a');
      await controller.refresh();

      await controller.deleteAll();

      expect((controller.state.listing as ArchivesReady).rows, isEmpty);
      // No log left at all. The empty `.lock` files each delete took its
      // guard on are not archives and are left behind on purpose — see
      // `ArchiveInventory.delete`.
      expect([
        for (final e in await Directory(
          '${tempDir.path}/dsync',
        ).list().toList())
          if (e.path.endsWith('.jsonl')) e.path,
      ], isEmpty);
    },
  );

  test('a run in this app keeps its history from being deleted', () async {
    final log = await writeLog('p1', 'a');
    await controller.refresh();
    // The lock `LocalAgent.lock()` holds for the length of a run — taken
    // here in this process, exactly as the head's own Run page takes it.
    final run = ReplicaLock(File('${tempDir.path}/dsync/p1-a.lock'));
    await run.acquire();
    addTearDown(run.release);

    await controller.delete(log.path);

    expect(await log.exists(), isTrue);
    expect(controller.state.error, contains('Wait for it to finish'));
    expect(titles(), ['p1']);
  });

  test('deleting all stops at a log a run is using', () async {
    final held = await writeLog('p1', 'a');
    await writeLog('p2', 'a');
    await controller.refresh();
    final run = ReplicaLock(File('${tempDir.path}/dsync/p1-a.lock'));
    await run.acquire();
    addTearDown(run.release);

    await controller.deleteAll();

    // Whichever it reached first, the locked one survived and the user was
    // told — not left with a shorter list and no idea what was kept.
    expect(await held.exists(), isTrue);
    expect(controller.state.error, isNotNull);
    expect(titles(), contains('p1'));
  });

  test('deleting all before the list is read does nothing', () async {
    await writeLog('p1', 'a');

    await controller.deleteAll();

    // The listing was `ArchivesLoading`, so there was nothing to delete —
    // and the refresh that follows finds the log still there.
    expect((controller.state.listing as ArchivesReady).rows, hasLength(1));
  });
}
