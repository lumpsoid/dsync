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

/// `ReplicaConnector.connect` is in flight: no `RunEvent` can have arrived.
final class SyncRunConnecting extends SyncRunPhase {
  const SyncRunConnecting();
}

/// Both sides are connected and `RunController.run()` is being listened
/// to; the other fields fill in as its events arrive.
final class SyncRunRunning extends SyncRunPhase {
  const SyncRunRunning();
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
/// its answer (SPEC §11.3): the conflict sheet is up. The rows are the
/// user's choices so far, already rendered — the sheet reads them and calls
/// `SyncRunController`'s input methods, never a `Plan`. They live on the
/// phase rather than beside it because a set of decisions only exists
/// while something is being decided; each input replaces the whole case.
/// [conflicts] come first, then [actions]: the order SPEC §11.3 fixes and
/// the order the events arrived in.
final class SyncRunAwaitingDecisions extends SyncRunPhase {
  const SyncRunAwaitingDecisions({
    required this.conflicts,
    required this.actions,
  });

  final List<SyncRunConflictDecision> conflicts;
  final List<SyncRunActionDecision> actions;

  /// What the proposed actions would move (SPEC §10) — the same sum as
  /// `SyncRunViewState.bytesToTransfer`, over the same actions. The sheet
  /// shows it while the page's plan section is hidden behind the sheet, so
  /// the size of what is being decided is on screen with the decisions.
  int get bytesToTransfer => actions.fold(0, (total, row) => total + row.bytes);
}

/// What the user can do with one conflict (SPEC §11.3: "picks a
/// direction"). [unresolved] is a choice too — the default, and what "skip"
/// means for a conflict: no action is added for the path, and the summary
/// counts it under conflicts, not skips.
enum SyncRunConflictChoice { unresolved, keepLocal, keepRemote }

/// One `Conflict` in the sheet: the same two status words as
/// [SyncRunConflictRow], the current [choice], and which choices are
/// [offered] — a side with no record of the path cannot be the one kept,
/// so a one-sided conflict offers only the other direction (the CLI's
/// prompt makes the same call).
final class SyncRunConflictDecision {
  const SyncRunConflictDecision({
    required this.path,
    required this.local,
    required this.remote,
    required this.choice,
    required this.offered,
  });

  final String path;
  final String local;
  final String remote;
  final SyncRunConflictChoice choice;
  final List<SyncRunConflictChoice> offered;
}

/// One proposed `PlanAction` in the sheet: [kept] is `false` once the user
/// skipped it.
final class SyncRunActionDecision {
  const SyncRunActionDecision({
    required this.path,
    required this.action,
    required this.bytes,
    required this.kept,
  });

  final String path;
  final String action;
  final int bytes;
  final bool kept;
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
}

final class SyncRunScanTally {
  const SyncRunScanTally({required this.local, required this.remote});

  final SyncRunScanSide local;
  final SyncRunScanSide remote;
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

/// One `PlanAction`, rendered: what it does, in words, and how many bytes
/// it moves.
final class SyncRunPlanRow {
  const SyncRunPlanRow({
    required this.path,
    required this.action,
    required this.bytes,
  });

  final String path;
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

/// The rendered values of the Run page: a `dsync_core` run's `RunEvent`s as
/// something a widget can display (SPEC §9, §11.4).
///
/// Holds only what the page displays — see the view-state role in
/// `app_scope.dart`: strings, ints and sealed cases, never a `RunEvent`, a
/// `Plan` or a `Conflict`. `SyncRunController` folds the stream into these
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
/// for every action applied, to show one leading icon changing.
class SyncRunViewState extends ChangeNotifier {
  final ValueNotifier<SyncRunPhase> _phase = ValueNotifier(const SyncRunIdle());
  bool _dryRun = false;
  SyncRunHeader? _header;
  SyncRunScanTally? _scanTally;
  List<String> _skippedSymlinks = const [];
  List<String> _unreadablePaths = const [];
  List<SyncRunConflictRow> _conflicts = const [];
  final ValueNotifier<List<SyncRunPlanRow>> _plan = ValueNotifier(const []);
  int _bytesToTransfer = 0;
  final Map<String, SyncRunResultRow> _results = {};
  final Map<String, ValueNotifier<SyncRunResultRow?>> _resultCells = {};
  SyncRunProgress? _progress;

  SyncRunPhase get phase => _phase.value;

  /// Fires when [phase] does, and only then. The body hides the sections
  /// the decision sheet already shows, and the plan section — which follows
  /// [planChanged] so the apply loop cannot rebuild it — needs that switch
  /// without following every progress event to get it.
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

  SyncRunProgress? get progress => _progress;

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
    for (final cell in _resultCells.values) {
      cell.value = null;
    }
    _progress = null;
    _plan.value = const [];
    _phase.value = const SyncRunConnecting();
    notifyListeners();
  }

  /// Moves the phase. `SyncRunController` only.
  void recordPhase(SyncRunPhase phase) {
    _phase.value = phase;
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
  /// on [planChanged] alone. `bytesToTransfer` is set first, so a listener
  /// woken by the plan reads the plan's own sum.
  void recordPlan(List<SyncRunPlanRow> rows, {required int bytesToTransfer}) {
    _bytesToTransfer = bytesToTransfer;
    _plan.value = List.unmodifiable(rows);
  }

  /// One action's outcome: recorded for [results], and pushed to that
  /// path's [resultCell] if the row for it has been built. Deliberately not
  /// on this state's listeners — see [planChanged].
  void recordResult(SyncRunResultRow row) {
    _results[row.path] = row;
    _resultCells[row.path]?.value = row;
  }

  void recordProgress(SyncRunProgress progress) {
    _progress = progress;
    notifyListeners();
  }

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
    super.dispose();
  }
}
