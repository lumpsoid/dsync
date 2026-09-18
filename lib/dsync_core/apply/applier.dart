import 'dart:collection';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/apply_result.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';

/// Reports one action's outcome as [Applier.apply] finishes it — `error` is
/// `null` on success, the thrown error otherwise (SPEC §7.6), matching
/// exactly what [FailedPath.error] would say.
///
/// **In completion order, not plan order** (SPEC §7.1, task 0f7dfc). Several
/// actions are in flight at once, so the order outcomes arrive in is the
/// order they finished, and a caller rendering a row per path gets them as
/// they land rather than as they were planned.
///
/// A worker `await`s the returned future before taking its next action, so
/// this is still the only cancellation seam [Applier.apply] has: a caller
/// whose own consumer stopped wanting more events can simply never resolve
/// it, and each worker in turn parks at its own action boundary. What that
/// no longer promises is that exactly one action ran past the last one
/// reported: up to [Applier.concurrency] actions may have been in flight,
/// and each of them is either finished and durable (SPEC §7.3 makes it so on
/// both sides before this fires) or parked here waiting to be reported.
/// Nothing beyond those ever starts. `RunController` is the caller that does
/// this (see its own doc comments).
///
/// Shaped like the callbacks already in this codebase — `RunController`'s
/// own `Presenter` typedef, `AgentServer.serve`'s `Agent Function(ReplicaSpec)`
/// — a plain function type, not a second interface: `Applier` still has
/// exactly one implementation of "how to apply a plan", only how its
/// progress leaves it changes (task e9f31c).
typedef ApplyProgress = Future<void> Function(
  String path,
  ActionType type,
  Object? error,
);

Future<void> _noopApplyProgress(String path, ActionType type, Object? error) =>
    Future.value();

/// Executes a [Plan] against the two replicas' [Agent]s (SPEC §7).
///
/// Orchestrates `copy`/`delete`/archive-commit calls on [Agent] — never
/// touches a filesystem or archive store directly, so it works the same
/// whether an [Agent] is local or remote. [onA]/[onB] are the same status
/// lists the caller already got from `agentA.scan()`/`agentB.scan()` before
/// reconciling: a [PlanAction] carries only a path and an [ActionType], not
/// the size/mtime/mode/hash needed to write a file or build an
/// [ArchiveEntry], so those are looked up here by path.
///
/// Actions are *started* in the order given and up to [concurrency] of them
/// run at once (SPEC §7.1, task 0f7dfc). Order was never what made this
/// correct — the per-path archive commit in [_copy]/[_delete] (SPEC §7.3)
/// is, and it is per path, so two actions on two paths have nothing to
/// order between them. A plan holds one action per path, so no two workers
/// can be on the same path at all.
///
/// **Why overlap at all.** A single action against a remote replica is a
/// handful of round trips with the link idle between them, and on a phone an
/// idle link is a radio that powers its receiver down (`RequestWindow`).
/// Overlapping actions is what puts traffic in that gap; the connection's
/// own window is what bounds it.
class Applier {
  /// How many actions may be in flight at once.
  ///
  /// **Sixteen, and the number is the bandwidth-delay product**, not a guess.
  /// Every agent operation costs one round trip (SPEC §4.2), and an action is
  /// about two of them — a `writeFile` and an `archiveCommitUpsert` — so one
  /// worker moves one file per two round trips however fat the link is.
  /// Throughput is therefore `concurrency × file size ÷ (2 × RTT)` and
  /// nothing else, until it meets the link.
  ///
  /// Measured over a unix socket with a forwarding proxy adding 10 ms
  /// (`benchmark/local_sync_throughput.dart`), on the 14k-file tree SPEC §17
  /// quotes: apply time halved for every doubling from 4 to 64 concurrent
  /// actions, with every per-operation mean pinned at one round trip
  /// throughout — no contention appeared anywhere in that range. The same
  /// sweep at zero latency showed 16 slightly *faster* than 4, so this costs
  /// a same-machine `unix://` sync nothing.
  ///
  /// Sixteen is where that arithmetic meets a phone on Wi-Fi: ~12.7 KB per
  /// file at a 10 ms round trip is ~0.53 MiB/s per worker, so sixteen reach
  /// ~8.5 MiB/s — about what the link measured at. Going further would not be
  /// wrong, it would just be queueing against the link instead of against
  /// latency, and queueing is what makes SPEC §17's per-operation means stop
  /// meaning "what one exchange cost". The other lever is the round trips
  /// themselves: fold the archive commit into the `writeFile` reply and every
  /// number here doubles.
  ///
  /// The cost is what is in flight on the memory-constrained end: sixteen
  /// streaming `writeFile`s hold one chunk each, not one file each (SPEC
  /// §7.2), so about a megabyte of buffers and sixteen open handles a side.
  static const defaultConcurrency = 16;

  /// How many actions this applier runs at once. Injectable, and `1` is
  /// exactly the strictly sequential behaviour this had before pipelining —
  /// which is what a test that reasons about ordering wants.
  final int concurrency;

  Applier({this.concurrency = defaultConcurrency})
    : assert(concurrency >= 1, 'An applier with no workers applies nothing');

  Future<ApplyResult> apply(
    Plan plan,
    List<ScanEntry> onA,
    List<ScanEntry> onB,
    Agent agentA,
    Agent agentB, {
    ApplyProgress onAction = _noopApplyProgress,
  }) async {
    final a = {for (final e in onA) e.path: e};
    final b = {for (final e in onB) e.path: e};

    final applied = <AppliedPath>[];
    final failed = <FailedPath>[];

    // Filled by every delete that got as far as removing its file, swept
    // once at the end — see [_pruneEmptiedDirs].
    final emptied = <_Emptied>[];

    // One queue, drained by [concurrency] workers, rather than a chunked
    // `Future.wait` per batch: a batch is only as fast as its slowest action,
    // and a plan of 14k small files with one large one in it would spend most
    // of its time with every worker but one idle.
    final queue = Queue<PlanAction>.of(plan.actions);

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final action = queue.removeFirst();
        final error = await _applyOne(action, a, b, agentA, agentB, emptied);
        if (error == null) {
          applied.add(AppliedPath(path: action.path, type: action.type));
        } else {
          failed.add(
            FailedPath(path: action.path, type: action.type, error: error),
          );
        }
        // Awaited inside the worker, so a caller that never resolves it
        // parks this worker at an action boundary and nothing it would have
        // taken next ever starts.
        await onAction(action.path, action.type, error);
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    await _pruneEmptiedDirs(emptied);

    return ApplyResult(applied: applied, failed: failed);
  }

  /// Applies one action, returning the failure it ended with or `null`
  /// (SPEC §7.6).
  Future<Object?> _applyOne(
    PlanAction action,
    Map<String, ScanEntry> a,
    Map<String, ScanEntry> b,
    Agent agentA,
    Agent agentB,
    List<_Emptied> emptied,
  ) async {
    try {
      switch (action.type) {
        case ActionType.copyAtoB:
          await _copy(
            action.path,
            source: agentA,
            dest: agentB,
            sourceEntries: a,
          );
        case ActionType.copyBtoA:
          await _copy(
            action.path,
            source: agentB,
            dest: agentA,
            sourceEntries: b,
          );
        case ActionType.deleteOnA:
          await _delete(
            action.path,
            target: agentA,
            agentA: agentA,
            agentB: agentB,
            emptied: emptied,
          );
        case ActionType.deleteOnB:
          await _delete(
            action.path,
            target: agentB,
            agentA: agentA,
            agentB: agentB,
            emptied: emptied,
          );
        case ActionType.commitOnly:
          await _commitOnly(
            action.path,
            a[action.path],
            b[action.path],
            agentA,
            agentB,
          );
      }
      return null;
    } catch (error) {
      return error;
    }
  }

  /// Copy in one direction (SPEC §7.2, §7.3). [source] streams the file;
  /// [dest] writes it and reports the metadata actually observed afterward.
  /// On success, both sides commit: [dest] with the post-write metadata (the
  /// content didn't change, so [sourceEntry]'s already-known hash is reused
  /// rather than rehashing on the destination), [source] with its own
  /// unchanged entry, refreshing its archive to match this scan.
  Future<void> _copy(
    String path, {
    required Agent source,
    required Agent dest,
    required Map<String, ScanEntry> sourceEntries,
  }) async {
    final sourceEntry = sourceEntries[path]!;
    final metadata = await dest.writeFile(
      path,
      source.readFile(path),
      mtime: sourceEntry.mtime!,
      mode: sourceEntry.mode!,
    );

    if (metadata.size != sourceEntry.size) {
      throw TransferSizeMismatchException(
        path: path,
        expected: sourceEntry.size!,
        actual: metadata.size,
      );
    }

    await dest.archiveCommitUpsert(
      ArchiveEntry(
        path: path,
        size: metadata.size,
        mtime: metadata.mtime,
        mode: metadata.mode,
        hash: sourceEntry.hash!,
      ),
    );
    await source.archiveCommitUpsert(
      ArchiveEntry(
        path: path,
        size: sourceEntry.size!,
        mtime: sourceEntry.mtime!,
        mode: sourceEntry.mode!,
        hash: sourceEntry.hash!,
      ),
    );
  }

  /// Delete on the side that still physically holds the file (SPEC §7.5,
  /// §7.3). On success both archives are tombstoned, even though only
  /// [target] ever held the file — both need to agree the path is gone.
  ///
  /// The ancestor pruning §7.5 also asks for is *not* done here. It is
  /// recorded in [emptied] and swept once the whole plan is applied, for the
  /// reason [_pruneEmptiedDirs] gives.
  Future<void> _delete(
    String path, {
    required Agent target,
    required Agent agentA,
    required Agent agentB,
    required List<_Emptied> emptied,
  }) async {
    await target.delete(path);
    // Recorded as soon as the file is gone, not after the commits: the
    // directory is empty from this moment whatever the commits do, and a
    // commit that fails leaves a failed action (SPEC §7.6) whose file is
    // still deleted.
    emptied.add(_Emptied(target, path));

    await agentA.archiveCommitDelete(path);
    await agentB.archiveCommitDelete(path);
  }

  /// Removes the directories this run emptied (SPEC §7.5), once every action
  /// is done.
  ///
  /// **Deferred rather than done per delete**, because `removeEmptyDirs` is
  /// the one operation that cannot share a connection with anything else: it
  /// reaches *ancestors* of the path it is given, so it can remove a
  /// directory a concurrent `writeFile` on an unrelated path is about to
  /// write into, and `RemoteAgent` therefore makes it a barrier. Called
  /// inside the apply loop it drained the connection's whole window once per
  /// delete, which handed back most of what SPEC §7.1's overlap buys. Here
  /// there is nothing left to drain.
  ///
  /// It is not less correct for being late. §7.5's rule is that the tool
  /// removes only emptiness it created, and that still holds: a directory
  /// emptied by a delete and then written into again by a later copy is now
  /// simply left alone, where before it would have been removed and
  /// recreated.
  ///
  /// **Failures here are swallowed**, which is the one thing this gives up.
  /// Pruning is tidying: §7.3's archive rule does not depend on it, so a
  /// directory left behind cannot stop the replicas converging, and it is
  /// the same best-effort §7.4 already gives mode bits. It is also no longer
  /// attributable — the action it belonged to has already been reported and
  /// recorded as applied, and failing it after the fact would claim the
  /// delete did not happen.
  Future<void> _pruneEmptiedDirs(List<_Emptied> emptied) async {
    for (final entry in emptied) {
      try {
        await entry.agent.removeEmptyDirs(entry.path);
      } catch (_) {
        // See above: cosmetic, and belongs to no action any more.
      }
    }
  }

  /// No filesystem I/O (SPEC §6 "same content, no transfer"). Either both
  /// sides currently hold identical content, in which case each commits an
  /// upsert built from its own scan entry, or at least one side has nothing
  /// to upsert — already deleted, or (the one-sided tombstone of §6's "a
  /// path one side has never seen", task 6a967f) never scanned into [a]/[b]
  /// at all because that side is silent about the path — in which case both
  /// commit a delete instead of upserting the null fields.
  ///
  /// A `null` entry is treated exactly like an already-deleted one: it is
  /// the silent side of a one-sided commit-only, where there was never an
  /// archive entry or a file to begin with, so tombstoning it is a no-op
  /// commit, redundant but harmless, and dropped by the next compaction
  /// (SPEC §8.2) since this action lands in `applied`.
  Future<void> _commitOnly(
    String path,
    ScanEntry? entryA,
    ScanEntry? entryB,
    Agent agentA,
    Agent agentB,
  ) async {
    final aDeleted = entryA == null || entryA.status == ScanStatus.deleted;
    final bDeleted = entryB == null || entryB.status == ScanStatus.deleted;
    if (aDeleted && bDeleted) {
      await agentA.archiveCommitDelete(path);
      await agentB.archiveCommitDelete(path);
      return;
    }

    await agentA.archiveCommitUpsert(_ownEntry(path, entryA!));
    await agentB.archiveCommitUpsert(_ownEntry(path, entryB!));
  }

  ArchiveEntry _ownEntry(String path, ScanEntry entry) => ArchiveEntry(
    path: path,
    size: entry.size!,
    mtime: entry.mtime!,
    mode: entry.mode!,
    hash: entry.hash!,
  );
}

/// Thrown when a copy leaves the destination a different size from the
/// source (SPEC §7.2 step 4).
///
/// The destination's archive entry records the *source's* hash rather than
/// rehashing bytes that are supposed to be identical. That shortcut is only
/// sound if the transfer completed, and the size the destination stat-ed
/// against the size the source reported is the cheapest available check that
/// it did. Without it a truncated transfer is archived under a hash that does
/// not describe the file on disk, and from the next run on both replicas
/// agree that a corrupt file is in sync — the one outcome SPEC §1 rules out.
///
/// Treated as a failed action (SPEC §7.6): the path is left as it landed, and
/// neither archive is committed, so the next run sees the difference and
/// resolves it.
class TransferSizeMismatchException implements Exception {
  final String path;
  final int expected;
  final int actual;

  const TransferSizeMismatchException({
    required this.path,
    required this.expected,
    required this.actual,
  });

  @override
  String toString() =>
      'Incomplete transfer of "$path": expected $expected bytes, '
      'destination has $actual';
}

/// One directory sweep owed by a delete that has already happened — which
/// replica to prune on, and the path whose ancestors to walk (SPEC §7.5).
class _Emptied {
  final Agent agent;
  final String path;

  const _Emptied(this.agent, this.path);
}
