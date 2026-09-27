import 'package:dsync/app/core_link/models/root_kind.dart';
import 'package:dsync/app/features/profiles/profile_row_actions.dart';
import 'package:dsync/app/profile_breakage.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/row_actions.dart';

/// [profileRowActions] over plain rows: which of the row's buttons a menu
/// repeats, which paths it copies, and that delete comes last.
void main() {
  final calls = <String>[];

  setUp(calls.clear);

  ProfileEntryRow entry(String local, String remote) => ProfileEntryRow(
    entryId: local,
    kind: RootKind.folder,
    localRootPath: local,
    remoteRootPath: remote,
    localRootRefusal: null,
  );

  ProfileRow row({
    String? peerName = 'desktop',
    List<ProfileEntryRow>? entries,
    ProfileBreakage? breakage,
    bool lastRunUnfinished = false,
  }) => ProfileRow(
    name: 'weekly',
    peerDeviceId: 'a1b2:c3d4',
    peerName: peerName,
    entries: entries ?? [entry('/on-device/notes', '~/notes')],
    breakage: breakage,
    lastRunUnfinished: lastRunUnfinished,
  );

  List<String> actionsOf(ProfileRow row) => describeActions(
    profileRowActions(
      row,
      onRunAgain: () => calls.add('run again'),
      onPickFolder: (index) => calls.add('pick $index'),
      onPairAgain: () => calls.add('pair again'),
      onDelete: () => calls.add('delete'),
    ),
  );

  test('a healthy row copies its two paths and deletes, with Delete bound', () {
    expect(actionsOf(row()), [
      'Copy path on this device = /on-device/notes',
      'Copy path on desktop = ~/notes',
      'Delete profile [Delete] !',
    ]);
  });

  test('an unfinished run offers to run again first', () {
    expect(actionsOf(row(lastRunUnfinished: true)).first, 'Run again');
  });

  test('a breakage offers its remedy, aimed where the row aims it', () {
    final lost = row(breakage: const ProfileLocalRootUnusable(1));
    final actions = profileRowActions(
      lost,
      onRunAgain: () => calls.add('run again'),
      onPickFolder: (index) => calls.add('pick $index'),
      onPairAgain: () => calls.add('pair again'),
      onDelete: () => calls.add('delete'),
    );
    expect(describeActions(actions).first, 'Choose folder');
    choose(actions, 'Choose folder');
    expect(calls, ['pick 1']);

    expect(
      actionsOf(row(breakage: const ProfileDeviceUnpaired())).first,
      'Pair again',
    );
  });

  test('a revoked peer is named by id, as its heading names it', () {
    expect(
      actionsOf(row(peerName: null)),
      contains('Copy path on unpaired device a1b2:c3d4 = ~/notes'),
    );
  });

  test('two drawn entries are numbered, and a third, not drawn, is not '
      'copied', () {
    final many = row(
      entries: [entry('/a', '~/a'), entry('/b', '~/b'), entry('/c', '~/c')],
    );
    expect(actionsOf(many), [
      'Copy path 1 on this device = /a',
      'Copy path 1 on desktop = ~/a',
      'Copy path 2 on this device = /b',
      'Copy path 2 on desktop = ~/b',
      'Delete profile [Delete] !',
    ]);
  });

  test('delete is the row\'s delete', () {
    final actions = profileRowActions(
      row(),
      onRunAgain: () => calls.add('run again'),
      onPickFolder: (index) => calls.add('pick $index'),
      onPairAgain: () => calls.add('pair again'),
      onDelete: () => calls.add('delete'),
    );
    choose(actions, 'Delete profile');
    expect(calls, ['delete']);
  });
}
