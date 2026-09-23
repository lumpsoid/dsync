import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/apply/commit_pipeline.dart';
import 'package:dsync/dsync_core/apply/read_ahead.dart';
import 'package:dsync/dsync_core/models/apply_result.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/read_ahead_stats.dart';
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
/// Past those, up to [Applier.concurrency] further copies may be queued with
/// their *source* read already started (`ReadAhead`). Those touch nothing: no
/// destination is written, nothing is committed, and a parked run simply holds
/// their bytes — at most `ReadAhead.defaultBudgetBytes` of them — until it is
/// collected.
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

void _noopReadAheadReport(ReadAheadStats stats) {}

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
/// **Three stages, not one loop** (task 9d2158), because there are three
/// resources and they have three different service times. [ReadAhead] reads
/// the source ahead of the writers; [concurrency] workers do the destination's
/// file work; [CommitPipeline] sends the records the two archives are owed,
/// in batches, while the workers carry on. Each stage is bounded by what
/// actually constrains it — bytes held on the source, actions in flight on the
/// destination, records per exchange on the wire — where one `concurrency`
/// counter used to govern all three, and each of the two stages that were
/// split out was measured as a term a worker spent *waiting* rather than
/// working: a third of the apply on the commit, and 53–62% of the serialized
/// budget on the source's read.
///
/// **Why overlap at all.** A single action against a remote replica is a
/// handful of round trips with the link idle between them, and on a phone an
/// idle link is a radio that powers its receiver down (`RequestWindow`).
/// Overlapping actions is what puts traffic in that gap; the connection's
/// own window is what bounds it.
class Applier {
  /// How many actions may be in flight at once.
  ///
  /// **The 16 → 4 sweep was run and 16 won.** Apply went 62.1 s → 80.6 s on
  /// the 14k-file tree over `peer://` for a 4× cut in workers — throughput
  /// 233 → 180 actions a second, down 23%, so four workers already reach
  /// most of what the path allows and the other twelve buy the rest. What
  /// the sweep settled is where the time is: `link` collapsed 42.4 → 9.0 ms,
  /// so that column was this side's own queueing and not the link, while
  /// `far ÷ peers` held at 4.35 ms and 4.89 ms an action against serialized
  /// budgets of 4.29 ms and 5.57 ms. The destination is the bound, and SPEC
  /// §17's `starved` split is what now says which part of it.
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

  /// How many source reads may be open beyond [concurrency] — see
  /// [ReadAhead.maxStreams], which is `concurrency + readAheadLead`.
  ///
  /// It is not what sets how far ahead the pump runs: a read-ahead slot is
  /// released when its writer takes the last chunk rather than when the write
  /// finishes, so slots turn over faster than actions do and what paces the
  /// prefetch is the queue between the pump and the workers. This is the
  /// headroom that keeps the pump from waiting on a slot while writes are still
  /// taking bytes, and the bound a *stalled* read runs into.
  final int readAheadLead;

  /// How many of the plan's actions each mark exchange covers (SPEC §7.6) —
  /// see [_markUntrusted]. The commit batch's size, so a run makes about as
  /// many mark exchanges as commit exchanges.
  static const defaultMarkWindow = CommitPipeline.defaultBatchSize;

  /// How many actions one mark exchange covers. Injectable so a test can
  /// reason about which window a path falls in.
  final int markWindow;

  Applier({
    this.concurrency = defaultConcurrency,
    this.commitBatchSize = CommitPipeline.defaultBatchSize,
    this.readAheadLead = ReadAhead.defaultLead,
    this.markWindow = defaultMarkWindow,
  }) : assert(concurrency >= 1, 'An applier with no workers applies nothing'),
       assert(readAheadLead >= 0, 'A negative lead is fewer reads than writes'),
       assert(markWindow >= 1, 'A window that marks nothing writes nothing');

  Future<ApplyResult> apply(
    Plan plan,
    List<ScanEntry> onA,
    List<ScanEntry> onB,
    Agent agentA,
    Agent agentB, {
    ApplyProgress onAction = _noopApplyProgress,
    ReadAheadReport onReadAhead = _noopReadAheadReport,
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
    //
    // Filled by the pump below rather than by the workers themselves, so that
    // a copy arrives at a worker with its source read already under way. It is
    // bounded, which is what makes the pump run ahead of the workers by a
    // fixed distance instead of walking the whole plan at once.
    final queue = _Handoff(capacity: concurrency);

    final readAhead = ReadAhead(maxStreams: concurrency + readAheadLead);

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

    // Walks the plan in order — so SPEC §7.1's "started in plan order" still
    // holds — starting each copy's source read before handing the action to a
    // worker. It blocks in two places, and between them is the whole of what
    // bounds the read-ahead: on a read-ahead slot, and on room in the queue.
    Future<void> pump() async {
      final actions = plan.actions;
      var markedUpTo = 0;
      Object? markFailure;
      for (var i = 0; i < actions.length; i++) {
        final action = actions[i];
        // The next window is marked only when the pump reaches it, so a run
        // that stops leaves marks on the copies it had started and at most a
        // window of ones it had not — see [_markUntrusted].
        if (i == markedUpTo) {
          markedUpTo = min(i + markWindow, actions.length);
          markFailure = await _markUntrusted(
            actions.sublist(i, markedUpTo),
            agentA,
            agentB,
          );
        }
        if (markFailure != null &&
            (action.type == ActionType.copyAtoB ||
                action.type == ActionType.copyBtoA)) {
          // Nothing of it is written, and nothing read: the worker reports it
          // failed with the mark's own error.
          if (!await queue.put(_Ready(action, null, markFailure))) return;
          continue;
        }
        final source = switch (action.type) {
          ActionType.copyAtoB => (agent: agentA, entry: a[action.path]),
          ActionType.copyBtoA => (agent: agentB, entry: b[action.path]),
          _ => null,
        };
        // A copy whose source entry has no size cannot be reserved for, so it
        // takes the unbuffered path and fails in the worker exactly where it
        // failed before — the pump is not a place an action can fail, because
        // a throw here would end the apply rather than the action.
        final prefetch = switch (source) {
          (agent: final agent, entry: ScanEntry(size: final size?)) =>
            await readAhead.begin(action.path, source: agent, size: size),
          _ => null,
        };
        if (!await queue.put(_Ready(action, prefetch))) {
          // Every worker has already stopped, so nobody will ever drain this
          // one. Releasing it is what closes the source read.
          prefetch?.discard();
          return;
        }
      }
      queue.close();
    }

    Future<void> worker() async {
      while (true) {
        final ready = await queue.take();
        if (ready == null) return;
        final action = ready.action;
        final markFailure = ready.markFailure;
        if (markFailure != null) {
          await commits.addFailed(action, markFailure);
          continue;
        }
        final outcome = await _applyOne(
          action,
          a,
          b,
          agentA,
          agentB,
          emptied,
          ready.prefetch,
        );
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

    // The workers release the pump if they all stop without draining the
    // queue, which only an `onAction` that *throws* can cause — the documented
    // way to stop a run is to never resolve it (see [ApplyProgress]). Without
    // this the pump would wait forever for room nobody is going to make.
    Future<void> workers() async {
      try {
        await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
      } finally {
        queue.abandon();
      }
    }

    await Future.wait([pump(), workers()]);
    onReadAhead(readAhead.stats);
    // Before the sweep, not after: an action still in a batch is an action
    // still to be reported, and `removeEmptyDirs` is a barrier that would
    // otherwise be waiting on the same connections the last commits need.
    await commits.drain();
    await _pruneEmptiedDirs(emptied);

    return ApplyResult(applied: applied, failed: failed);
  }

  /// Marks every path [actions] copies to as untrusted on the side it is
  /// copied to, and returns once both marks are durable (SPEC §7.6) — or the
  /// error that stopped them, which the caller fails those copies with.
  ///
  /// **Before any of them is written**, because `Agent.writeFile` writes in
  /// place and a write that stops part-way — a failed stream, a killed
  /// process — leaves a file the next scan could only read as a local edit.
  /// The mark makes it read as possibly torn: committed if it holds the other
  /// side's content, a conflict labelled interrupted if not. It is superseded
  /// by the path's own commit (§7.3), so a copy that lands clears it and one
  /// that fails keeps it.
  ///
  /// **A window at a time, as the pump reaches it**, not the whole plan up
  /// front. A mark on a copy that never started is harmless to the next scan,
  /// which reads a file still matching its entry as unmarked, but it clears
  /// only when a later commit touches the path; until then a user's edit
  /// there is raised as an interrupted conflict. Marking by window bounds
  /// what a stopped run leaves that way to one [markWindow] plus the queue.
  /// The pump runs ahead of the workers, so a window's exchange and fsync
  /// overlap the writes already queued rather than stalling them.
  Future<Object?> _markUntrusted(
    List<PlanAction> actions,
    Agent agentA,
    Agent agentB,
  ) async {
    final onA = [
      for (final action in actions)
        if (action.type == ActionType.copyBtoA) ArchiveIntent(action.path),
    ];
    final onB = [
      for (final action in actions)
        if (action.type == ActionType.copyAtoB) ArchiveIntent(action.path),
    ];
    try {
      await Future.wait([
        if (onA.isNotEmpty) agentA.archiveCommit(onA),
        if (onB.isNotEmpty) agentB.archiveCommit(onB),
      ]);
      return null;
    } catch (error) {
      return error;
    }
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
    Prefetch? prefetch,
  ) async {
    try {
      switch (action.type) {
        case ActionType.copyAtoB:
          final (:onSource, :onDest) = await _copy(
            action.path,
            source: agentA,
            dest: agentB,
            sourceEntries: a,
            prefetch: prefetch,
          );
          return _OwedCommits(onA: onSource, onB: onDest);
        case ActionType.copyBtoA:
          final (:onSource, :onDest) = await _copy(
            action.path,
            source: agentB,
            dest: agentA,
            sourceEntries: b,
            prefetch: prefetch,
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
      // A `writeFile` that throws part-way through the stream it was given may
      // simply drop its subscription, which would leave this prefetch's slot
      // and its source read held for the rest of the run. Discarding is a
      // no-op on one that finished normally.
      prefetch?.discard();
      return _ActionFailed(error);
    }
  }

  /// Copy in one direction (SPEC §7.2, §7.3). [source] streams the file;
  /// [dest] writes it and reports the metadata actually observed afterward.
  ///
  /// **[prefetch] is that same source stream, already running** (task 9d2158
  /// §10.3). Without it this was `dest.writeFile(path, source.readFile(path))`,
  /// and because the stream is lazy the read did not begin until the write
  /// subscribed: the destination waited out the whole read before it had a byte
  /// to write. `source` is still the agent the bytes come from — it is simply
  /// no longer this method that starts asking for them. A `null` prefetch is
  /// the old path, taken by a copy whose source entry had no size for
  /// [ReadAhead] to reserve against.
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
    required Prefetch? prefetch,
  }) async {
    final sourceEntry = sourceEntries[path]!;
    final metadata = await dest.writeFile(
      path,
      prefetch?.bytes ?? source.readFile(path),
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
    // `isPresent` rather than `deleted` alone: a marked path with no file
    // (SPEC §7.6) resolves here too, and is owed a tombstone to clear its mark.
    final aDeleted = entryA == null || !entryA.isPresent;
    final bDeleted = entryB == null || !entryB.isPresent;
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

/// One action, with the source read for it already under way if it is a copy.
///
/// The pump's unit of work and the workers': what the read-ahead stage hands
/// the write stage.
class _Ready {
  final PlanAction action;
  final Prefetch? prefetch;

  /// Why this copy must not be written: its window's mark failed (SPEC §7.6).
  final Object? markFailure;

  const _Ready(this.action, this.prefetch, [this.markFailure]);
}

/// A bounded FIFO between the pump and the workers.
///
/// **Bounded, because that is what makes the read-ahead a read-*ahead*.** The
/// pump stops [capacity] items in front of the workers, so the reads it has
/// started are the next ones to be written and not the whole plan's. Unbounded
/// it would walk 14,471 actions at once and the read-ahead's own slot bound
/// would be the only thing holding it, which is the same bound expressed twice
/// and in the wrong place.
///
/// Plain completers rather than a `StreamController`: several workers take from
/// this, which a single-subscription stream cannot serve, and a broadcast one
/// would hand every worker the same action.
class _Handoff {
  final int capacity;

  final Queue<_Ready> _items = Queue();
  final Queue<Completer<void>> _takers = Queue();
  final Queue<Completer<void>> _putters = Queue();

  /// Set once the pump has walked the whole plan: what turns an empty queue
  /// from "wait" into "there will be no more".
  bool _closed = false;

  /// Set when the workers have all stopped without draining. Distinct from
  /// [_closed] — that one ends the *workers*, this one ends the *pump*.
  bool _abandoned = false;

  _Handoff({required this.capacity})
    : assert(capacity >= 1, 'A handoff that holds nothing hands nothing over');

  /// Adds [item], returning once there is room for it — `false` if there is
  /// nobody left to take it, in which case it was not added and whatever it
  /// holds is the caller's to release.
  Future<bool> put(_Ready item) async {
    while (_items.length >= capacity) {
      if (_abandoned) return false;
      final room = Completer<void>();
      _putters.add(room);
      await room.future;
    }
    if (_abandoned) return false;
    _items.add(item);
    if (_takers.isNotEmpty) _takers.removeFirst().complete();
    return true;
  }

  /// The next action to apply, or `null` once [close] has been called and
  /// everything put here has been taken.
  Future<_Ready?> take() async {
    while (_items.isEmpty) {
      if (_closed) return null;
      final work = Completer<void>();
      _takers.add(work);
      await work.future;
    }
    final item = _items.removeFirst();
    if (_putters.isNotEmpty) _putters.removeFirst().complete();
    return item;
  }

  void close() {
    _closed = true;
    while (_takers.isNotEmpty) {
      _takers.removeFirst().complete();
    }
  }

  void abandon() {
    _abandoned = true;
    while (_putters.isNotEmpty) {
      _putters.removeFirst().complete();
    }
  }
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
