import 'package:flutter/foundation.dart';

import '../../core_link/models/action_choice.dart';
import '../../core_link/models/conflict_choice.dart';
import '../../core_link/models/root_kind.dart';
import '../../core_link/models/run_standing.dart';

/// Where the run stands. Sealed, for the reason `PairOutcome` and
/// `AppBootstrap` give: a phase with the wrong payload — "finished" with no
/// counts, "stopped" with no number — cannot be constructed, and the page
/// switches over every case.
sealed class SyncRunPhase {
  const SyncRunPhase();
}

/// No view of the run has arrived yet.
final class SyncRunIdle extends SyncRunPhase {
  const SyncRunIdle();
}

/// The core is resolving the run and connecting both sides.
final class SyncRunConnecting extends SyncRunPhase {
  const SyncRunConnecting();
}

/// Both sides are connected and the core is scanning them and reconciling
/// the two scans (SPEC §5, §6): the header, the tally, the path lists and
/// the plan fill in as the views bring them. A dry run stays here until it
/// ends — it never applies.
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

/// The run completed with its summary (SPEC §11.4). The five counts
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

  @override
  bool operator ==(Object other) =>
      other is SyncRunFinished &&
      other.applied == applied &&
      other.skipped == skipped &&
      other.conflicts == conflicts &&
      other.failed == failed &&
      other.unreadable == unreadable;

  @override
  int get hashCode =>
      Object.hash(applied, skipped, conflicts, failed, unreadable);
}

/// A profile of several entries ran to its end, and some did not sync:
/// [issues] is one line per such entry, naming it and saying why. Not
/// over: a resume runs every entry again, the synced ones as no-ops.
final class SyncRunFinishedWithIssues extends SyncRunPhase {
  const SyncRunFinishedWithIssues(this.issues);

  final List<String> issues;

  @override
  bool operator ==(Object other) =>
      other is SyncRunFinishedWithIssues && listEquals(other.issues, issues);

  @override
  int get hashCode => Object.hashAll(issues);
}

/// The core has handed the plan to the review and waits on its answer
/// (SPEC §11.3): the page's own plan and conflict rows turn into the
/// review, each with its control. What each conflict offers rides on its
/// row ([SyncRunConflictRow.offered]). The current choices are not here:
/// each lives in its row's cell ([SyncRunViewState.actionDecisionCell],
/// [SyncRunViewState.conflictDecisionCell]) and the running total in
/// [SyncRunViewState.decisionSummary], so a tap rebuilds one row and the
/// bar under the page, never the phase and every row with it.
final class SyncRunAwaitingDecisions extends SyncRunPhase {
  const SyncRunAwaitingDecisions();
}

/// SPEC §10's delete guard stopped the run between the review and the
/// apply: what was decided deletes most of a side's files — a folder
/// emptied or moved by accident, the wrong folder picked — and the core
/// waits, holding both locks, for the user to say whether to go on. [sides]
/// names each side it tripped on. Nothing has been applied yet.
final class SyncRunConfirmingDeletes extends SyncRunPhase {
  const SyncRunConfirmingDeletes(this.sides);

  final List<SyncRunDeletesOnSide> sides;

  @override
  bool operator ==(Object other) =>
      other is SyncRunConfirmingDeletes && listEquals(other.sides, sides);

  @override
  int get hashCode => Object.hashAll(sides);
}

/// One side of [SyncRunConfirmingDeletes]: the run deletes [deletes] of the
/// [archived] files the last sync saw in [root], which is on [where] —
/// "this device" or "the remote". [root] is the running entry's, `null`
/// when the core has not said which entry runs.
final class SyncRunDeletesOnSide {
  const SyncRunDeletesOnSide({
    required this.where,
    required this.root,
    required this.deletes,
    required this.archived,
  });

  final String where;
  final String? root;
  final int deletes;
  final int archived;

  @override
  bool operator ==(Object other) =>
      other is SyncRunDeletesOnSide &&
      other.where == where &&
      other.root == root &&
      other.deletes == deletes &&
      other.archived == archived;

  @override
  int get hashCode => Object.hash(where, root, deletes, archived);
}

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

  @override
  bool operator ==(Object other) =>
      other is SyncRunDecisionSummary &&
      other.apply == apply &&
      other.reversed == reversed &&
      other.skipped == skipped &&
      other.resolved == resolved &&
      other.keptBoth == keptBoth &&
      other.leftOpen == leftOpen;

  @override
  int get hashCode =>
      Object.hash(apply, reversed, skipped, resolved, keptBoth, leftOpen);
}

/// The user stopped the run. **This is not "cancelled".** The core's
/// graceful stop starts nothing further, lets what is in flight finish and
/// commit on both sides (SPEC §7.3 makes it durable), and ends the run;
/// [completedActions] is how many actions had completed. The page's
/// wording says so; "cancelled" would imply nothing happened, which is
/// false.
final class SyncRunStopped extends SyncRunPhase {
  const SyncRunStopped({required this.completedActions});

  final int completedActions;

  @override
  bool operator ==(Object other) =>
      other is SyncRunStopped && other.completedActions == completedActions;

  @override
  int get hashCode => completedActions.hashCode;
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

  @override
  bool operator ==(Object other) =>
      other is SyncRunPaused && other.completedActions == completedActions;

  @override
  int get hashCode => completedActions.hashCode;
}

/// The run ended without a summary: a side could not be connected (SPEC
/// §4.4), the core reported a failure, or the user declined the deletions
/// SPEC §10's guard asked about. [message] is the whole line to show.
final class SyncRunFailed extends SyncRunPhase {
  const SyncRunFailed(this.message);

  final String message;

  @override
  bool operator ==(Object other) =>
      other is SyncRunFailed && other.message == message;

  @override
  int get hashCode => message.hashCode;
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

  @override
  bool operator ==(Object other) =>
      other is SyncRunReplicaBusy && other.message == message;

  @override
  int get hashCode => message.hashCode;
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
    required this.history,
    required this.firstSyncWarning,
  });

  final String localRoot;
  final String remoteRoot;
  final String history;
  final String? firstSyncWarning;
}

/// One side's `ScanReasonTally` (SPEC §5.2), as five numbers, and the
/// core's [total] of paths it checked. `metadata` and `hash` both stay: a
/// path that scans unchanged appears nowhere else in the run, and which of
/// the two branches resolved it is the only thing the tally is for.
final class SyncRunScanSide {
  const SyncRunScanSide({
    required this.metadataMatched,
    required this.hashMatched,
    required this.modified,
    required this.created,
    required this.deleted,
    required this.total,
  });

  final int metadataMatched;
  final int hashMatched;
  final int modified;
  final int created;
  final int deleted;
  final int total;
}

/// Both sides' tallies, and the core's counts across them: every path
/// either side's scan touched ([totalChecked], Design C.4's one-line
/// summary, ahead of the per-side breakdown it discloses) and how many of
/// those it did not find unchanged ([totalChanged]).
final class SyncRunScanTally {
  const SyncRunScanTally({
    required this.local,
    required this.remote,
    required this.totalChecked,
    required this.totalChanged,
  });

  final SyncRunScanSide local;
  final SyncRunScanSide remote;
  final int totalChecked;
  final int totalChanged;
}

/// One `Conflict` (SPEC §6), rendered: each side's status, and its file
/// where it has one; its [index] in the plan's conflicts, which a choice
/// names; and what the core [offered] for it — a side with no record of
/// the path cannot be the one kept, and keeping both needs a file on both
/// sides. The offer is the review's to use, and only the review's.
final class SyncRunConflictRow {
  const SyncRunConflictRow({
    required this.index,
    required this.path,
    required this.local,
    required this.remote,
    required this.offered,
  });

  final int index;
  final String path;
  final SyncRunConflictSide local;
  final SyncRunConflictSide remote;
  final List<ConflictChoice> offered;
}

/// One side of a conflict: its [status], and — for a side with a file on
/// disk — when that file was last modified ("25 Sep 14:03", by that side's
/// own clock, shown in this device's time zone) and its size. A deleted
/// side, or one with no record, has no [file].
final class SyncRunConflictSide {
  const SyncRunConflictSide(this.status, {this.file});

  final SyncRunSideStatus status;
  final ({String modified, int bytes})? file;
}

/// One side's status for a conflicting path (SPEC §5.2), as the page draws
/// it: an icon and a word per side. [interrupted] is a write that never
/// committed, with or without a file left behind (SPEC §7.6); [none] is a
/// side with no record of the path.
enum SyncRunSideStatus {
  unchanged,
  created,
  modified,
  deleted,
  interrupted,
  none,
}

/// Which direction one planned action moves in (Design C.5): the plan
/// section it lands in, grouped so the page reads *where → what → how
/// far* rather than one flat list. [toDevice] and [toThisDevice] are a
/// `CopyAction` by which side it copies from (`SyncRunController`'s
/// `_group`); [deletions] is a `DeleteAction` on either side — one group
/// for both, since the row's own action label already says which; and
/// [recordOnly] is a `CommitOnlyAction`, collapsed by default because
/// "same content, record only" is confirmation, not something to review.
enum SyncRunPlanGroup { toDevice, toThisDevice, deletions, recordOnly }

/// One [SyncRunPlanGroup]'s slice of the plan: which indexes into
/// [SyncRunViewState.plan] belong to it, folded once per plan by
/// [SyncRunViewState.show] so a group's header count never re-walks the
/// plan to find its own rows, and the bytes the core counts those rows
/// moving.
final class SyncRunPlanSection {
  const SyncRunPlanSection({required this.indexes, required this.bytes});

  final List<int> indexes;
  final int bytes;

  int get count => indexes.length;
}

/// One `PlanAction`, rendered: its [index] in the plan, which a choice
/// names; what it does, in words; how many bytes it moves; which
/// [SyncRunPlanGroup] it falls in; and its [reversal] — `null` when the
/// core offers none, which is also what keeps the review from offering to
/// reverse it.
final class SyncRunPlanRow {
  const SyncRunPlanRow({
    required this.index,
    required this.path,
    required this.action,
    required this.bytes,
    required this.group,
    required this.reversal,
  });

  final int index;
  final String path;
  final String action;
  final int bytes;
  final SyncRunPlanGroup group;
  final SyncRunPlanReversal? reversal;

  @override
  bool operator ==(Object other) =>
      other is SyncRunPlanRow &&
      other.index == index &&
      other.path == path &&
      other.action == action &&
      other.bytes == bytes &&
      other.group == group &&
      other.reversal == reversal;

  @override
  int get hashCode => Object.hash(index, path, action, bytes, group, reversal);
}

/// A planned action's reverse, rendered: what it does, literally — which
/// side's file is replaced or restored, never a softer "undo" — and the
/// bytes it would copy. Fixed for the plan, so it rides on the row rather
/// than being worked out per tap.
final class SyncRunPlanReversal {
  const SyncRunPlanReversal({required this.action, required this.bytes});

  final String action;
  final int bytes;

  @override
  bool operator ==(Object other) =>
      other is SyncRunPlanReversal &&
      other.action == action &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(action, bytes);
}

/// One action's reported outcome: [error] is `null` when it applied.
final class SyncRunResultRow {
  const SyncRunResultRow({
    required this.path,
    required this.action,
    required this.error,
  });

  final String path;
  final String action;
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is SyncRunResultRow &&
      other.path == path &&
      other.action == action &&
      other.error == error;

  @override
  int get hashCode => Object.hash(path, action, error);
}

/// The apply's progress, verbatim: [completed] of [total] kept actions.
final class SyncRunProgress {
  const SyncRunProgress({required this.completed, required this.total});

  final int completed;
  final int total;
}

/// One entry of the profile's run, as the header strip lists it above the
/// current entry's own plan (D10): its kind and both roots as typed, and
/// how it stands.
final class SyncRunEntryRow {
  const SyncRunEntryRow({
    required this.kind,
    required this.localRoot,
    required this.remoteRoot,
    required this.status,
  });

  final RootKind kind;
  final String localRoot;
  final String remoteRoot;
  final SyncRunEntryStatus status;
}

/// Where one entry of the run stands. Sealed, for the reason [SyncRunPhase]
/// is: [SyncRunEntrySkipped] and [SyncRunEntryFailed] each carry the line
/// that says why, and a status with the wrong payload cannot be
/// constructed.
sealed class SyncRunEntryStatus {
  const SyncRunEntryStatus();
}

/// Not reached yet — waits behind an earlier entry still running.
final class SyncRunEntryPending extends SyncRunEntryStatus {
  const SyncRunEntryPending();
}

/// The entry the current plan and tallies describe.
final class SyncRunEntryRunning extends SyncRunEntryStatus {
  const SyncRunEntryRunning();
}

final class SyncRunEntrySynced extends SyncRunEntryStatus {
  const SyncRunEntrySynced();
}

/// Not there to sync — a missing or wrong-kind root, a kind mismatch;
/// nothing was written for it.
final class SyncRunEntrySkipped extends SyncRunEntryStatus {
  const SyncRunEntrySkipped(this.reason);

  final String reason;
}

/// Ran and reported an error — a refused connection, a lock held elsewhere.
final class SyncRunEntryFailed extends SyncRunEntryStatus {
  const SyncRunEntryFailed(this.message);

  final String message;
}

/// The run stopped, or the user stopped it, before this entry started.
final class SyncRunEntryNotRun extends SyncRunEntryStatus {
  const SyncRunEntryNotRun();
}

/// The rendered values of the Run page: the latest view of the run the
/// core sent, as something a widget can display (SPEC §9, §11.4).
///
/// Holds only what the page displays — see the view-state role in
/// `app_scope.dart`: strings, ints and sealed cases. Every field is written
/// by [show], once per view the core sends, and every one is that view's
/// rendering: the phase, the review and the outcome are the core's
/// decisions, and nothing here folds one view into the next.
///
/// **Not every change wakes every listener.** The plan and the per-path
/// rows each have a listenable of their own ([planChanged], [resultCell],
/// [actionDecisionCell], [conflictDecisionCell], [decisionSummary]), set
/// only when their value changes: a page that rendered 50k plan rows from
/// this notifier alone would rebuild them for every view the apply loop
/// brings, to show one leading icon changing, and a tap in the review is
/// one row's news and the bar's. The phase has its own too
/// ([phaseChanged]), which fires only when the phase does.
class SyncRunViewState extends ChangeNotifier {
  final ValueNotifier<SyncRunPhase> _phase = ValueNotifier(const SyncRunIdle());
  RunStanding? _standing;
  bool _dryRun = false;
  SyncRunHeader? _header;
  String? _diagnosticsRoot;
  SyncRunScanTally? _scanTally;
  List<String> _skippedSymlinks = const [];
  List<String> _unreadablePaths = const [];
  List<SyncRunConflictRow> _conflicts = const [];
  final ValueNotifier<List<SyncRunPlanRow>> _plan = ValueNotifier(const []);
  Map<SyncRunPlanGroup, SyncRunPlanSection> _planSections = _emptyPlanSections;
  int _bytesToTransfer = 0;
  Map<String, SyncRunResultRow> _results = const {};
  final Map<String, ValueNotifier<SyncRunResultRow?>> _resultCells = {};
  List<ActionChoice> _actionChoices = const [];
  final Map<int, ValueNotifier<ActionChoice>> _actionCells = {};
  List<ConflictChoice> _conflictChoices = const [];
  final Map<int, ValueNotifier<ConflictChoice>> _conflictCells = {};
  final ValueNotifier<SyncRunDecisionSummary?> _decisionSummary = ValueNotifier(
    null,
  );
  int _appliedCount = 0;
  int _failedCount = 0;
  SyncRunProgress? _progress;
  String? _startedAt;
  List<SyncRunEntryRow> _entries = const [];
  int? _currentEntry;

  SyncRunPhase get phase => _phase.value;

  /// Fires when [phase] does, and only then. The plan section — which
  /// follows [planChanged] so the apply loop cannot rebuild it — turns its
  /// rows into the review and back, and collapses its groups while
  /// applying, on the phase; this lets it without following every view to
  /// get it.
  Listenable get phaseChanged => _phase;

  /// The core's word on whether the run is live: connecting to applying.
  /// The screen is held, leaving asks first and probes wait while it is.
  /// `false` before the core has said anything.
  bool get live => _standing == RunStanding.live;

  /// Whether the core offers to run it again: paused, or ended short.
  bool get resumable => _standing == RunStanding.resumable;

  /// SPEC §11.3 `--dry-run`: the plan is shown and nothing is applied, so
  /// the page labels the empty apply section as intended, not as a failure.
  bool get dryRun => _dryRun;

  /// `null` until both sides' `hello` is in.
  SyncRunHeader? get header => _header;

  /// The folder on this device the Diagnostics page probes: the running
  /// entry's (a file entry's own folder); `null` until the core has listed
  /// the entries.
  String? get diagnosticsRoot => _diagnosticsRoot;

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

  /// The reconciled plan (SPEC §6).
  List<SyncRunPlanRow> get plan => _plan.value;

  /// Fires when [plan] does, and only then: the plan is fixed once made,
  /// so a plan of 50k actions is rendered once, and a widget showing it
  /// under this listenable builds once per attempt rather than once per
  /// view. [SyncRunViewState]'s own listeners cannot say that: they fire
  /// for every view.
  Listenable get planChanged => _plan;

  /// [plan], sliced into its four [SyncRunPlanGroup]s (Design C.5) —
  /// folded once per plan, not re-walked per build. Every group is
  /// present, empty ones included, so a reader never null-checks a group
  /// that has nothing in it.
  Map<SyncRunPlanGroup, SyncRunPlanSection> get planSections => _planSections;

  int get bytesToTransfer => _bytesToTransfer;

  /// The result for [path], as something the row for that path can watch.
  /// One result is one row's news: [show] writes it here when it changes
  /// and nowhere else, so the plan above the rows is not rebuilt for it and
  /// no row re-walks the plan to find its own result.
  ///
  /// The cell is created on first read, and only a row that is built reads
  /// one: a path the viewport has never reached costs a map entry, not a
  /// notifier. `value` is `null` until the action reports.
  ValueListenable<SyncRunResultRow?> resultCell(String path) =>
      _resultCells.putIfAbsent(path, () => ValueNotifier(_results[path]));

  /// The review's current choice for [row], as something that row can
  /// watch — [resultCell]'s reasoning, for a tap rather than an applied
  /// action. Created on first read, from the choice the core sent for the
  /// row.
  ValueListenable<ActionChoice> actionDecisionCell(SyncRunPlanRow row) =>
      _actionCells.putIfAbsent(
        row.index,
        () => ValueNotifier(_actionChoices[row.index]),
      );

  /// [actionDecisionCell], for the conflict [row].
  ValueListenable<ConflictChoice> conflictDecisionCell(
    SyncRunConflictRow row,
  ) => _conflictCells.putIfAbsent(
    row.index,
    () => ValueNotifier(_conflictChoices[row.index]),
  );

  /// The review's running total; `null` outside a review. Its own
  /// listenable for the same reason as the cells: the bar that shows it
  /// is all a tap should rebuild besides the tapped row.
  ValueListenable<SyncRunDecisionSummary?> get decisionSummary =>
      _decisionSummary;

  /// How many reported outcomes applied, and how many failed.
  int get appliedCount => _appliedCount;
  int get failedCount => _failedCount;

  SyncRunProgress? get progress => _progress;

  /// The wall-clock time both sides connected, as "HH:MM"; `null` before.
  /// A fixed time, not an elapsed one: an elapsed-time line would have to
  /// repaint every second of a scan to stay true.
  String? get startedAt => _startedAt;

  /// The profile's entries, in the order they run; empty until the target
  /// resolves. The page draws this list above the current entry's plan only
  /// when there is more than one (D10) — a single-entry run reads exactly
  /// as it always has.
  List<SyncRunEntryRow> get entries => _entries;

  /// Which of [entries] the plan and tallies describe; `null` before the
  /// first one starts.
  int? get currentEntry => _currentEntry;

  /// Renders one view of the run, whole. `SyncRunController` only.
  ///
  /// Every field is replaced — a resumed attempt's view shows nothing of
  /// the attempt before it — but a listenable is set only when its value
  /// changed, and the cells are written rather than dropped: a built row
  /// may be watching one. A decision cell past the end of this view's rows
  /// belongs to a row on its way out, and keeps what it showed.
  ///
  /// [actionChoices] and [conflictChoices] are the core's, one per row of
  /// [plan] and [conflicts], in their order; [copyBytes] is what the core
  /// counts the plan's copies moving each way.
  void show({
    required SyncRunPhase phase,
    required RunStanding? standing,
    required bool dryRun,
    required String? startedAt,
    required SyncRunHeader? header,
    required String? diagnosticsRoot,
    required SyncRunScanTally? scanTally,
    required List<String> skippedSymlinks,
    required List<String> unreadablePaths,
    required List<SyncRunConflictRow> conflicts,
    required List<SyncRunPlanRow> plan,
    required ({int toDevice, int toThisDevice}) copyBytes,
    required int bytesToTransfer,
    required Map<String, SyncRunResultRow> results,
    required List<ActionChoice> actionChoices,
    required List<ConflictChoice> conflictChoices,
    required SyncRunDecisionSummary? decisionSummary,
    required SyncRunProgress? progress,
    required int appliedCount,
    required int failedCount,
    required List<SyncRunEntryRow> entries,
    required int? currentEntry,
  }) {
    _standing = standing;
    _dryRun = dryRun;
    _startedAt = startedAt;
    _header = header;
    _diagnosticsRoot = diagnosticsRoot;
    _entries = List.unmodifiable(entries);
    _currentEntry = currentEntry;
    _scanTally = scanTally;
    _skippedSymlinks = List.unmodifiable(skippedSymlinks);
    _unreadablePaths = List.unmodifiable(unreadablePaths);
    _conflicts = List.unmodifiable(conflicts);
    _bytesToTransfer = bytesToTransfer;
    _progress = progress;
    _appliedCount = appliedCount;
    _failedCount = failedCount;
    _results = results;
    for (final MapEntry(key: path, value: cell) in _resultCells.entries) {
      cell.value = results[path];
    }
    _actionChoices = List.unmodifiable(actionChoices);
    for (final MapEntry(key: index, value: cell) in _actionCells.entries) {
      if (index < actionChoices.length) cell.value = actionChoices[index];
    }
    _conflictChoices = List.unmodifiable(conflictChoices);
    for (final MapEntry(key: index, value: cell) in _conflictCells.entries) {
      if (index < conflictChoices.length) cell.value = conflictChoices[index];
    }
    _decisionSummary.value = decisionSummary;
    if (!listEquals(plan, _plan.value)) _recordPlan(plan, copyBytes);
    _phase.value = phase;
    notifyListeners();
  }

  /// Replaces the plan — one notification, on [planChanged] alone.
  /// [planSections] is set first, so a listener woken by the plan reads
  /// the plan's own group counts; it is one pass over [rows], not
  /// re-walked on every build that follows.
  void _recordPlan(
    List<SyncRunPlanRow> rows,
    ({int toDevice, int toThisDevice}) copyBytes,
  ) {
    final indexes = {
      for (final group in SyncRunPlanGroup.values) group: <int>[],
    };
    for (var i = 0; i < rows.length; i++) {
      indexes[rows[i].group]!.add(i);
    }
    _planSections = {
      for (final group in SyncRunPlanGroup.values)
        group: SyncRunPlanSection(
          indexes: List.unmodifiable(indexes[group]!),
          bytes: switch (group) {
            SyncRunPlanGroup.toDevice => copyBytes.toDevice,
            SyncRunPlanGroup.toThisDevice => copyBytes.toThisDevice,
            SyncRunPlanGroup.deletions || SyncRunPlanGroup.recordOnly => 0,
          },
        ),
    };
    _plan.value = List.unmodifiable(rows);
  }

  /// Disposes the notifiers this state hands out — the phase's, the plan's,
  /// and the cells built rows are watching — so a write after the page left
  /// is an assertion failure in the page that made it, as it is for [this].
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

/// Every [SyncRunPlanGroup] with nothing in it — the state a run renders
/// before its plan is made.
final Map<SyncRunPlanGroup, SyncRunPlanSection> _emptyPlanSections = {
  for (final group in SyncRunPlanGroup.values)
    group: const SyncRunPlanSection(indexes: [], bytes: 0),
};
