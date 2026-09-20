import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/archive_row.dart';
import 'package:dsync/app/features/archives/archives_controller.dart';
import 'package:dsync/app/features/archives/archives_page.dart';
import 'package:dsync/app/features/archives/archives_scope.dart';
import 'package:dsync/app/features/archives/archives_view_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rendering tests for the Archives page, driven the way the scope contract
/// in `app_scope.dart` intends: the controller is pinned with
/// `setController` and the page is pumped directly. The listing is written
/// straight onto the view state — nothing here touches the filesystem,
/// because the page renders values, not archives.
void main() {
  late AppController app;
  late _RecordingArchivesController controller;

  setUp(() {
    app = AppController(
      () async => AppPaths(Directory.systemTemp.path),
      now: DateTime.now,
    );
    controller = _RecordingArchivesController(app);
    appScope.setController(app);
    archivesScope.setController(controller);
  });

  tearDown(appScope.reset);
  tearDown(archivesScope.reset);
  tearDown(() => controller.dispose());

  ArchiveRow row(String title, {String? note, String? peerLine}) => ArchiveRow(
    logPath: '/state/dsync/$title-a.jsonl',
    title: title,
    peerLine: peerLine,
    location: '/on-device/notes',
    sizeLabel: '4.2 MiB',
    sizeBytes: 4404019,
    lastWritten: '2026-09-15',
    note: note,
  );

  Future<void> pumpPage(WidgetTester tester) =>
      tester.pumpWidget(const MaterialApp(home: ArchivesPage()));

  testWidgets('mounting asks for the listing', (tester) async {
    await pumpPage(tester);

    expect(controller.refreshes, 1);
  });

  testWidgets('a list still being read shows neither rows nor an empty state', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.text(
        'No sync history stored. The next run over any folder '
        'starts from scratch.',
      ),
      findsNothing,
    );
  });

  testWidgets('every archive is a row with what it costs', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('weekly notes')]));
    await tester.pump();

    expect(find.text('weekly notes'), findsOneWidget);
    expect(find.text('/on-device/notes'), findsOneWidget);
    expect(find.text('4.2 MiB · last written 2026-09-15'), findsOneWidget);
  });

  testWidgets('the total is shown above the rows', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('one'), row('two')]));
    await tester.pump();

    expect(find.byKey(const Key('archives-total')), findsOneWidget);
    expect(find.text('8.4 MiB'), findsOneWidget);
    expect(find.text('across 2 stored histories'), findsOneWidget);
  });

  testWidgets('a row names the device its run syncs with, under the run', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(
      ArchivesReady([row('weekly notes', peerLine: 'syncs with desktop')]),
    );
    await tester.pump();

    expect(find.text('syncs with desktop'), findsOneWidget);
    final title = tester.getTopLeft(find.text('weekly notes')).dy;
    final peer = tester.getTopLeft(find.text('syncs with desktop')).dy;
    final size = tester
        .getTopLeft(find.text('4.2 MiB · last written 2026-09-15'))
        .dy;
    expect(title, lessThan(peer));
    expect(peer, lessThan(size));
  });

  testWidgets('a run whose device was revoked reads as an unpaired id', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(
      ArchivesReady([
        row('weekly notes', peerLine: 'syncs with unpaired device a1b2:c3d4'),
      ]),
    );
    await tester.pump();

    expect(find.text('syncs with unpaired device a1b2:c3d4'), findsOneWidget);
  });

  testWidgets('an archive no saved run points at names no device', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(
      ArchivesReady([
        row('p9', note: 'No saved run uses this history any more.'),
      ]),
    );
    await tester.pump();

    // No run, so no device: the remark is the whole of what is known.
    expect(find.textContaining('syncs with'), findsNothing);
    expect(
      find.text('No saved run uses this history any more.'),
      findsOneWidget,
    );
  });

  testWidgets('an archive no saved run points at carries its remark', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(
      ArchivesReady([
        row(
          'p9',
          note:
              'No saved run uses this history any '
              'more.',
        ),
      ]),
    );
    await tester.pump();

    expect(
      find.text('No saved run uses this history any more.'),
      findsOneWidget,
    );
  });

  testWidgets('an empty list says the next run starts from scratch', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(const ArchivesReady([]));
    await tester.pump();

    expect(find.textContaining('No sync history stored'), findsOneWidget);
    // Nothing to delete, so nothing offers to.
    expect(find.byKey(const Key('archives-delete-all')), findsNothing);
  });

  testWidgets('a read that failed shows its message', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(
      const ArchivesFailed('PathAccessException: /state/dsync'),
    );
    await tester.pump();

    expect(find.textContaining('PathAccessException'), findsOneWidget);
  });

  testWidgets('deleting one asks first, then deletes by log path', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('weekly notes')]));
    await tester.pump();

    await tester.tap(
      find.byKey(const Key('archive-delete-/state/dsync/weekly notes-a.jsonl')),
    );
    await tester.pumpAndSettle();
    expect(controller.deleted, isEmpty, reason: 'the dialog comes first');
    expect(
      find.textContaining('does not touch any of your files'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('archives-confirm-delete')));
    await tester.pumpAndSettle();

    expect(controller.deleted, ['/state/dsync/weekly notes-a.jsonl']);
  });

  testWidgets('cancelling the dialog deletes nothing', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('weekly notes')]));
    await tester.pump();

    await tester.tap(
      find.byKey(const Key('archive-delete-/state/dsync/weekly notes-a.jsonl')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(controller.deleted, isEmpty);
  });

  testWidgets('deleting all asks first, then deletes all', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('one'), row('two')]));
    await tester.pump();

    await tester.tap(find.byKey(const Key('archives-delete-all')));
    await tester.pumpAndSettle();
    expect(find.text('Delete all 2 histories?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('archives-confirm-delete-all')));
    await tester.pumpAndSettle();

    expect(controller.deletedAll, 1);
  });

  testWidgets('a refused delete is shown above the list it left alone', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('weekly notes')]));
    controller.state.recordError('A sync run is using this history right now.');
    await tester.pump();

    expect(find.byKey(const Key('archives-notice')), findsOneWidget);
    expect(find.text('weekly notes'), findsOneWidget);
  });
}

/// Records the inputs the page sends instead of touching the filesystem.
/// [refresh] is overridden to a no-op so a mounted page does not read a real
/// state directory — what is asserted is that it asked.
class _RecordingArchivesController extends ArchivesController {
  _RecordingArchivesController(super.app);

  int refreshes = 0;
  int deletedAll = 0;
  final List<String> deleted = [];

  @override
  Future<void> refresh() async => refreshes++;

  @override
  Future<void> delete(String logPath) async => deleted.add(logPath);

  @override
  Future<void> deleteAll() async => deletedAll++;
}
