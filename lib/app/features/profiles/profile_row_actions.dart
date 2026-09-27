import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../profile_breakage.dart';
import '../../profile_row.dart';
import '../../row_action.dart';

/// A saved run's actions, in menu order — what the row's buttons offer
/// ([RowAction] states the rule):
///
/// - "Run again", while the last run did not finish, as the row's button;
/// - the breakage's remedy, as the row's button: "Choose folder" or
///   "Pair again";
/// - a copy of each path the row draws, headed as the row heads it ("path
///   on this device", "path on Laptop"), numbered when the row draws two
///   entries;
/// - "Delete profile", last and destructive, with Delete as its key — the
///   row's delete icon, behind the same confirmation ([onDelete]).
///
/// The row's tap (Run setup) is not repeated: it is the row itself, and a
/// broken row has none.
List<RowAction> profileRowActions(
  ProfileRow row, {
  required VoidCallback onRunAgain,
  required void Function(int entryIndex) onPickFolder,
  required VoidCallback onPairAgain,
  required VoidCallback onDelete,
}) {
  final shown = profileEntriesShown(row.entries);
  final peer = profilePeerLabel(row);
  return [
    if (row.lastRunUnfinished)
      RowCommand(
        label: 'Run again',
        icon: Icons.replay,
        destructive: false,
        shortcut: null,
        onSelected: onRunAgain,
      ),
    ...switch (row.breakage) {
      ProfileLocalRootUnusable(:final entryIndex) => [
        RowCommand(
          label: 'Choose folder',
          icon: Icons.folder_open,
          destructive: false,
          shortcut: null,
          onSelected: () => onPickFolder(entryIndex),
        ),
      ],
      ProfileDeviceUnpaired() => [
        RowCommand(
          label: 'Pair again',
          icon: Icons.link,
          destructive: false,
          shortcut: null,
          onSelected: onPairAgain,
        ),
      ],
      null => const <RowAction>[],
    },
    for (final (index, entry) in shown.indexed) ...[
      RowCopy(
        value: entry.localRootPath,
        what: _pathOn('this device', index: index, of: shown.length),
      ),
      RowCopy(
        value: entry.remoteRootPath,
        what: _pathOn(peer, index: index, of: shown.length),
      ),
    ],
    RowCommand(
      label: 'Delete profile',
      icon: Icons.delete_outline,
      destructive: true,
      shortcut: const SingleActivator(LogicalKeyboardKey.delete),
      onSelected: onDelete,
    ),
  ];
}

/// "path on Laptop", or "path 2 on Laptop" among two drawn entries.
String _pathOn(String side, {required int index, required int of}) =>
    of == 1 ? 'path on $side' : 'path ${index + 1} on $side';

/// The entries a row draws in full: the first two, so a long profile still
/// fits on a row sized for one — and so its menu copies what is on screen.
List<ProfileEntryRow> profileEntriesShown(List<ProfileEntryRow> entries) =>
    entries.length <= 2 ? entries : entries.sublist(0, 2);

/// The peer as the row names its side: its name here, or — once revoked, when
/// this host keeps only an id — "unpaired device" and that id.
String profilePeerLabel(ProfileRow row) =>
    row.peerName ?? 'unpaired device ${row.peerDeviceId}';
