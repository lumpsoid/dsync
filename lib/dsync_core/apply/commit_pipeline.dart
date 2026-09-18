import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/plan.dart';

/// Reports one action as its commits land on both replicas — `error` is
/// `null` when they did, and the failure the batch ended with otherwise.
///
/// Awaited by [CommitPipeline], which is what makes a consumer that stops
/// consuming stop the run: see [CommitPipeline.add].
typedef CommitReport = Future<void> Function(PlanAction action, Object? error);

/// Owns the commit stage of an apply: collects the archive records each
/// finished action owes the two replicas, sends them in batches, and reports
/// every action — committed or failed — in the order it finished (SPEC §7.3,
/// task 9d2158).
///
/// **Why a stage and not two more `await`s in the worker.** Measured
/// phone-to-desktop over `peer://`, an action was a 49.0 ms `writeFile`
/// followed by a 22.0 ms `archiveCommitUpsert`, of which 21.7 ms was link
/// latency and 0.34 ms was the replica doing the work. A third of the apply
/// was a worker holding still while a round trip carried one short line of
/// JSON. The commit is not the file work's continuation; it is different work
/// against a different resource, and the two only looked like one operation
/// because one worker did both in turn.
///
/// So a worker hands its records over and takes its next action. The records
/// wait here until there are [batchSize] of them, then go as one exchange per
/// replica. At the measured rates that is one round trip per sixty-four paths
/// instead of one per path, and it happens while the workers are writing
/// files rather than instead of it.
///
/// **What this does not batch is durability.** Each replica's archive already
/// buffers commits and fsyncs them together (SPEC §8.2), flushing at `unlock`.
/// This batches the *exchange*; §8.2 batches the fsync. They are independent
/// bounds on the same crash window, and the window is the one §7.3 already
/// describes: a crash loses commits for paths whose files were written, and
/// the next run finds those paths in sync on both sides and commits them.
///
/// **A failed action comes through here too** ([addFailed]), even though it
/// owes neither archive anything. Reporting is one thing or it is not a thing:
/// with failures reported by their worker and successes by this stage, two
/// actions that finished in a known order could be reported in either, and
/// the order outcomes arrive in would depend on which of two unrelated
/// `await`s resumed first. A failure rides its batch as a slot with no
/// records in it.
///
/// **What it costs is that the run reports later than it acts.** An action is
/// reported when its batch lands, so up to `2 × batchSize` actions may have
/// been applied since the last one a consumer heard about — one batch filling
/// and one on the wire, and no more, because [add] will not start a third.
/// Every action reported is still durable on both sides by the time it is
/// reported, which is the part SPEC §7.3 asks for and the part a caller
/// resolving progress events depends on.
class CommitPipeline {
  /// How many actions' records travel in one exchange.
  ///
  /// **Sixty-four, because that is where the round trip stops being
  /// measurable.** The exchange it amortises is 22.0 ms; at sixty-four paths
  /// that is 0.34 ms an action, already under the 15.6 ms the destination
  /// spends writing the file and far under anything SPEC §17 can resolve.
  /// Doubling it again would halve a number that no longer shows up, while
  /// doubling the report lag and the batch a crash loses.
  ///
  /// The upper bound is set by what a batch has to hold, not by the wire: one
  /// record is about 150 bytes, so a full batch is a ~10 KiB frame, against a
  /// link that moves 12.7 KiB in 0.2 ms.
  static const defaultBatchSize = 64;

  /// The two replicas a batch is committed to. Both, always: an action is
  /// owed by both archives or by neither (SPEC §7.3).
  final Agent agentA;
  final Agent agentB;

  final int batchSize;

  /// Where a finished batch's actions are reported. A callback for the reason
  /// `Applier`'s own `ApplyProgress` is one: this class hands back outcomes it
  /// already has and knows nothing about what a caller does with them.
  final CommitReport onCommitted;

  /// Records handed over and not yet sent. Never longer than [batchSize] at
  /// rest — [add] sends as soon as it reaches it.
  final List<_PendingCommits> _pending = [];

  /// The batch on the wire, if there is one. At most one, which is what
  /// bounds how far ahead of its own reporting the run may get.
  Future<void>? _inFlight;

  CommitPipeline({
    required this.agentA,
    required this.agentB,
    required this.onCommitted,
    this.batchSize = defaultBatchSize,
  }) : assert(batchSize >= 1, 'A batch of nothing commits nothing');

  /// Takes what [action] owes the two archives now that its file work has
  /// succeeded, and returns as soon as there is room for it.
  ///
  /// It does **not** wait for the commit: that is the whole point, and it is
  /// why a worker can be several actions past the last one reported. What it
  /// does wait for is a batch already on the wire, once the pending one is
  /// full — which is also what stops the run when a consumer stops resolving
  /// the reports, since a batch is not finished until every action in it has
  /// been reported.
  Future<void> add(
    PlanAction action, {
    required ArchiveCommit onA,
    required ArchiveCommit onB,
  }) => _enqueue(_PendingCommits(action, onA: onA, onB: onB));

  /// Takes an action that failed (SPEC §7.6), so that it is reported in its
  /// place in the sequence rather than ahead of the successes that finished
  /// before it. It owes neither archive a record and adds none to the batch.
  Future<void> addFailed(PlanAction action, Object error) =>
      _enqueue(_PendingCommits(action, error: error));

  Future<void> _enqueue(_PendingCommits owed) async {
    _pending.add(owed);
    if (_pending.length < batchSize) return;
    await _send();
  }

  /// Sends everything left and waits until every batch has been reported.
  /// Called once the last action is applied; after it returns, nothing this
  /// pipeline was given is still owed.
  Future<void> drain() async {
    while (_pending.isNotEmpty || _inFlight != null) {
      if (_pending.isEmpty) {
        await _inFlight;
        continue;
      }
      await _send();
    }
    // The last batch was handed to the wire by the loop above but not waited
    // for: `_send` returns once the batch is *started*.
    await _inFlight;
  }

  Future<void> _send() async {
    final previous = _inFlight;
    if (previous != null) await previous;
    // Another caller may have taken these records while this one waited
    // above. Nothing is lost — they are in that caller's batch.
    if (_pending.isEmpty) return;

    final batch = List.of(_pending);
    _pending.clear();
    final sending = _commit(batch);
    _inFlight = sending;
    unawaited(
      sending.whenComplete(() {
        if (identical(_inFlight, sending)) _inFlight = null;
      }),
    );
  }

  /// One exchange per replica, in parallel — they are two connections and
  /// neither commit depends on the other's — then one report per action.
  ///
  /// **A batch fails whole.** Either side throwing fails every action in it,
  /// because neither the wire nor `Agent.archiveCommit` says which records
  /// landed. That is pessimistic and deliberately so: an action reported
  /// failed whose commit did land costs the next run nothing — it finds the
  /// path in sync — while the reverse would leave an archive claiming a path
  /// was propagated when nothing said so.
  Future<void> _commit(List<_PendingCommits> batch) async {
    final onA = [for (final owed in batch) ?owed.onA];
    final onB = [for (final owed in batch) ?owed.onB];
    Object? error;
    // A batch of nothing but failed actions has nothing to commit, and
    // exchanging two empty lists to say so would be the round trip this
    // class exists to avoid.
    if (onA.isNotEmpty || onB.isNotEmpty) {
      try {
        await Future.wait([
          agentA.archiveCommit(onA),
          agentB.archiveCommit(onB),
        ]);
      } catch (thrown) {
        error = thrown;
      }
    }
    for (final owed in batch) {
      await onCommitted(owed.action, owed.error ?? error);
    }
  }
}

/// One finished action and what it left for the pipeline: the record each
/// replica is owed, or the failure that means neither gets one.
class _PendingCommits {
  final PlanAction action;
  final ArchiveCommit? onA;
  final ArchiveCommit? onB;

  /// The action's own failure (SPEC §7.6), reported in place of whatever the
  /// batch around it did.
  final Object? error;

  const _PendingCommits(this.action, {this.onA, this.onB, this.error});
}
