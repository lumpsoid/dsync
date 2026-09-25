import 'package:flutter/foundation.dart';

/// Where the run stands. Sealed, for the reason `PairOutcome` and
/// `AppBootstrap` give: a phase with the wrong payload — "finished" with no
/// counts, "stopped" with no number — cannot be constructed, and the page
/// switches over every case.
sealed class SyncRunPhase {
  const SyncRunPhase();
}

/// `SyncRunController.start` has not been called.
final class SyncRunIdle extends SyncRunPhase {
  const SyncRunIdle();
}

/// The core is connecting both sides: no run update can have arrived.
final class SyncRunConnecting extends SyncRunPhase {
  const SyncRunConnecting();
}

/// Both sides are connected and the core is scanning them and reconciling
/// the two scans (SPEC §5, §6): the header, the tally, the path lists and
/// the plan fill in as their events arrive. A dry run stays here until its
/// summary — it never applies.
final class SyncRunScanning extends SyncRunPhase {
  const SyncRunScanning();
}

/// The plan has been answered and the core is applying it (SPEC §7). Its own
/// case rather than [SyncRunScanning] with a progress, because between the
/// answer and the first progress the page must already say "applying" — and
/// a plan with nothing kept in it may never report a progress at all.
final class SyncRunApplying extends SyncRunPhase {
  const SyncRunApplying();
}

/// The stream ended with a `RunSummaryEvent` (SPEC §11.4). The five counts
/// are carried as five numbers: [skipped] is "offered and declined" and
/// [unreadable] is "never reached the plan at all" — two questions, so two
/// numbers, exactly as `RunSummaryEvent.unreadableCount`'s doc comment
/// keeps them apart.
final class SyncRunFinished extends SyncRunPhase {
  const SyncRunFinished({
    required this.applied,
    required this.skipped,
    required this.conflicts,
    required this.failed,
    required this.unreadable,
  });

  final int applied;
  final int skipped;
  final int conflicts;
  final int failed;
  final int unreadable;
}

/// `RunController` has handed the plan to the presenter and is suspended on
/// its answer (SPEC §11.3): the page's own plan and conflict rows turn into
/// the review, each with its control. The phase carries only what is fixed
/// for the whole review — which choices each conflict offers, keyed by path
/// so a row built lazily finds its own in O(1). The user's current choices
/// are not here: each lives in its path's cell
/// ([SyncRunViewState.actionDecisionCell],
/// [SyncRunViewState.conflictDecisionCell]) and the running total in
/// [SyncRunViewState.decisionSummary], so a tap rebuilds one row and the bar
/// under the page, never the phase and every row with it.
final class SyncRunAwaitingDecisions extends SyncRunPhase {
  const SyncRunAwaitingDecisions({required this.conflictOffers});

  /// Each conflict's offered choices, by path — a side with no record of
  /// the path cannot be the one kept, and keeping both needs a file on both
  /// sides (`PlanDecisions.offeredFor`).
  final Map<String, List<SyncRunConflictChoice>> conflictOffers;
}

/// What the user can do with one conflict (SPEC §11.3: "picks a
/// direction"). [unresolved] is a choice too — the default, and what "skip"
/// means for a conflict: no action is added for the path, and the summary
/// counts it under conflicts, not skips. [keepBoth] saves the peer's file
/// beside this device's and leaves the conflict open; it is offered only
/// when both sides hold a file.
enum SyncRunConflictChoice { unresolved, keepLocal, keepRemote, keepBoth }

/// What the user can do with one proposed action: apply it as planned
/// (the default), apply its reverse — the loser's version put back,
/// offered only when the plan carries one — or leave it out.
enum SyncRunActionChoice { proposed, reversed, skipped }

/// The review's running total, for the bar under the page: how many of
/// the plan's actions will be applied ([apply], reversed ones included)
/// and how many of those are [reversed], how many are [skipped], and what
/// the conflicts come to — settled toward one side ([resolved]), copied
/// aside and left open ([keptBoth]), or simply left open ([leftOpen]).
final class SyncRunDecisionSummary {
  const SyncRunDecisionSummary({
    required this.apply,
    required this.reversed,
    required this.skipped,
    required this.resolved,
    required this.keptBoth,
    required this.leftOpen,
  });

  final int apply;
  final int reversed;
  final int skipped;
  final int resolved;
  final int keptBoth;
  final int leftOpen;
}

/// The user stopped the run. **This is not "cancelled".** Stopping means
/// `SyncRunController` stopped listening to `RunController.run()`, which
/// suspends its apply loop at an action boundary — the loop is a
/// one-at-a-time handoff, so the action whose result was last reported is
/// fully applied and committed on both sides (SPEC §7.3 makes it durable),
/// and the next one never starts. [completedActions] is how many that was.
/// The page's wording says so; "cancelled" would imply nothing happened,
/// which is false.
final class SyncRunStopped extends SyncRunPhase {
  const SyncRunStopped({required this.completedActions});

  final int completedActions;
}

/// The OS backgrounded the app mid-run and the run was suspended for it —
/// the screen went off, or the user switched away (SPEC §11.4).
///
/// Mechanically this is [SyncRunStopped]: the same suspension at the same
/// action boundary, with the same guarantee that [completedActions] are
/// applied and committed on both sides and nothing further started. It is
/// a case of its own because it is not a *terminal* phase — nobody asked
/// for it, and the run continues when the app comes back — and because the
/// page's wording and its Resume affordance follow from which of the two
/// happened. A phase that both carried a count and a "was this the user's
/// doing?" flag would be the bool-plus-nullable cluster the head's states
/// are written to avoid.
final class SyncRunPaused extends SyncRunPhase {
  const SyncRunPaused({required this.completedActions});

  final int completedActions;
}

/// The run ended without a summary: a `ReplicaConnectFailure` (SPEC §4.4)
/// before any event, or a `RunErrorEvent` — always the stream's last event.
/// [message] is the whole line to show.
final class SyncRunFailed extends SyncRunPhase {
  const SyncRunFailed(this.message);

  final String message;
}

/// The run never started because this device's replica is already locked
/// (SPEC §4.3): another `dsync` process on this machine holds it, or another
/// holder inside this one does — the Archives page deleting a log while a
/// run is on, say.
///
/// Its own phase rather than a [SyncRunFailed] carrying a sentence, because
/// the page renders it differently from a run that failed: nothing went
/// wrong here, something else is simply using the replica, and the remedy is
/// to wait rather than to investigate. Which process holds it is deliberately
/// not claimed — the lock file carries no owner, and one read out of it would
/// be stale by the time this line is on screen.
final class SyncRunReplicaBusy extends SyncRunPhase {
  const SyncRunReplicaBusy(this.message);

  /// The whole line to show — the core's own, which names the replica and
  /// the lock file that is held, so the user can see for themselves that
  /// it is the one their other run took.
  final String message;
}

/// SPEC §11.4's run header, rendered: the two locations and what the tool
/// already knows about the pair. [history] is "last synced ..." or "first
/// sync of this pair ..."; [firstSyncWarning] is SPEC §6's "a path one side
/// has never seen" note, present only when either side has no archive —
/// the flag is the data, the warning is its rendering, and the asymmetric
/// case (one side has history) is worded differently from both-empty
/// because only it is likely a mistake rather than an expected first run.
final class SyncRunHeader {
  const SyncRunHeader({
    required this.localRoot,
    required this.remoteRoot,
    required this.deviceName,
    required this.history,
    required this.firstSyncWarning,
  });

  final String localRoot;
  final String remoteRoot;
  final String deviceName;
  final String history;
  final String? firstSyncWarning;
}

/// One side's `ScanReasonTally` (SPEC §5.2), as five numbers. `metadata`
/// and `hash` both stay: a path that scans unchanged appears nowhere else
/// in the run, and which of the two branches resolved it is the only thing
/// the tally is for.
final class SyncRunScanSide {
  const SyncRunScanSide({
    required this.metadataMatched,
    required this.hashMatched,
    required this.modified,
    required this.created,
    required this.deleted,
  });

  final int metadataMatched;
  final int hashMatched;
  final int modified;
  final int created;
  final int deleted;

  int get total => metadataMatched + hashMatched + modified + created + deleted;

  /// Paths this side's scan found to differ from the last commit — the
  /// three reasons that are not "scanned unchanged" (SPEC §5.2).
  int get changed => modified + created + deleted;
}

final class SyncRunScanTally {
  const SyncRunScanTally({required this.local, required this.remote});

  final SyncRunScanSide local;
  final SyncRunScanSide remote;

  /// Every path either side's scan touched (Design C.4's one-line summary,
  /// ahead of the per-side breakdown it discloses).
  int get totalChecked => local.total + remote.total;

  /// How many of those paths scanned changed — the sum of both sides'
  /// [SyncRunScanSide.changed].
  int get totalChanged => local.changed + remote.changed;
}

/// One `Conflict` (SPEC §6), rendered: each side's status word, or "no
/// record" for a side that has never seen the path.
final class SyncRunConflictRow {
  const SyncRunConflictRow({
    required this.path,
    required this.local,
    required this.remote,
  });

  final String path;
  final String local;
  final String remote;
}

/// Which direction one planned action moves in (Design C.5): the plan
/// section it lands in, grouped so the page reads *where → what → how
/// far* rather than one flat list. [toDevice] and [toThisDevice] are a
/// `CopyAction` by which side it copies from (`RunController`'s
/// `_group`); [deletions] is a `DeleteAction` on either side — one group
/// for both, since the row's own action label already says which; and
/// [recordOnly] is a `CommitOnlyAction`, collapsed by default because
/// "same content, record only" is confirmation, not something to review.
enum SyncRunPlanGroup { toDevice, toThisDevice, deletions, recordOnly }

/// One [SyncRunPlanGroup]'s slice of the plan: which indexes into
/// [SyncRunViewState.plan] belong to it, and the bytes those rows move,
/// folded once by [SyncRunViewState.recordPlan] so a group's header count
/// never re-walks the plan to find its own rows.
final class SyncRunPlanSection {
  const SyncRunPlanSection({required this.indexes, required this.bytes});

  final List<int> indexes;
  final int bytes;

  int get count => indexes.length;
}

/// One `PlanAction`, rendered: what it does, in words, how many bytes it
/// moves, which [SyncRunPlanGroup] it falls in, and its [reversal] — `null`
/// when the plan offers none, which is also what keeps the review from
/// offering to reverse it.
final class SyncRunPlanRow {
  const SyncRunPlanRow({
    required this.path,
    required this.action,
    required this.bytes,
    required this.group,
    required this.reversal,
  });

  final String path;
  final String action;
  final int bytes;
  final SyncRunPlanGroup group;
  final SyncRunPlanReversal? reversal;
}

/// A planned action's reverse, rendered: what it does, literally — which
/// side's file is replaced or restored, never a softer "undo" — and the
/// bytes it would copy. Fixed for the plan, so it rides on the row rather
/// than being worked out per tap.
final class SyncRunPlanReversal {
  const SyncRunPlanReversal({required this.action, required this.bytes});

  final String action;
  final int bytes;
}

/// One `RunResultEvent`: [error] is `null` when the action applied.
final class SyncRunResultRow {
  const SyncRunResultRow({
    required this.path,
    required this.action,
    required this.error,
  });

  final String path;
  final String action;
  final String? error;
}

/// `RunProgressEvent`, verbatim: [completed] of [total] kept actions.
final class SyncRunProgress {
  const SyncRunProgress({required this.completed, required this.total});

  final int completed;
  final int total;
}

/// The rendered values of the Run page: the core's run updates as
/// something a widget can display (SPEC §9, §11.4).
///
/// Holds only what the page displays — see the view-state role in
/// `app_scope.dart`: strings, ints and sealed cases, never a run update, a
/// plan or a conflict. `SyncRunController` folds the stream into these
/// fields in the order SPEC §11.4 fixes — header, scan tally, skipped and
/// unreadable paths, conflicts, plan, per-action results, summary — and
/// each field is the rendering of the event that fills it. It is many
/// fields because it is one view of one run; what it is not is a set of
/// flags that must agree: the run's phase is one sealed value.
///
/// **Not every write wakes this state's listeners.** The plan and the
/// per-action results each have a listenable of their own ([planChanged],
/// [resultCell]) because the apply loop writes them once per action: a page
/// that rendered 50k plan rows from this notifier alone would rebuild them
/// for every action applied, to show one leading icon changing. The apply
/// loop's progress and counts are written silently too ([recordProgress],
/// [recordResult]) and shown when the controller says so
/// ([publishProgress]) — how often that is, is the controller's rule, not
/// this state's. The review's choices are the same pattern for a tap: one
/// cell per path ([actionDecisionCell], [conflictDecisionCell]) and one for
/// the running total ([decisionSummary]).
class SyncRunViewState extends ChangeNotifier {
  final ValueNotifier<SyncRunPhase> _phase = ValueNotifier(const SyncRunIdle());
  bool _dryRun = false;
  SyncRunHeader? _header;
  SyncRunScanTally? _scanTally;
  List<String> _skippedSymlinks = const [];
  List<String> _unreadablePaths = const [];
  List<SyncRunConflictRow> _conflicts = const [];
  final ValueNotifier<List<SyncRunPlanRow>> _plan = ValueNotifier(const []);
  Map<SyncRunPlanGroup, SyncRunPlanSection> _planSections = _emptyPlanSections;
  int _bytesToTransfer = 0;
  final Map<String, SyncRunResultRow> _results = {};
  final Map<String, ValueNotifier<SyncRunResultRow?>> _resultCells = {};
  final Map<String, SyncRunActionChoice> _actionChoices = {};
  final Map<String, ValueNotifier<SyncRunActionChoice>> _actionCells = {};
  final Map<String, SyncRunConflictChoice> _conflictChoices = {};
  final Map<String, ValueNotifier<SyncRunConflictChoice>> _conflictCells = {};
  final ValueNotifier<SyncRunDecisionSummary?> _decisionSummary = ValueNotifier(
    null,
  );
  int _appliedCount = 0;
  int _failedCount = 0;
  SyncRunProgress? _progress;
  String? _startedAt;

  SyncRunPhase get phase => _phase.value;

  /// Fires when [phase] does, and only then. The plan section — which
  /// follows [planChanged] so the apply loop cannot rebuild it — turns its
  /// rows into the review and back, and collapses its groups while
  /// applying, on the phase; this lets it without following every progress
  /// event to get it.
  Listenable get phaseChanged => _phase;

  /// SPEC §11.3 `--dry-run`: the plan is shown and nothing is applied, so
  /// the page labels the empty apply section as intended, not as a failure.
  bool get dryRun => _dryRun;

  /// `null` until the `RunReplicasEvent` — the first event of any run that
  /// got past `hello`.
  SyncRunHeader? get header => _header;

  /// `null` until both scans have completed.
  SyncRunScanTally? get scanTally => _scanTally;

  /// Symlinks the scan did not follow (SPEC §5.1), one line each, with the
  /// side and the scan's own reason. Not failures: the tool obeying §9.
  List<String> get skippedSymlinks => _skippedSymlinks;

  /// Paths a side could not read, or could not tell apart from another
  /// (SPEC §5, §16), one line each. Failures: excluded from the plan and
  /// counted in [SyncRunFinished.unreadable].
  List<String> get unreadablePaths => _unreadablePaths;

  List<SyncRunConflictRow> get conflicts => _conflicts;

  /// The reconciled plan (SPEC §6), before the presenter decides.
  List<SyncRunPlanRow> get plan => _plan.value;

  /// Fires when [plan] does, and only then. The plan arrives whole in one
  /// `RunPlanEvent`, and the apply loop that follows it reports one result
  /// per action — so a plan of 50k actions is fetched once, and a widget
  /// showing the plan under this listenable builds once per run rather than
  /// once per action. [SyncRunViewState]'s own listeners cannot say that:
  /// they also fire for the phase, the progress and every path list.
  Listenable get planChanged => _plan;

  /// [plan], sliced into its four [SyncRunPlanGroup]s (Design C.5) —
  /// folded once by [recordPlan], not re-walked per build. Every group is
  /// present, empty ones included, so a reader never null-checks a group
  /// that has nothing in it.
  Map<SyncRunPlanGroup, SyncRunPlanSection> get planSections => _planSections;

  int get bytesToTransfer => _bytesToTransfer;

  /// Each applied action's outcome, in the order they ran.
  List<SyncRunResultRow> get results => List.unmodifiable(_results.values);

  /// The result for [path], as something the row for that path can watch.
  /// One result is one row's news: [recordResult] writes it here and on
  /// [SyncRunViewState]'s listeners never, so the plan above the rows is not
  /// rebuilt for it and no row re-walks the plan to find its own result.
  ///
  /// The cell is created on first read, and only a row that is built reads
  /// one: a path the viewport has never reached costs a map entry, not a
  /// notifier. `value` is `null` until the action reports.
  ValueListenable<SyncRunResultRow?> resultCell(String path) =>
      _resultCells.putIfAbsent(path, () => ValueNotifier(_results[path]));

  /// The review's current choice for the proposed action at [path], as
  /// something that row can watch — [resultCell]'s reasoning, for a tap
  /// rather than an applied action: one choice is one row's news, so
  /// [recordActionChoice] writes it here and on this state's listeners
  /// never. Created on first read; [SyncRunActionChoice.proposed] until
  /// the user picks otherwise.
  ValueListenable<SyncRunActionChoice> actionDecisionCell(String path) =>
      _actionCells.putIfAbsent(
        path,
        () =>
            ValueNotifier(_actionChoices[path] ?? SyncRunActionChoice.proposed),
      );

  /// [actionDecisionCell], for the conflict at [path];
  /// [SyncRunConflictChoice.unresolved] until the user picks otherwise.
  ValueListenable<SyncRunConflictChoice> conflictDecisionCell(String path) =>
      _conflictCells.putIfAbsent(
        path,
        () => ValueNotifier(
          _conflictChoices[path] ?? SyncRunConflictChoice.unresolved,
        ),
      );

  /// The review's running total; `null` outside a review. Its own
  /// listenable for the same reason as the cells: the bar that shows it
  /// is all a tap should rebuild besides the tapped row.
  ValueListenable<SyncRunDecisionSummary?> get decisionSummary =>
      _decisionSummary;

  /// How many of [results] applied, and how many failed — counted as each
  /// result is recorded, so a page showing them does not re-walk [results]
  /// on every refresh.
  int get appliedCount => _appliedCount;
  int get failedCount => _failedCount;

  SyncRunProgress? get progress => _progress;

  /// The wall-clock time both sides connected, as "HH:MM"; `null` before.
  /// A fixed time, not an elapsed one: an elapsed-time line would have to
  /// repaint every second of a scan to stay true.
  String? get startedAt => _startedAt;

  /// Starts a run's rendering from nothing but its mode. `SyncRunController`
  /// only.
  ///
  /// **From nothing, literally**: every field the fold writes is cleared
  /// first, because a resumed run (`SyncRunController.resume`) renders into
  /// this same state and its scan, plan and results replace the paused
  /// attempt's — they do not continue them. The result cells are emptied
  /// rather than dropped: a row built from the previous attempt's plan may
  /// still be watching one, and a cell that kept its old value would mark
  /// an action the new plan has not started as already applied.
  void recordStart({required bool dryRun}) {
    _dryRun = dryRun;
    _header = null;
    _scanTally = null;
    _skippedSymlinks = const [];
    _unreadablePaths = const [];
    _conflicts = const [];
    _bytesToTransfer = 0;
    _results.clear();
    _appliedCount = 0;
    _failedCount = 0;
    for (final cell in _resultCells.values) {
      cell.value = null;
    }
    resetDecisions();
    _progress = null;
    _startedAt = null;
    _plan.value = const [];
    _planSections = _emptyPlanSections;
    _phase.value = const SyncRunConnecting();
    notifyListeners();
  }

  /// Moves the phase. `SyncRunController` only.
  void recordPhase(SyncRunPhase phase) {
    _phase.value = phase;
    notifyListeners();
  }

  void recordStartedAt(String time) {
    _startedAt = time;
    notifyListeners();
  }

  void recordHeader(SyncRunHeader header) {
    _header = header;
    notifyListeners();
  }

  void recordScanTally(SyncRunScanTally tally) {
    _scanTally = tally;
    notifyListeners();
  }

  void recordSkippedSymlink(String line) {
    _skippedSymlinks = List.unmodifiable([..._skippedSymlinks, line]);
    notifyListeners();
  }

  void recordUnreadablePath(String line) {
    _unreadablePaths = List.unmodifiable([..._unreadablePaths, line]);
    notifyListeners();
  }

  void recordConflict(SyncRunConflictRow row) {
    _conflicts = List.unmodifiable([..._conflicts, row]);
    notifyListeners();
  }

  /// Replaces the plan at once — one notification for one `RunPlanEvent`,
  /// on [planChanged] alone. `bytesToTransfer` and [planSections] are set
  /// first, so a listener woken by the plan reads the plan's own sum and
  /// group counts; [planSections] is one pass over [rows], not re-walked
  /// on every build that follows.
  void recordPlan(List<SyncRunPlanRow> rows, {required int bytesToTransfer}) {
    _bytesToTransfer = bytesToTransfer;
    final indexes = {
      for (final group in SyncRunPlanGroup.values) group: <int>[],
    };
    final bytes = {for (final group in SyncRunPlanGroup.values) group: 0};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      indexes[row.group]!.add(i);
      bytes[row.group] = bytes[row.group]! + row.bytes;
    }
    _planSections = {
      for (final group in SyncRunPlanGroup.values)
        group: SyncRunPlanSection(
          indexes: List.unmodifiable(indexes[group]!),
          bytes: bytes[group]!,
        ),
    };
    _plan.value = List.unmodifiable(rows);
  }

  /// One action's outcome: recorded for [results] and its counts, and
  /// pushed to that path's [resultCell] if the row for it has been built.
  /// Not on this state's listeners — see [planChanged]; the counts reach
  /// them with the next [publishProgress].
  void recordResult(SyncRunResultRow row) {
    if (_results[row.path] case final previous?) _uncount(previous);
    _results[row.path] = row;
    row.error == null ? _appliedCount++ : _failedCount++;
    _resultCells[row.path]?.value = row;
  }

  void _uncount(SyncRunResultRow row) =>
      row.error == null ? _appliedCount-- : _failedCount--;

  /// The review's choice for the proposed action at [path]: pushed to that
  /// path's [actionDecisionCell] if a row is watching it, and on this
  /// state's listeners never — see [actionDecisionCell].
  void recordActionChoice(String path, SyncRunActionChoice choice) {
    _actionChoices[path] = choice;
    _actionCells[path]?.value = choice;
  }

  /// [recordActionChoice], for the conflict at [path].
  void recordConflictChoice(String path, SyncRunConflictChoice choice) {
    _conflictChoices[path] = choice;
    _conflictCells[path]?.value = choice;
  }

  /// The review's running total, on [decisionSummary] alone.
  void recordDecisionSummary(SyncRunDecisionSummary summary) =>
      _decisionSummary.value = summary;

  /// Every path back to its default choice and no running total: a review
  /// opening, a new attempt ([recordStart]), or an answer that ignores the
  /// choices made (`SyncRunController.acceptAll`) — after which a row still
  /// showing "reversed" would claim something the core was not told. The
  /// cells are reset rather than dropped, as [recordStart] resets
  /// [resultCell]s: a built row may be watching one.
  void resetDecisions() {
    _actionChoices.clear();
    _conflictChoices.clear();
    for (final cell in _actionCells.values) {
      cell.value = SyncRunActionChoice.proposed;
    }
    for (final cell in _conflictCells.values) {
      cell.value = SyncRunConflictChoice.unresolved;
    }
    _decisionSummary.value = null;
  }

  /// The apply loop's latest progress, written without waking anyone: see
  /// [publishProgress].
  void recordProgress(SyncRunProgress progress) {
    _progress = progress;
  }

  /// Shows what [recordProgress] and [recordResult] wrote since the last
  /// time. A phase change shows it too.
  void publishProgress() => notifyListeners();

  /// Disposes the notifiers this state hands out — the phase's, the plan's,
  /// and the cells built rows are watching — so a write after the page left is an
  /// assertion failure in the page that made it, as it is for [this].
  @override
  void dispose() {
    _phase.dispose();
    _plan.dispose();
    for (final cell in _resultCells.values) {
      cell.dispose();
    }
    for (final cell in _actionCells.values) {
      cell.dispose();
    }
    for (final cell in _conflictCells.values) {
      cell.dispose();
    }
    _decisionSummary.dispose();
    super.dispose();
  }
}

/// Every [SyncRunPlanGroup] with nothing in it — [recordStart]'s reset and
/// the state a run renders before its first plan arrives.
final Map<SyncRunPlanGroup, SyncRunPlanSection> _emptyPlanSections = {
  for (final group in SyncRunPlanGroup.values)
    group: const SyncRunPlanSection(indexes: [], bytes: 0),
};
