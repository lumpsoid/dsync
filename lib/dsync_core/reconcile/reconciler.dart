import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';

/// Turns two replicas' status lists into a [Plan] (SPEC §6).
///
/// Pure: no filesystem access, no I/O, no archive lookups of its own. Each
/// side has already compared itself against its own archive (SPEC §5); this
/// only ever sees the two resulting status lists.
class Reconciler {
  Plan reconcile(List<ScanEntry> onA, List<ScanEntry> onB) {
    final a = {for (final e in onA) e.path: e};
    final b = {for (final e in onB) e.path: e};
    final filesOnA = _presentPaths(a.values);
    final filesOnB = _presentPaths(b.values);
    final dirsOnA = _impliedDirs(filesOnA);
    final dirsOnB = _impliedDirs(filesOnB);

    final actions = <PlanAction>[];
    final conflicts = <Conflict>[];

    for (final path in {...a.keys, ...b.keys}.toList()..sort()) {
      // A path beneath one that's a file on the other side is covered by
      // that ancestor's own type-mismatch conflict below — nothing more to
      // resolve about it until that conflict is settled.
      if (_hasAncestorIn(path, filesOnA) || _hasAncestorIn(path, filesOnB)) {
        continue;
      }

      final entryA = a[path];
      final entryB = b[path];

      // A file on one side and a directory (real files beneath it) on the
      // other can never be reconciled automatically (SPEC §6).
      if (_isFileVsDir(entryA, dirsOnB) || _isFileVsDir(entryB, dirsOnA)) {
        conflicts.add(Conflict(path: path, onA: entryA, onB: entryB));
        continue;
      }

      _resolveCell(path, entryA, entryB, actions, conflicts);
    }

    return Plan(actions: actions, conflicts: conflicts);
  }
}

/// Resolves one path given its (possibly absent) entry on each side and
/// appends the outcome to [actions] or [conflicts].
///
/// A `null` entry means that side's scan has no record of the path at all —
/// it never had an archive entry and doesn't currently have the file. That
/// isn't in the SPEC §6 table, which assumes both sides always report a
/// status; it happens whenever a path is new to a replica that has never
/// seen it before (e.g. the first run over two pre-existing trees). Treated
/// as: mirror whatever the other side currently has, or do nothing if the
/// other side has since deleted it too.
void _resolveCell(
  String path,
  ScanEntry? entryA,
  ScanEntry? entryB,
  List<PlanAction> actions,
  List<Conflict> conflicts,
) {
  void act(ActionType type, {int bytes = 0}) =>
      actions.add(PlanAction(path: path, type: type, bytes: bytes));
  void conflict() =>
      conflicts.add(Conflict(path: path, onA: entryA, onB: entryB));

  if (entryA == null || entryB == null) {
    final present = entryA ?? entryB!;
    if (present.status == ScanStatus.deleted) return;
    act(
      entryA == null ? ActionType.copyBtoA : ActionType.copyAtoB,
      bytes: _transferBytes(present),
    );
    return;
  }

  switch ((entryA.status, entryB.status)) {
    case (ScanStatus.unchanged, ScanStatus.unchanged):
      return;
    case (ScanStatus.unchanged, ScanStatus.created) ||
        (ScanStatus.unchanged, ScanStatus.modified):
      entryA.hash == entryB.hash
          ? act(ActionType.commitOnly)
          : act(ActionType.copyBtoA, bytes: _transferBytes(entryB));
    case (ScanStatus.unchanged, ScanStatus.deleted):
      act(ActionType.deleteOnA);

    case (ScanStatus.created, ScanStatus.unchanged) ||
        (ScanStatus.modified, ScanStatus.unchanged):
      entryA.hash == entryB.hash
          ? act(ActionType.commitOnly)
          : act(ActionType.copyAtoB, bytes: _transferBytes(entryA));

    case (ScanStatus.created, ScanStatus.created) ||
        (ScanStatus.created, ScanStatus.modified) ||
        (ScanStatus.modified, ScanStatus.created) ||
        (ScanStatus.modified, ScanStatus.modified):
      entryA.hash == entryB.hash ? act(ActionType.commitOnly) : conflict();

    case (ScanStatus.created, ScanStatus.deleted) ||
        (ScanStatus.modified, ScanStatus.deleted):
      conflict();

    case (ScanStatus.deleted, ScanStatus.unchanged):
      act(ActionType.deleteOnB);
    case (ScanStatus.deleted, ScanStatus.created) ||
        (ScanStatus.deleted, ScanStatus.modified):
      conflict();
    case (ScanStatus.deleted, ScanStatus.deleted):
      act(ActionType.commitOnly);
  }
}

/// The bytes a copy from [source] moves (SPEC §10).
///
/// The table never copies from a side that no longer has the file, so a
/// source entry's size is always known; the fallback is only here because
/// [ScanEntry] represents a deleted path with nulls in those fields.
int _transferBytes(ScanEntry source) => source.size ?? 0;

/// Whether [entry] is a file currently present at a path that [otherSideDirs]
/// says is a directory on the other side.
bool _isFileVsDir(ScanEntry? entry, Set<String> otherSideDirs) {
  return entry != null &&
      entry.status != ScanStatus.deleted &&
      otherSideDirs.contains(entry.path);
}

/// Whether any ancestor segment of [path] is itself a currently-present file
/// in [files] — i.e. [path] lives beneath a path that's occupied by a file
/// rather than a directory.
bool _hasAncestorIn(String path, Set<String> files) {
  final segments = path.split('/');
  for (var i = 1; i < segments.length; i++) {
    if (files.contains(segments.sublist(0, i).join('/'))) return true;
  }
  return false;
}

/// Paths of entries that currently exist on disk (i.e. not tombstones).
Set<String> _presentPaths(Iterable<ScanEntry> entries) => {
  for (final e in entries)
    if (e.status != ScanStatus.deleted) e.path,
};

/// Every ancestor directory implied by [paths], e.g. `a/b/c.txt` implies `a`
/// and `a/b`.
Set<String> _impliedDirs(Set<String> paths) {
  final dirs = <String>{};
  for (final path in paths) {
    final segments = path.split('/');
    for (var i = 1; i < segments.length; i++) {
      dirs.add(segments.sublist(0, i).join('/'));
    }
  }
  return dirs;
}
