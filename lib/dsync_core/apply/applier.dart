import 'dart:collection';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/apply/commit_pipeline.dart';
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
/// **Every action reported here is durable on both sides** — SPEC §7.3 makes
/// it so before this fires, which for a successful action means its archive
/// batch has landed (`CommitPipeline`).
///
/// It is still the only cancellation seam [Applier.apply] has: a caller whose
/// own consumer stopped wanting more events can simply never resolve the
/// returned future, and the run parks. What parks is no longer only a worker
/// at its own action boundary. A failed action is reported by its worker, so
/// that worker parks; a successful one is reported by the commit stage, and
/// an unresolved report there stops the batch it belongs to from finishing,
/// which stops the next batch from being sent, which parks every worker in
/// turn as soon as one has nowhere to hand its records.
///
/// So the run runs on for a bounded distance past the last action reported:
/// up to [Applier.concurrency] actions in flight, plus up to twice
/// [Applier.commitBatchSize] applied and waiting to be committed or reported.
/// Every one of them is finished on disk; what they are waiting for is the
/// archive to say so. `RunController` is the caller that does this (see its
/// own doc comments).
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
/// correct — the per-path archive record each action ends with (SPEC §7.3)
/// is, and it is per path, so two actions on two paths have nothing to
/// order between them. A plan holds one action per path, so no two workers
/// can be on the same path at all.
///
/// **Two stages, not one loop** (task 9d2158). A worker does an action's file
/// work and hands the records the two archives are owed to [CommitPipeline],
/// which sends them in batches while the workers carry on. The file work and
/// the commit are different work against different resources — a phone's
/// storage and a round trip carrying one line of JSON — and a worker that did
/// both in turn spent a third of the apply waiting on the second.
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
  /// Every agent operation costs one round trip (SPEC §4.2), and an action
  /// used to be about two of them — a `writeFile` and a commit — so one worker
  /// moved one file per two round trips however fat the link is. Throughput is
  /// therefore `concurrency × file size ÷ (trips × RTT)` and nothing else,
  /// until it meets the link. Since task 9d2158 the commit is batched and off
  /// the worker's path, so `trips` is one: the number below was derived
  /// against two and is left where it is until it is re-measured against one
  /// (9d2158 phase 3), not adjusted by arithmetic over means.
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
  /// meaning "what one exchange cost".
  ///
  /// The cost is what is in flight on the memory-constrained end: sixteen
  /// streaming `writeFile`s hold one chunk each, not one file each (SPEC
  /// §7.2), so about a megabyte of buffers and sixteen open handles a side.
  static const defaultConcurrency = 16;

  /// How many actions this applier runs at once. Injectable, and `1` is
  /// exactly the strictly sequential behaviour this had before pipelining —
  /// which is what a test that reasons about ordering wants.
  final int concurrency;

  /// How many actions' archive records travel in one exchange — see
  /// [CommitPipeline.defaultBatchSize]. Injectable for the same reason
  /// [concurrency] is: `1` is a commit per action, which is what a test
  /// reasoning about one path's commits wants to see.
  final int commitBatchSize;

  Applier({
    this.concurrency = defaultConcurrency,
    this.commitBatchSize = CommitPipeline.defaultBatchSize,
  }) : assert(concurrency >= 1, 'An applier with no workers applies nothing');

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

    // Awaited by the commit stage as it reports each action, so a caller that
    // never resolves it parks the run: the batch being reported never
    // finishes, the next one is never sent, and every worker stops as soon as
    // it has nowhere to hand its records.
    Future<void> report(PlanAction action, Object? error) async {
      if (error == null) {
        applied.add(AppliedPath(path: action.path, type: action.type));
      } else {
        failed.add(
          FailedPath(path: action.path, type: action.type, error: error),
        );
      }
      await onAction(action.path, action.type, error);
    }

    final commits = CommitPipeline(
      agentA: agentA,
      agentB: agentB,
      onCommitted: report,
      batchSize: commitBatchSize,
    );

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final action = queue.removeFirst();
        final outcome = await _applyOne(action, a, b, agentA, agentB, emptied);
        // Both outcomes go to the same stage, so they are reported in the
        // order the actions finished rather than in whichever order two
        // unrelated `await`s happened to resume.
        switch (outcome) {
          case _ActionFailed(:final error):
            await commits.addFailed(action, error);
          case _OwedCommits(:final onA, :final onB):
            await commits.add(action, onA: onA, onB: onB);
        }
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    // Before the sweep, not after: an action still in a batch is an action
    // still to be reported, and `removeEmptyDirs` is a barrier that would
    // otherwise be waiting on the same connections the last commits need.
    await commits.drain();
    await _pruneEmptiedDirs(emptied);

    return ApplyResult(applied: applied, failed: failed);
  }

  /// Applies one action, returning what it left the two archives owing, or
  /// the failure it ended with (SPEC §7.6).
  ///
  /// The records are *returned* rather than committed here, because when they
  /// are sent is [CommitPipeline]'s to decide and no longer this action's.
  /// What is still this method's is which record each replica gets, which is
  /// the part SPEC §7.3 is about.
  Future<_ActionOutcome> _applyOne(
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
          final (:onSource, :onDest) = await _copy(
            action.path,
            source: agentA,
            dest: agentB,
            sourceEntries: a,
          );
          return _OwedCommits(onA: onSource, onB: onDest);
        case ActionType.copyBtoA:
          final (:onSource, :onDest) = await _copy(
            action.path,
            source: agentB,
            dest: agentA,
            sourceEntries: b,
          );
          return _OwedCommits(onA: onDest, onB: onSource);
        case ActionType.deleteOnA:
          return await _delete(action.path, target: agentA, emptied: emptied);
        case ActionType.deleteOnB:
          return await _delete(action.path, target: agentB, emptied: emptied);
        case ActionType.commitOnly:
          return _commitOnly(action.path, a[action.path], b[action.path]);
      }
    } catch (error) {
      return _ActionFailed(error);
    }
  }

  /// Copy in one direction (SPEC §7.2, §7.3). [source] streams the file;
  /// [dest] writes it and reports the metadata actually observed afterward.
  ///
  /// Returns what each side is owed rather than committing it: [dest] the
  /// post-write metadata (the content didn't change, so [sourceEntry]'s
  /// already-known hash is reused rather than rehashing on the destination),
  /// [source] its own unchanged entry, refreshing its archive to match this
  /// scan. Both go to [CommitPipeline], which is what decides when.
  Future<({ArchiveCommit onSource, ArchiveCommit onDest})> _copy(
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

    return (
      onDest: ArchiveUpsert(
        ArchiveEntry(
          path: path,
          size: metadata.size,
          mtime: metadata.mtime,
          mode: metadata.mode,
          hash: sourceEntry.hash!,
        ),
      ),
      onSource: ArchiveUpsert(
        ArchiveEntry(
          path: path,
          size: sourceEntry.size!,
          mtime: sourceEntry.mtime!,
          mode: sourceEntry.mode!,
          hash: sourceEntry.hash!,
        ),
      ),
    );
  }

  /// Delete on the side that still physically holds the file (SPEC §7.5,
  /// §7.3). Both archives are tombstoned, even though only [target] ever held
  /// the file — both need to agree the path is gone.
  ///
  /// The ancestor pruning §7.5 also asks for is *not* done here. It is
  /// recorded in [emptied] and swept once the whole plan is applied, for the
  /// reason [_pruneEmptiedDirs] gives.
  Future<_ActionOutcome> _delete(
    String path, {
    required Agent target,
    required List<_Emptied> emptied,
  }) async {
    await target.delete(path);
    // Recorded as soon as the file is gone, not after the commits: the
    // directory is empty from this moment whatever the commits do, and a
    // commit that fails leaves a failed action (SPEC §7.6) whose file is
    // still deleted.
    emptied.add(_Emptied(target, path));

    return _OwedCommits(
      onA: ArchiveTombstone(path),
      onB: ArchiveTombstone(path),
    );
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
  /// sides currently hold identical content, in which case each is owed an
  /// upsert built from its own scan entry, or at least one side has nothing
  /// to upsert — already deleted, or (the one-sided tombstone of §6's "a
  /// path one side has never seen", task 6a967f) never scanned into [a]/[b]
  /// at all because that side is silent about the path — in which case both
  /// are owed a tombstone instead of an upsert over the null fields.
  ///
  /// A `null` entry is treated exactly like an already-deleted one: it is
  /// the silent side of a one-sided commit-only, where there was never an
  /// archive entry or a file to begin with, so tombstoning it is a no-op
  /// commit, redundant but harmless, and dropped by the next compaction
  /// (SPEC §8.2) since this action lands in `applied`.
  _ActionOutcome _commitOnly(
    String path,
    ScanEntry? entryA,
    ScanEntry? entryB,
  ) {
    final aDeleted = entryA == null || entryA.status == ScanStatus.deleted;
    final bDeleted = entryB == null || entryB.status == ScanStatus.deleted;
    if (aDeleted && bDeleted) {
      return _OwedCommits(
        onA: ArchiveTombstone(path),
        onB: ArchiveTombstone(path),
      );
    }

    return _OwedCommits(
      onA: ArchiveUpsert(_ownEntry(path, entryA!)),
      onB: ArchiveUpsert(_ownEntry(path, entryB!)),
    );
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

/// What one action left behind for [Applier.apply] to do next: the records
/// the two archives are owed, or the failure that means neither gets one.
///
/// A sum type rather than a nullable error beside a nullable pair, because
/// the two cases have nothing in common and every caller has to branch on
/// which it got anyway.
sealed class _ActionOutcome {
  const _ActionOutcome();
}

/// An action that succeeded, and what each replica's archive is owed for it
/// (SPEC §7.3). Handed to `CommitPipeline`, which decides when it travels.
final class _OwedCommits extends _ActionOutcome {
  final ArchiveCommit onA;
  final ArchiveCommit onB;

  const _OwedCommits({required this.onA, required this.onB});
}

/// An action that failed (SPEC §7.6). Neither archive is committed, so the
/// path is left as it landed and the next run resolves the difference.
final class _ActionFailed extends _ActionOutcome {
  final Object error;

  const _ActionFailed(this.error);
}

/// One directory sweep owed by a delete that has already happened — which
/// replica to prune on, and the path whose ancestors to walk (SPEC §7.5).
class _Emptied {
  final Agent agent;
  final String path;

  const _Emptied(this.agent, this.path);
}
