import 'dart:collection';

import 'package:dsync/dsync_core/models/plan.dart';

/// [actions] reordered so that consecutive ones sit in different parent
/// folders: one from each folder in turn, round-robin, the folders in the
/// order they first appear and each folder's own actions in their given order
/// (SPEC §7.2, task 5d8c28).
///
/// **Why.** The apply starts actions in the order it is handed them and keeps
/// up to `Applier.concurrency` in flight, so whatever is adjacent here is what
/// runs at the same time. On Android's shared storage, creates in one parent
/// folder serialise — the kernel holds the parent's lock across FUSE's round
/// trip to MediaProvider — and a plan sorted by path puts a folder's files
/// side by side. Measured on the OnePlus 6 with the real `LocalAgent.writeFile`
/// (1,500 fresh files, 30 a folder), path order held at ~15 ms a file from four
/// workers to sixteen; the same writes spread across folders took 5.4 ms at
/// four and 4.4 at sixteen, the storage's own floor.
///
/// **Every action, not only fresh copies**, because the rule then needs
/// nothing but paths and costs the rest nothing: an overwrite has no serial
/// part whatever its folder (SPEC §7.2's `write_ops_probe.c` table), a
/// commit-only touches no file, and nothing the apply guarantees depends on
/// start order (§7.1).
///
/// A tree that is mostly one folder gains nothing, and no order could give it
/// anything: once the smaller folders run out, what is left is that folder's
/// creates, which serialise.
List<PlanAction> spreadAcrossFolders(List<PlanAction> actions) {
  // A map literal keeps insertion order, which is what makes the folders take
  // their turns in the order the plan first reaches them.
  final byFolder = <String, Queue<PlanAction>>{};
  for (final action in actions) {
    byFolder.putIfAbsent(_folderOf(action.path), Queue.new).add(action);
  }
  final folders = byFolder.values.toList();
  final spread = <PlanAction>[];
  while (folders.isNotEmpty) {
    for (final folder in folders) {
      spread.add(folder.removeFirst());
    }
    folders.removeWhere((folder) => folder.isEmpty);
  }
  return spread;
}

/// The parent folder of a root-relative, `/`-joined [PlanAction.path] — `''`
/// for a file at the root.
String _folderOf(String path) {
  final lastSlash = path.lastIndexOf('/');
  return lastSlash == -1 ? '' : path.substring(0, lastSlash);
}
