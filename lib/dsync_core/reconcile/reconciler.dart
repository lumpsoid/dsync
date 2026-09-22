import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/unreadable_paths.dart';

/// Turns two replicas' status lists into a [Plan] (SPEC §6).
///
/// Pure: no filesystem access, no I/O, no archive lookups of its own. Each
/// side has already compared itself against its own archive (SPEC §5); this
/// only ever sees the two resulting status lists.
class Reconciler {
  /// [unreadable] is what neither list can express (SPEC §5, task 37bf4f): a
  /// path a scan could not read reports no entry, and §6 reads the resulting
  /// silence as "this side has never seen it" — a signal that means *mirror
  /// it from the other side*. That is the right reading for a path that
  /// genuinely is not there and the wrong one for a path that is, so the
  /// paths behind it are excluded here rather than left to resolve as
  /// something the scan never claimed. Without this, a locally-edited file
  /// the scan could not read would be overwritten by the other replica's
  /// copy — the run reporting "not synced" for a path it had just
  /// overwritten.
  ///
  /// Despite the name, also carries SPEC §16's case-fold collisions — see
  /// [UnreadablePaths]'s own doc comment for why it covers more than paths
  /// that were literally unreadable: a path that folds onto another on this
  /// replica is exactly as untrustworthy to mirror from the other side as
  /// one this scan simply could not read.
  ///
  /// Defaults to [UnreadablePaths.none], which asserts something true and
  /// ordinary — this scan read everything it walked — rather than standing in
  /// for a fact the caller failed to supply.
  Plan reconcile(
    List<ScanEntry> onA,
    List<ScanEntry> onB, {
    UnreadablePaths unreadable = UnreadablePaths.none,
  }) {
    final a = {for (final e in onA) e.path: e};
    final b = {for (final e in onB) e.path: e};
    final filesOnA = _presentPaths(a.values);
    final filesOnB = _presentPaths(b.values);
    final dirsOnA = _impliedDirs(filesOnA);
    final dirsOnB = _impliedDirs(filesOnB);

    final actions = <PlanAction>[];
    final conflicts = <Conflict>[];

    for (final path in {...a.keys, ...b.keys}.toList()..sort()) {
      // Neither this run nor the next can say anything true about a path a
      // scan could not read, so it gets no action and no conflict — a
      // conflict would ask the user to choose between a side's content and
      // something the tool never managed to look at.
      if (unreadable.covers(path)) continue;

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
/// no archive entry and no file. This case is covered by §6's "a path one
/// side has never seen" rule: mirror whatever the other side has, or — when
/// that side reports `deleted` — tombstone the side still recording it, so
/// the two archives converge instead of drifting forever (task 6a967f).
///
/// **That reading survives the scan exchange dropping entries** (SPEC §6.1,
/// task 97171c). A path the two sides proved equal by digest is absent from
/// *both* lists, so it never reaches here at all — a §6 cell of "nothing"
/// and an unvisited path are the same plan. What cannot happen is a path
/// present in one list and silently held, unchanged, by the other: the only
/// three ways a path enters a list are phase 1, the peer-changed entries
/// phase 2 subtracts, and a dirty bucket, and each of the three is symmetric
/// — the peer's changed path is subtracted on *this* side and returned, and a
/// dirty bucket is fetched from both sides. So silence here still means what
/// it has always meant.
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
    if (present.status == ScanStatus.untrusted) {
      _resolveUntrusted(
        untrusted: present,
        other: null,
        onA: entryA != null,
        act: act,
        conflict: conflict,
      );
      return;
    }
    if (present.status == ScanStatus.deleted) {
      // The other side is silent: no archive entry and no file. A replica
      // that still had the file on disk would report `created` even with a
      // wiped archive — it would never be silent. So silence here plus a
      // `deleted` entry there means the path is gone everywhere, and a
      // commit-only tombstones the side still recording it instead of
      // leaving the two archives to disagree forever (task 6a967f).
      act(ActionType.commitOnly);
      return;
    }
    act(
      entryA == null ? ActionType.copyBtoA : ActionType.copyAtoB,
      bytes: _transferBytes(present),
    );
    return;
  }

  switch ((entryA.status, entryB.status)) {
    // Neither side has content anyone can stand behind. Not reachable by
    // construction — a path is marked only on the side a copy writes to, and
    // a marked side is never a copy's source — so reaching it means the
    // archives were changed under the tool, and the user is who decides.
    case (ScanStatus.untrusted, ScanStatus.untrusted):
      conflict();
    case (ScanStatus.untrusted, _):
      _resolveUntrusted(
        untrusted: entryA,
        other: entryB,
        onA: true,
        act: act,
        conflict: conflict,
      );
    case (_, ScanStatus.untrusted):
      _resolveUntrusted(
        untrusted: entryB,
        other: entryA,
        onA: false,
        act: act,
        conflict: conflict,
      );

    case (ScanStatus.unchanged, ScanStatus.unchanged):
      // Same hash — the overwhelmingly normal case — is "nothing", exactly
      // as it always was. Different hashes is new (SPEC §6, task 97171c):
      // two archives that have silently diverged, each side in sync with its
      // own. Neither side changed, so there is no direction to pick and no
      // rule that could pick one — which is the definition of a conflict
      // here, and the same answer `modified × modified` with unequal hashes
      // already gives.
      //
      // It could not be reached before this task's digests: an `unchanged`
      // path was reported by both sides on every run and this cell simply
      // returned, so the disagreement was in hand and thrown away. Digesting
      // `(path, hash)` rather than paths alone is what turns it into a dirty
      // bucket, and this is where that bucket's contents land.
      if (entryA.hash != entryB.hash) conflict();
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

/// Resolves a path one side has marked untrusted (SPEC §7.6).
///
/// A marked file reaches here only when it no longer matches its archive
/// entry (the scanner reads one that still does as unmarked), so it is either
/// what the write left or a user's edit since, and nothing on disk tells the
/// two apart. Holding the other side's content means the write finished and
/// only its commit was lost, so a commit-only records it. Anything else is a
/// conflict, which [Conflict.interrupted] labels as possibly incomplete. That
/// includes the other side having nothing, deleted or silent: deleting the
/// marked file could destroy a user's edit, so the user decides.
///
/// A write killed after its bytes and before its mtime commits with the wrong
/// mtime until its content next changes, the same exposure §7.4 accepts for
/// mode bits.
///
/// A marked path with no file and no entry was never written: it is read as
/// a side that has never seen the path, so the other side is mirrored onto
/// it, or with nothing to mirror a commit-only's tombstone clears the mark.
///
/// [onA] says which side is the marked one.
void _resolveUntrusted({
  required ScanEntry untrusted,
  required ScanEntry? other,
  required bool onA,
  required void Function(ActionType type, {int bytes}) act,
  required void Function() conflict,
}) {
  if (!untrusted.isPresent) {
    other != null && other.isPresent
        ? act(
            onA ? ActionType.copyBtoA : ActionType.copyAtoB,
            bytes: _transferBytes(other),
          )
        : act(ActionType.commitOnly);
  } else if (other != null && other.isPresent && other.hash == untrusted.hash) {
    act(ActionType.commitOnly);
  } else {
    conflict();
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
  return entry != null && entry.isPresent && otherSideDirs.contains(entry.path);
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
    if (e.isPresent) e.path,
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
