import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_link/models/compared_side.dart';
import '../../core_link/models/conflict_choice.dart';
import '../../core_link/models/replica_side.dart';
import '../../core_link/models/row_ref.dart';
import '../../destructive_confirm_dialog.dart';
import '../../format_bytes.dart';
import '../../format_count.dart';
import '../../format_path.dart';
import '../../path_text.dart';
import '../../pop_on_escape.dart';
import '../../readable_width.dart';
import '../../run_request.dart';
import '../file_diff/file_diff_page.dart';
import '../file_diff/file_diff_view_state.dart';
import 'run_controller.dart';
import 'run_layout.dart';
import 'run_plan_section.dart';
import 'run_review_cursor.dart';
import 'run_review_keyboard.dart';
import 'run_scope.dart';
import 'run_timings_sheet.dart';
import 'run_view_state.dart';

/// The Run page: drive a run for [request] and render the core's latest
/// view of it (SPEC §9, §11.4). Widgets only, per the page role in
/// `app_scope.dart`: it switches over [SyncRunPhase] and lists the rendered
/// rows in the order the core sent them.
///
/// **Owns its controller.** This page takes `runScope.create()` — never the
/// cached `controller` every other page reads — and disposes it in
/// [State.dispose]; the scope contract in `app_scope.dart` says why:
/// two runs must never share a session, and a view arriving late from a
/// finished run must not write into a view state a later page tore down.
///
/// **The lifecycle seam lives here.** This page owns the
/// `AppLifecycleListener` that pauses the run when the app is backgrounded
/// and resumes it when it comes back — the two input methods
/// `SyncRunController` exposes for it, whose doc comment carries the whole
/// rationale: why a backgrounded run is torn down rather than left to the
/// far end's heartbeat deadline, what a resume does and does not carry
/// over, and why only `paused` may trigger it. The page is the owner
/// because the binding is a widget-tree fact and a controller that reached
/// for `WidgetsBinding.instance` itself could not be tested without one.
///
/// `onPause` and nothing above it — not `onInactive`, not `onHide`. A
/// notification shade, a permission dialog and an incoming call are
/// `inactive`; pausing for those would stop a run that was never in
/// danger. The platform walks every state in between on the way down and
/// back up (`inactive`, `hidden`, then `paused`), so these two callbacks
/// see a backgrounding and a return, never a jump.
///
/// **Resuming is automatic, and the button is the fallback.** `onResume`
/// continues a paused run without asking, because the user did not ask for
/// the pause either. A run that ended in failure — including one whose
/// pause did not finish before the OS froze the process, which surfaces as
/// the far end's heartbeat deadline — is not resumed behind their back:
/// that one offers Resume as a button and waits to be told.
///
/// [onDone] is the navigation seam: it fires when the user taps Done on a
/// finished, stopped or failed run, and the entrypoint decides where that
/// leads. This page holds no `Navigator` of its own.
///
/// **Its width is read once, here.** The page is pushed over the app
/// shell, so it decides its own [RunLayout] from the window's width and
/// hands the plain value down: the plan as a table on a wide window, the
/// phone's rows otherwise, and the page's column to match. The Timings
/// report is handed the width itself, to choose a sheet or a dialog by the
/// shell's breakpoint ([showRunTimings]).
///
/// **The review works from the keyboard** ([RunReviewKeyboard]), and Esc
/// anywhere on the page does what the system back does ([PopOnEscape]) —
/// through the same [PopScope], so a live run still asks before it is
/// left.
class RunPage extends StatefulWidget {
  const RunPage({super.key, required this.request, required this.onDone});

  /// What to sync, built by the Run setup page.
  final RunRequest request;

  /// Called when the run is over and the user is done reading it.
  final VoidCallback onDone;

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  final SyncRunController _controller = runScope.create();

  /// The app's lifecycle, as the two calls this page makes on it. Held so
  /// it is disposed with the page: a listener that outlived the run it
  /// pauses would pause a controller nobody owns any more.
  late final AppLifecycleListener _lifecycle;

  /// What the body's plan section and the review bar follow: the plan
  /// itself (the bar's size warning is fixed with it), and the phase
  /// that turns its rows into the review and collapses them while applying. Built once and not per
  /// build, so a rebuild does not swap the section's listeners.
  late final Listenable _planSection = Listenable.merge([
    _controller.state.planChanged,
    _controller.state.phaseChanged,
  ]);

  /// What the top block (header, counts row, scan tally, path lists,
  /// conflicts) follows: the view state itself, which every view the core
  /// sends wakes. The view state, not a merge: its `show` sets the plan's
  /// group counts before it notifies.
  Listenable get _topSection => _controller.state;

  /// The review's keyboard cursor, and which plan groups are open — the
  /// page's, because the cursor walks the rows the open groups show.
  final ReviewCursor _cursor = ReviewCursor();
  final PlanDisclosures _disclosures = PlanDisclosures();

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onPause: _controller.pause,
      onResume: _controller.resumeFromBackground,
    );
    _controller.start(widget.request);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _cursor.dispose();
    _disclosures.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirmAbort() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const _AbortDialog(),
    );
    if (!(confirmed ?? false)) return;
    if (!mounted) return;
    // Nothing to stop first: popping disposes the controller, which cancels
    // the subscription and releases the run's locks (see its `dispose`).
    Navigator.of(context).pop();
  }

  void _compareConflict(SyncRunConflictRow row) => _openComparison(
    ConflictRowRef(row.index),
    row.path,
    oldSide: ComparedSide(ReplicaSide.a, row.local.file?.bytes),
    newSide: ComparedSide(ReplicaSide.b, row.remote.file?.bytes),
  );

  /// A copy's source is the new side and its destination the old one; the
  /// destination has a file only where the core offers a reversal.
  void _comparePlan(SyncRunPlanRow row) {
    final source = row.group == SyncRunPlanGroup.toDevice
        ? ReplicaSide.a
        : ReplicaSide.b;
    _openComparison(
      ActionRowRef(row.index),
      row.path,
      oldSide: ComparedSide(
        source == ReplicaSide.a ? ReplicaSide.b : ReplicaSide.a,
        row.reversal?.bytes,
      ),
      newSide: ComparedSide(source, row.bytes),
    );
  }

  void _openComparison(
    RowRef row,
    String path, {
    required ComparedSide oldSide,
    required ComparedSide newSide,
  }) {
    final session = _controller.session;
    if (session == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileDiffPage(
          args: FileDiffArgs(
            session: session,
            row: row,
            path: path,
            oldSide: oldSide,
            newSide: newSide,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    // System back while the core says the run is live asks before
    // leaving, because popping disposes the controller and that closes the
    // session mid-run. Before the first view and once the run is not live
    // there is no session to lose, so back pops with no prompt. Stop stays
    // the deliberate path and is untouched: this only closes the silent
    // one.
    //
    // Esc is that same back, from the keyboard ([PopOnEscape]): it goes
    // through this PopScope, so it asks exactly when back asks. The review
    // list takes the focus once there is a review, and Esc bubbles up from
    // it — the list does not take the key.
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = RunLayout.forWidth(constraints.maxWidth);
        return ListenableBuilder(
          listenable: state,
          builder: (context, child) => PopScope(
            canPop: !state.live,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              _confirmAbort();
            },
            child: child!,
          ),
          child: PopOnEscape(
            child: _buildScaffold(context, state, layout, constraints.maxWidth),
          ),
        );
      },
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    SyncRunViewState state,
    RunLayout layout,
    double windowWidth,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Sync with ${widget.request.deviceName}'),
        actions: [
          // Offered in every phase, including while the run is still going
          // (SPEC §17): "why is this taking so long" is a question asked
          // during the wait, and a report only reachable from a finished run
          // would answer it after it stopped mattering. Idle is the one
          // exception — there is nothing measured yet to look at.
          ListenableBuilder(
            listenable: state,
            builder: (context, _) => switch (state.phase) {
              SyncRunIdle() => const SizedBox.shrink(),
              SyncRunConnecting() ||
              SyncRunReconnecting() ||
              SyncRunScanning() ||
              SyncRunApplying() ||
              SyncRunAwaitingDecisions() ||
              SyncRunConfirmingDeletes() ||
              SyncRunFinished() ||
              SyncRunFinishedWithIssues() ||
              SyncRunStopped() ||
              SyncRunPaused() ||
              SyncRunReplicaBusy() ||
              SyncRunFailed() => IconButton(
                key: const Key('run-timings'),
                icon: const Icon(Icons.speed_outlined),
                tooltip: 'Timings',
                onPressed: () => showRunTimings(
                  context,
                  _controller,
                  windowWidth: windowWidth,
                ),
              ),
            },
          ),
          ListenableBuilder(
            listenable: state,
            // Resume is offered where the core offers it: a run it can
            // continue but does not continue on its own — a failure, and a
            // pause the app has not come back from yet (the tablet on the
            // desk that is picked up and read rather than unlocked). A
            // finished or stopped run is an outcome, not an interruption.
            builder: (context, _) => state.resumable
                ? TextButton(
                    key: const Key('run-resume'),
                    onPressed: _controller.resume,
                    child: const Text('Resume'),
                  )
                : const SizedBox.shrink(),
          ),
          ListenableBuilder(
            listenable: state,
            builder: (context, _) => switch (state.phase) {
              SyncRunIdle() ||
              SyncRunConnecting() ||
              SyncRunReconnecting() ||
              SyncRunScanning() ||
              SyncRunApplying() ||
              SyncRunAwaitingDecisions() ||
              SyncRunConfirmingDeletes() => TextButton(
                key: const Key('run-stop'),
                onPressed: _controller.stop,
                child: const Text('Stop'),
              ),
              SyncRunFinished() ||
              SyncRunFinishedWithIssues() ||
              SyncRunStopped() ||
              SyncRunPaused() ||
              SyncRunReplicaBusy() ||
              SyncRunFailed() => TextButton(
                key: const Key('run-done'),
                onPressed: widget.onDone,
                child: const Text('Done'),
              ),
            },
          ),
        ],
      ),
      // The review's bar (SPEC §11.3): the running total and the two
      // answers, under the rows being reviewed rather than over them. A
      // plain bottom bar of fixed height, so the body needs no padding
      // measured off it; it follows the phase to appear and disappear, and
      // the plan for its size warning — the plan section's listenable — and
      // its total follows its own cell, so a tap does not rebuild it from
      // the view state.
      bottomNavigationBar: ListenableBuilder(
        listenable: _planSection,
        builder: (context, _) => switch (state.phase) {
          SyncRunAwaitingDecisions() => _ReviewBar(
            summary: state.decisionSummary,
            sizeWarning: state.sizeWarning,
            controller: _controller,
            layout: layout,
            conflicts: state.conflicts.isNotEmpty,
          ),
          SyncRunConfirmingDeletes(:final sides) => _DeletesBar(
            sides: sides,
            controller: _controller,
            layout: layout,
          ),
          SyncRunIdle() ||
          SyncRunConnecting() ||
          SyncRunReconnecting() ||
          SyncRunScanning() ||
          SyncRunApplying() ||
          SyncRunFinished() ||
          SyncRunFinishedWithIssues() ||
          SyncRunStopped() ||
          SyncRunPaused() ||
          SyncRunReplicaBusy() ||
          SyncRunFailed() => const SizedBox.shrink(),
        },
      ),
      // A sliver list, so a section builds the rows the viewport holds and
      // not the rows that exist: a photo library's scan is tens of thousands
      // of paths, and none of them fit on a screen (§9's lists are the whole
      // library, not the part of it that changed).
      //
      // Two listeners, not one. Everything above the plan changes as the run
      // reports — phase and progress, header, tally, the two path lists, the
      // conflicts, the counts row — and follows the view state itself
      // (`_topSection`). The plan rows deliberately do not: the plan is
      // fixed once made, and every view the apply brings after it carries
      // the same rows with new results. So the plan section follows
      // `planChanged` and the phase (`_planSection`) — never the progress
      // or the path lists — and each row follows the cell for its own path
      // (`SyncRunViewState.resultCell`), which is what keeps applying action
      // N from rebuilding the rows above it — see the view state's class doc
      // comment and `RunPlanRow` (`run_plan_section.dart`).
      body: CustomScrollView(
        slivers: [
          RunReviewKeyboard(
            state: state,
            cursor: _cursor,
            order: () => reviewOrder(state, _disclosures),
            onChoose: _controller.choose,
            onResolve: _controller.resolveConflict,
            onCompareAction: _comparePlan,
            onCompareConflict: _compareConflict,
            onApply: _controller.confirm,
            onSyncAllExceptConflicts: _controller.acceptAll,
            sliver: _buildColumn(state, layout),
          ),
        ],
      ),
    );
  }

  Widget _buildColumn(SyncRunViewState state, RunLayout layout) {
    return SliverReadableColumn(
      width: layout.width,
      sliver: SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverMainAxisGroup(
          slivers: [
            ListenableBuilder(
              listenable: _topSection,
              // The read-only blocks — the phase and how the run ended, the
              // entries, the roots, the paths that could not be read — are
              // selectable each on its own. Not the page as a whole: the
              // review's rows take the keys on pointer down, and a region
              // over them would take the focus back from them on a click
              // held past the press timeout (`CopyValueButton` states the
              // rule).
              builder: (context, _) => SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: SelectionArea(child: _StageStrip(state)),
                  ),
                  // Only past one entry: a single-entry run reads
                  // exactly as it always has, with no list to draw
                  // above its own header and plan (D10).
                  if (state.entries.length > 1)
                    SliverToBoxAdapter(
                      child: SelectionArea(child: _EntriesSection(state)),
                    ),
                  if (state.header case final header?)
                    SliverToBoxAdapter(
                      child: SelectionArea(child: _Header(header)),
                    ),
                  SliverToBoxAdapter(child: _CountsRow(state)),
                  if (state.scanTally case final tally?)
                    SliverToBoxAdapter(child: _ScanTally(tally)),
                  if (state.unreadablePaths.isNotEmpty)
                    RunListSection(
                      sectionKey: const Key('run-unreadable'),
                      title: 'Could not read',
                      header: null,
                      itemExtent: null,
                      itemCount: state.unreadablePaths.length,
                      itemBuilder: (context, index) => SelectionArea(
                        child: Text(
                          state.unreadablePaths[index],
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  if (state.skippedSymlinks.isNotEmpty)
                    RunListSection(
                      sectionKey: const Key('run-symlinks'),
                      title: 'Symlinks not followed',
                      header: null,
                      itemExtent: null,
                      itemCount: state.skippedSymlinks.length,
                      itemBuilder: (context, index) => SelectionArea(
                        child: Text(state.skippedSymlinks[index]),
                      ),
                    ),
                  // A re-dialled review's rows that changed since the
                  // user answered them lead the plan area (SPEC §11.4),
                  // under the line that says so; every other row keeps
                  // its earlier choice in its own section below.
                  if (state.recalled case (:final changed, :final kept)
                      when state.phase is SyncRunAwaitingDecisions)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          recalledLine(changed: changed, kept: kept),
                          key: const Key('run-review-recalled'),
                        ),
                      ),
                    ),
                  if (state.changedConflicts.isNotEmpty ||
                      state.changedActions.isNotEmpty)
                    RunListSection(
                      sectionKey: const Key('run-changed'),
                      title:
                          'Changed since you approved '
                          '(${formatCount(state.changedConflicts.length + state.changedActions.length)})',
                      header: null,
                      itemExtent: null,
                      itemCount:
                          state.changedConflicts.length +
                          state.changedActions.length,
                      itemBuilder: (context, index) {
                        final conflicts = state.changedConflicts;
                        if (index < conflicts.length) {
                          final row = state.conflicts[conflicts[index]];
                          return _conflictItem(
                            state,
                            row,
                            mark: _ChangeLine(row.path, row.changed),
                          );
                        }
                        final row =
                            state.plan[state.changedActions[index -
                                conflicts.length]];
                        return _actionItem(
                          state,
                          row,
                          layout,
                          mark: _ChangeLine(row.path, row.changed),
                        );
                      },
                    ),
                  // First of the plan area (Design C.5): during the
                  // review each row carries its own control and its
                  // frame for the keyboard's cursor, and after it
                  // each follows its own result.
                  if (state.listedConflicts.isNotEmpty)
                    RunListSection(
                      sectionKey: const Key('run-conflicts'),
                      title:
                          'Conflicts (${formatCount(state.listedConflicts.length)})',
                      header: null,
                      itemExtent: null,
                      itemCount: state.listedConflicts.length,
                      itemBuilder: (context, index) => _conflictItem(
                        state,
                        state.conflicts[state.listedConflicts[index]],
                      ),
                    ),
                ],
              ),
            ),
            ListenableBuilder(
              listenable: _planSection,
              builder: (context, _) => state.plan.isEmpty
                  ? const SliverToBoxAdapter(child: SizedBox.shrink())
                  : RunPlanSection(
                      state,
                      onChoose: _controller.choose,
                      onCompare: _comparePlan,
                      layout: layout,
                      cursor: _cursor,
                      disclosures: _disclosures,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// A conflict's row: during the review with its choices and its frame
  /// for the keyboard's cursor. [mark], where there is one, sits under it.
  Widget _conflictItem(
    SyncRunViewState state,
    SyncRunConflictRow row, {
    Widget? mark,
  }) {
    final reviewing = state.phase is SyncRunAwaitingDecisions;
    final conflict = _marked(
      _ConflictRow(
        row,
        state: state,
        offered: reviewing ? row.offered : null,
        onResolve: _controller.resolveConflict,
        onCompare: _compareConflict,
      ),
      mark,
    );
    if (!reviewing) return conflict;
    return ReviewRowFrame(
      cursor: _cursor,
      target: ConflictTarget(row.index),
      child: conflict,
    );
  }

  /// [_conflictItem], for a planned action — as its plan group shows it.
  Widget _actionItem(
    SyncRunViewState state,
    SyncRunPlanRow row,
    RunLayout layout, {
    Widget? mark,
  }) {
    final reviewing = state.phase is SyncRunAwaitingDecisions;
    final action = _marked(
      RunPlanRow(
        state: state,
        row: row,
        onChoose: reviewing ? _controller.choose : null,
        onCompare: reviewing ? _comparePlan : null,
        layout: layout,
      ),
      mark,
    );
    if (!reviewing) return action;
    return ReviewRowFrame(
      cursor: _cursor,
      target: ActionTarget(row.index),
      child: action,
    );
  }

  static Widget _marked(Widget row, Widget? mark) => switch (mark) {
    final mark? => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [row, mark],
    ),
    null => row,
  };
}

/// A changed row's mark, under it in the review's changed group: what the
/// row was when the user answered it, or that its path is new.
class _ChangeLine extends StatelessWidget {
  const _ChangeLine(this.path, this.change);

  final String path;
  final SyncRunRowChange? change;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.tertiary;
    final was = change?.was;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 6),
            child: Icon(Icons.change_circle_outlined, size: 14, color: color),
          ),
          Expanded(
            child: Text(
              was == null ? 'new' : 'was: $was',
              key: Key('run-changed-$path'),
              style: TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The stages a run passes through, in order: the strip's row.
enum _Stage {
  connect('Connect'),
  scan('Scan'),
  review('Review'),
  apply('Apply'),
  done('Done');

  const _Stage(this.label);

  final String label;
}

/// The run's phase, first on the page: the stages as a row of static marks
/// — done, current, pending — then one line on the current one, or how the
/// run ended, then when it started.
///
/// **Nothing here animates.** A scan can last minutes, and a spinner or an
/// indeterminate bar repaints at frame rate for all of them to say only
/// "still going", which the current-stage mark already says. The one
/// moving part is the apply bar, which is determinate and so repaints only
/// when its value changes — at most once a second, by the controller's
/// rule. For the same reason the start is a fixed "Started 14:02", not an
/// elapsed-time ticker.
///
/// A run that was stopped, paused, refused or failed shows no stage row:
/// those phases do not carry the stage they interrupted, and a row that
/// guessed would say something the run did not.
class _StageStrip extends StatelessWidget {
  const _StageStrip(this.state);

  final SyncRunViewState state;

  @override
  Widget build(BuildContext context) {
    final phase = state.phase;
    final stage = switch (phase) {
      SyncRunConnecting() || SyncRunReconnecting() => _Stage.connect,
      SyncRunScanning() => _Stage.scan,
      SyncRunAwaitingDecisions() || SyncRunConfirmingDeletes() => _Stage.review,
      SyncRunApplying() => _Stage.apply,
      SyncRunFinished() => _Stage.done,
      SyncRunIdle() ||
      SyncRunFinishedWithIssues() ||
      SyncRunStopped() ||
      SyncRunPaused() ||
      SyncRunReplicaBusy() ||
      SyncRunFailed() => null,
    };
    final startedAt = state.startedAt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stage != null) ...[
            _StageRow(stage, over: phase is SyncRunFinished),
            const SizedBox(height: 8),
          ],
          _StageText(state),
          if (startedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Started $startedAt',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

/// The five stages, each marked done, current or pending by its shape — a
/// tick, a filled dot, a ring — so no mark depends on colour. [over]: the
/// last stage is reached and done too, not current.
class _StageRow extends StatelessWidget {
  const _StageRow(this.current, {required this.over});

  final _Stage current;
  final bool over;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final stage in _Stage.values)
          MergeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (stage.index < current.index || over)
                  Icon(
                    Icons.check_circle,
                    size: 16,
                    color: scheme.primary,
                    semanticLabel: 'done',
                  )
                else if (stage == current)
                  Icon(
                    Icons.circle,
                    size: 16,
                    color: scheme.primary,
                    semanticLabel: 'current',
                  )
                else
                  Icon(
                    Icons.circle_outlined,
                    size: 16,
                    color: scheme.outline,
                    semanticLabel: 'pending',
                  ),
                const SizedBox(width: 4),
                Text(stage.label),
              ],
            ),
          ),
      ],
    );
  }
}

/// The strip's text slot: the current stage in one line, or the run's end.
class _StageText extends StatelessWidget {
  const _StageText(this.state);

  final SyncRunViewState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (state.phase) {
      SyncRunIdle() => const SizedBox.shrink(),
      SyncRunConnecting() => const Text('Connecting…'),
      SyncRunReconnecting(:final attempt) => Text(
        'Connection lost — reconnecting ($attempt)',
        key: const Key('run-reconnecting'),
      ),
      SyncRunScanning() => Text(
        state.dryRun
            ? 'Scanning both folders (dry run)…'
            : 'Scanning both folders…',
      ),
      SyncRunAwaitingDecisions() => const Text(
        'Waiting for your review',
        key: Key('run-awaiting'),
      ),
      SyncRunConfirmingDeletes() => const Text(
        'Waiting for you to confirm the deletions',
        key: Key('run-confirming-deletes'),
      ),
      SyncRunApplying() => _ApplyProgress(state.progress),
      // A single line: the five numbers this used to carry live in the
      // counts row now (`_CountsRow`, keyed `run-summary`), which follows
      // `planChanged` rather than this text's own listenable and so is not
      // built here.
      SyncRunFinished() => Text(
        state.dryRun ? 'Dry run finished' : 'Finished',
        style: theme.textTheme.titleMedium,
      ),
      SyncRunFinishedWithIssues(:final issues) => Column(
        key: const Key('run-finished-with-issues'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Finished, but not every entry synced',
            style: theme.textTheme.titleMedium,
          ),
          for (final issue in issues) _NoticeLine.warning(issue),
        ],
      ),
      SyncRunStopped(:final completedActions) => Text(
        stoppedMessage(completedActions),
        key: const Key('run-stopped'),
      ),
      SyncRunPaused(:final completedActions) => Text(
        pausedMessage(completedActions),
        key: const Key('run-paused'),
      ),
      SyncRunReplicaBusy(:final message) => _NoticeLine.error(
        message,
        key: const Key('run-replica-busy'),
      ),
      SyncRunFailed(:final message) => _NoticeLine.error(
        message,
        key: const Key('run-failed'),
      ),
    };
  }
}

/// While applying: how far along, in words, and as a determinate bar once
/// the loop has reported anything. Never an indeterminate bar — before the
/// first progress the line says "Applying…" and there is no bar at all.
class _ApplyProgress extends StatelessWidget {
  const _ApplyProgress(this.progress);

  final SyncRunProgress? progress;

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    return Column(
      key: const Key('run-progress'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          progress == null
              ? 'Applying…'
              : 'Applying ${formatCount(progress.completed)} of '
                    '${formatCount(progress.total)}',
        ),
        if (progress != null && progress.total > 0) ...[
          const SizedBox(height: 8),
          // The label carries the phase, because a determinate bar takes
          // the platform's progress-bar role and its value must be a number
          // on 0..100 — the framework fills that in from [value], and a
          // prose `semanticsValue` here would be rejected outright. So the
          // phase goes where prose is allowed, and the percentage stays the
          // value.
          LinearProgressIndicator(
            value: progress.completed / progress.total,
            semanticsLabel: 'Applying changes',
          ),
        ],
      ],
    );
  }
}

/// One of the header's roots: its [label], then the path in whatever
/// width the label leaves — shortened only when that width requires it.
class _RootLine extends StatelessWidget {
  const _RootLine({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label),
        Flexible(child: PathText(path, style: null, leafStyle: null)),
      ],
    );
  }
}

/// An entry's two roots on one line, `local ⇄ remote`, each whole when the
/// line holds both. When it does not, the line is shared by
/// [sharePathWidths] — a short side keeps all of itself and the long side
/// gets the rest — and each side is middle-elided by its [PathText] into
/// its share.
class _RootPair extends StatelessWidget {
  const _RootPair({
    required this.local,
    required this.remote,
    required this.style,
  });

  final String local;
  final String remote;
  final TextStyle? style;

  static const _arrow = ' ⇄ ';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final arrow = PathText.wholeWidth(context, _arrow, style: style);
        final widths = sharePathWidths(
          (constraints.maxWidth - arrow).clamp(0, double.infinity),
          first: PathText.wholeWidth(context, local, style: style),
          second: PathText.wholeWidth(context, remote, style: style),
        );
        return Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widths.first),
              child: PathText(local, style: style, leafStyle: null),
            ),
            Text(_arrow, style: style),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widths.second),
              child: PathText(remote, style: style, leafStyle: null),
            ),
          ],
        );
      },
    );
  }
}

/// The header card (Design C.1): `This device ⇄ <device>`, then the two
/// roots — each a [PathText], whole when the card has room and otherwise
/// middle-elided rather than tail-clipped, so the leaf that tells two
/// saved runs apart survives a long Android path — then the last-synced
/// line and, if either side has no archive, the first-sync warning.
class _Header extends StatelessWidget {
  const _Header(this.header);

  final SyncRunHeader header;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        key: const Key('run-header'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This device ⇄ Remote',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          _RootLine(label: 'This device: ', path: header.localRoot),
          _RootLine(label: 'Remote: ', path: header.remoteRoot),
          const SizedBox(height: 4),
          Text(header.history),
          if (header.firstSyncWarning case final warning?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _NoticeLine.warning(
                warning,
                key: const Key('run-first-sync-warning'),
              ),
            ),
        ],
      ),
    );
  }
}

/// The profile's entries, above the current one's own header and plan
/// (D10): each entry's two roots and how it stands, so the user can see at
/// a glance which have synced, which are left, and which did not — without
/// waiting for the whole profile to finish. Shown only past one entry (the
/// page's caller gates it); the current entry's row is the one the rest of
/// the page describes.
class _EntriesSection extends StatelessWidget {
  const _EntriesSection(this.state);

  final SyncRunViewState state;

  @override
  Widget build(BuildContext context) {
    final current = state.currentEntry;
    return Padding(
      key: const Key('run-entries'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, entry) in state.entries.indexed)
            _EntryRow(index: index, entry: entry, isCurrent: index == current),
        ],
      ),
    );
  }
}

/// One entry's line: both its roots, elided the way the header elides them,
/// and a status word coloured and iconed the way every other notice on this
/// page is — never colour alone (see [_NoticeLine]).
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.index,
    required this.entry,
    required this.isCurrent,
  });

  final int index;
  final SyncRunEntryRow entry;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, label) = switch (entry.status) {
      SyncRunEntryPending() => (
        Icons.circle_outlined,
        theme.colorScheme.outline,
        'pending',
      ),
      SyncRunEntryRunning() => (
        Icons.sync,
        theme.colorScheme.primary,
        'running',
      ),
      SyncRunEntrySynced() => (
        Icons.check_circle,
        theme.colorScheme.primary,
        'synced',
      ),
      SyncRunEntrySkipped(:final reason) => (
        Icons.remove_circle_outline,
        theme.colorScheme.tertiary,
        'skipped: $reason',
      ),
      SyncRunEntryFailed(:final message) => (
        Icons.error_outline,
        theme.colorScheme.error,
        'failed: $message',
      ),
      SyncRunEntryNotRun() => (
        Icons.circle_outlined,
        theme.colorScheme.outline,
        'not run',
      ),
    };
    return Padding(
      key: Key('run-entry-$index'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 6),
            child: Icon(icon, size: 16, color: color),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RootPair(
                  local: entry.localRoot,
                  remote: entry.remoteRoot,
                  style: isCurrent
                      ? theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        )
                      : theme.textTheme.bodyMedium,
                ),
                Text(
                  label,
                  key: Key('run-entry-status-$index'),
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The scan tally (Design C.4): one line — "N files checked · M changed" —
/// with a disclosure to today's per-side breakdown, which is where the
/// metadata/hash split SPEC §5.2 wants reaches the page. Expansion is this
/// widget's own state for the same reason as [_PlanGroupSection] in
/// `run_plan_section.dart`: it renders no run update, so a rebuild of what
/// wraps it must not reset it.
class _ScanTally extends StatefulWidget {
  const _ScanTally(this.tally);

  final SyncRunScanTally tally;

  @override
  State<_ScanTally> createState() => _ScanTallyState();
}

class _ScanTallyState extends State<_ScanTally> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tally = widget.tally;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        key: const Key('run-scan-tally'),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${formatCount(tally.totalChecked)} files checked · '
                    '${formatCount(tally.totalChanged)} changed',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              ],
            ),
            if (_expanded) ...[const SizedBox(height: 8), _ScanTable(tally)],
          ],
        ),
      ),
    );
  }
}

/// The per-side breakdown behind the scan tally's disclosure: one row per
/// side, one column per outcome, so a glance down a column compares the
/// sides and a glance along a row reads one side. Zeros are dimmed — the
/// numbers that say something changed are the ones that should stand out.
///
/// Both unchanged counts stay reachable: the fast path versus a rehash that
/// found nothing changed (SPEC §5.2) is the whole point of the tally
/// reaching a head at all, so the hash share sits under the unchanged
/// total rather than in a column of its own.
class _ScanTable extends StatelessWidget {
  const _ScanTable(this.tally);

  final SyncRunScanTally tally;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.outline;
    final small = theme.textTheme.bodySmall;
    Widget cell(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
      child: Align(alignment: Alignment.centerRight, child: child),
    );
    Widget header(String text) =>
        cell(Text(text, style: small?.copyWith(color: dim)));
    Widget count(int n) =>
        Text(formatCount(n), style: n == 0 ? TextStyle(color: dim) : null);
    TableRow side(String name, SyncRunScanSide s) => TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(name, overflow: TextOverflow.ellipsis),
        ),
        cell(count(s.total)),
        cell(
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              count(s.metadataMatched + s.hashMatched),
              if (s.hashMatched > 0)
                Text(
                  '${formatCount(s.hashMatched)} by hash',
                  style: small?.copyWith(color: dim),
                ),
            ],
          ),
        ),
        cell(count(s.modified)),
        cell(count(s.created)),
        cell(count(s.deleted)),
      ],
    );
    return Table(
      key: const Key('run-scan-table'),
      columnWidths: const {0: FlexColumnWidth()},
      defaultColumnWidth: const IntrinsicColumnWidth(),
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        TableRow(
          children: [
            const SizedBox.shrink(),
            header('Checked'),
            header('Unchanged'),
            header('Modified'),
            header('Created'),
            header('Deleted'),
          ],
        ),
        side('This device', tally.local),
        side('Remote', tally.remote),
      ],
    );
  }
}

/// The counts row (Design C.3): compact tallies of where the plan is
/// headed while the run goes, the SPEC §11.4 five numbers once it is over.
/// Both keep this row's key, `run-summary` — the finished branch is what
/// that key used to mark alone, on `_StageText`; the pending branch is new.
///
/// Hidden until there is something to show: before the plan arrives and
/// after, nothing here is built for a phase with neither (idle,
/// connecting, or scanning before the plan lands).
class _CountsRow extends StatelessWidget {
  const _CountsRow(this.state);

  final SyncRunViewState state;

  @override
  Widget build(BuildContext context) {
    final phase = state.phase;
    if (phase is SyncRunFinished) {
      return _FinishedCounts(
        key: const Key('run-summary'),
        phase: phase,
        dryRun: state.dryRun,
      );
    }
    if (state.plan.isEmpty || phase is SyncRunAwaitingDecisions) {
      return const SizedBox.shrink();
    }
    return _PendingCounts(key: const Key('run-summary'), state: state);
  }
}

/// The counts row before the run is over: how much of the plan moves in
/// each direction (Design C.3), folded once per plan and read from
/// [SyncRunViewState.planSections] rather than walked here, plus the
/// unresolved-conflict count already on [SyncRunViewState.conflicts]. The
/// live Applied/Failed pair joins them while the run applies the plan —
/// what `_PlanTally` used to show under the plan's own disclosure.
class _PendingCounts extends StatelessWidget {
  const _PendingCounts({super.key, required this.state});

  final SyncRunViewState state;

  @override
  Widget build(BuildContext context) {
    final sections = state.planSections;
    final toDevice = sections[SyncRunPlanGroup.toDevice]!;
    final toThisDevice = sections[SyncRunPlanGroup.toThisDevice]!;
    final deletions = sections[SyncRunPlanGroup.deletions]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _CountTile(
            icon: Icons.arrow_upward,
            text:
                'to the remote ${formatCount(toDevice.count)}'
                '${toDevice.bytes > 0 ? ' (${formatBytes(toDevice.bytes)})' : ''}',
          ),
          _CountTile(
            icon: Icons.arrow_downward,
            text:
                'to this device ${formatCount(toThisDevice.count)}'
                '${toThisDevice.bytes > 0 ? ' (${formatBytes(toThisDevice.bytes)})' : ''}',
          ),
          _CountTile(
            icon: Icons.delete_outline,
            text: 'delete ${formatCount(deletions.count)}',
          ),
          _CountTile(
            icon: Icons.call_split,
            text: 'conflicts ${formatCount(state.conflicts.length)}',
          ),
          if (state.phase is SyncRunApplying) _ApplyTally(state),
        ],
      ),
    );
  }
}

/// One "icon, then N" tile of [_PendingCounts].
class _CountTile extends StatelessWidget {
  const _CountTile({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16),
      const SizedBox(width: 4),
      Flexible(child: Text(text)),
    ],
  );
}

/// Applied/failed so far, folded into the counts row while the run applies
/// the plan — what `_PlanTally` used to show under the plan's own
/// disclosure, at the same key (`run-plan-tally`) so the one test that
/// named it still finds it. [SyncRunViewState]'s own counts, not a walk
/// over its results: [_RunPageState]'s top block already follows the view
/// state itself, which the apply loop wakes at most once a second, so this
/// needs no listenable of its own.
class _ApplyTally extends StatelessWidget {
  const _ApplyTally(this.state);

  final SyncRunViewState state;

  @override
  Widget build(BuildContext context) {
    final applied = state.appliedCount;
    final failed = state.failedCount;
    return Row(
      key: const Key('run-plan-tally'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Applied: $applied'),
        const SizedBox(width: 12),
        if (failed > 0)
          _NoticeLine.error('Failed: $failed')
        else
          const Text('Failed: 0'),
      ],
    );
  }
}

/// The counts row once the run is over: the SPEC §11.4 five numbers,
/// unchanged from what `_StageText`'s finished case used to render under
/// the same key — moved here so that case can stay the single line
/// Inherited-from-Phase-5 asks for.
class _FinishedCounts extends StatelessWidget {
  const _FinishedCounts({super.key, required this.phase, required this.dryRun});

  final SyncRunFinished phase;
  final bool dryRun;

  @override
  Widget build(BuildContext context) {
    final SyncRunFinished(
      :applied,
      :skipped,
      :conflicts,
      :failed,
      :unreadable,
    ) = phase;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (dryRun) const Text('Nothing was applied.'),
          // Five numbers, always: two of them (skipped, unreadable) answer
          // different questions and are never summed.
          Text('Applied: $applied'),
          Text('Skipped: $skipped'),
          Text('Conflicts: $conflicts'),
          if (failed > 0)
            _NoticeLine.error('Failed: $failed')
          else
            const Text('Failed: 0'),
          if (unreadable > 0)
            _NoticeLine.error('Unreadable: $unreadable')
          else
            const Text('Unreadable: 0'),
        ],
      ),
    );
  }
}

/// The review's bar under the page: the running total, then "Sync all
/// except conflicts" (the `--batch` answer: every action as planned, no
/// conflict resolved — whatever the rows say) and Apply (the rows' own
/// choices). Follows [summary] alone, so a tap rebuilds this and the tapped
/// row and nothing else. One line of total, ellipsised, so its height never
/// depends on what was chosen.
///
/// Over the total, when the plan moves more than its warn size (SPEC
/// §10), the warning line: fixed with the plan, and right above Apply so
/// it is read before the answer is given.
///
/// In the table [layout] — a desk, a keyboard — it also lists the review's
/// keys, one line under the total, so they are learnt from the page rather
/// than from a help screen; the conflict keys only where there are
/// [conflicts] to use them on.
class _ReviewBar extends StatelessWidget {
  const _ReviewBar({
    required this.summary,
    required this.sizeWarning,
    required this.controller,
    required this.layout,
    required this.conflicts,
  });

  final ValueListenable<SyncRunDecisionSummary?> summary;

  /// SPEC §10's warning, over the answers so it is read before Apply.
  final String? sizeWarning;
  final SyncRunController controller;
  final RunLayout layout;
  final bool conflicts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        // Held to the body's column, so the answers sit under the rows
        // being reviewed rather than at the far edge of a wide window.
        child: ReadableColumn(
          width: layout.width,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (sizeWarning case final warning?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _NoticeLine.warning(
                      warning,
                      key: const Key('run-size-warning'),
                    ),
                  ),
                ValueListenableBuilder<SyncRunDecisionSummary?>(
                  valueListenable: summary,
                  builder: (context, summary, _) => Text(
                    summary == null ? '' : _summaryLine(summary),
                    key: const Key('run-review-summary'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (layout == RunLayout.table)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _keyLegend(conflicts: conflicts),
                      key: const Key('run-review-keys'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                // Wraps rather than overflowing on a narrow phone; its height
                // follows the screen's width, never the choices.
                // Full width, so the end alignment has room to push the
                // buttons right: a bare Wrap in this start-aligned column
                // shrinks to its buttons and sits on the left.
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      TextButton(
                        key: const Key('run-sync-all-except-conflicts'),
                        onPressed: controller.acceptAll,
                        child: const Text('Sync all except conflicts'),
                      ),
                      FilledButton(
                        key: const Key('run-confirm'),
                        onPressed: controller.confirm,
                        child: const Text('Apply'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// SPEC §10's delete guard, in the review bar's place: what the decided
/// actions delete — how many files, of how many, on which side and in
/// which folder — and the two answers. Not a dialog: like the review, it
/// is the run's own next step, and Stop stays one tap away above it.
class _DeletesBar extends StatelessWidget {
  const _DeletesBar({
    required this.sides,
    required this.controller,
    required this.layout,
  });

  final List<SyncRunDeletesOnSide> sides;
  final SyncRunController controller;
  final RunLayout layout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = sides.fold(0, (sum, side) => sum + side.deletes);
    return Material(
      key: const Key('run-deletes-bar'),
      elevation: 8,
      child: SafeArea(
        top: false,
        child: ReadableColumn(
          width: layout.width,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This sync deletes most of a folder',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                for (final side in sides)
                  Text(
                    '${formatCount(side.deletes)} of the '
                    '${formatCount(side.archived)} files on ${side.where}'
                    '${switch (side.root) {
                      // In full: this is the line that asks the user to
                      // check which folder is about to be emptied, and it
                      // wraps.
                      final root? => ' ($root)',
                      null => '',
                    }} would be deleted.',
                  ),
                const SizedBox(height: 4),
                const Text(
                  'If a folder was emptied, moved or unmounted by mistake, '
                  "don't delete.",
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      TextButton(
                        key: const Key('run-deletes-decline'),
                        onPressed: controller.declineDeletes,
                        child: const Text("Don't delete"),
                      ),
                      FilledButton(
                        key: const Key('run-deletes-confirm'),
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.error,
                          foregroundColor: theme.colorScheme.onError,
                        ),
                        onPressed: controller.confirmDeletes,
                        child: Text('Delete ${formatCount(total)} files'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Apply 1,198 · 2 reversed · 1 conflict kept both": the actions that
/// will be applied, then only the parts that are not zero.
String _summaryLine(SyncRunDecisionSummary summary) => [
  'Apply ${formatCount(summary.apply)}',
  if (summary.reversed > 0) '${formatCount(summary.reversed)} reversed',
  if (summary.skipped > 0) '${formatCount(summary.skipped)} skipped',
  if (summary.resolved > 0)
    '${formatCount(summary.resolved)} ${_conflicts(summary.resolved)} resolved',
  if (summary.keptBoth > 0)
    '${formatCount(summary.keptBoth)} ${_conflicts(summary.keptBoth)} kept both',
  if (summary.leftOpen > 0)
    '${formatCount(summary.leftOpen)} ${_conflicts(summary.leftOpen)} left open',
].join(' · ');

String _conflicts(int count) => count == 1 ? 'conflict' : 'conflicts';

/// "↑ ↓ PgUp PgDn Home End move · A as planned, R reverse, S skip ·
/// conflicts: T this device, … · Enter apply · …": the review's keys, the
/// choice keys read from the very maps the keyboard picks by, so the
/// legend cannot promise a key the review does not take.
String _keyLegend({required bool conflicts}) => [
  '↑ ↓ PgUp PgDn Home End move',
  _choiceKeys(actionChoiceKeys, actionChoiceName),
  if (conflicts)
    'conflicts: ${_choiceKeys(conflictChoiceKeys, _conflictChoiceName)}',
  'Enter apply',
  'Ctrl+Enter sync all except conflicts',
  'Esc leave',
].join(' · ');

String _choiceKeys<C>(
  Map<C, LogicalKeyboardKey> keys,
  String Function(C choice) name,
) => [
  for (final MapEntry(key: choice, value: key) in keys.entries)
    '${key.keyLabel} ${name(choice).toLowerCase()}',
].join(', ');

/// A conflict's choice said back in words: above the side boxes that make
/// it, and in the review bar's key legend.
String _conflictChoiceName(ConflictChoice choice) => switch (choice) {
  ConflictChoice.unresolved => 'Skip',
  ConflictChoice.keepA => 'This device',
  ConflictChoice.keepB => 'Remote',
  ConflictChoice.keepBoth => 'Both',
};

/// One conflict (SPEC §6): the file's name, then each side's status boxed
/// side by side — and, while the review is up ([offered] set), those two
/// boxes are the choice. Tapping a side keeps it; tapping both keeps both;
/// neither selected is Skip. The choice is said back in words at the top
/// right ("Skip", "This device", "Remote", "Both"), so what a tap did is
/// never left to the box colours alone. Follows its own cell
/// ([SyncRunViewState.conflictDecisionCell]) so a tap rebuilds this row
/// alone.
///
/// A side the conflict cannot keep (no record of the path there — the
/// core's [SyncRunConflictRow.offered]) is not tappable. Selecting the second side
/// where "Both" is not offered moves the selection to it instead.
///
/// After the review it follows its own [SyncRunViewState.resultCell]. A
/// side kept settles the conflict, and its result reads like any applied
/// action's. "Keep both" does not: its result is the peer's copy saved
/// aside, reported under the conflict's own path, and the conflict stays
/// open — so it is shown as a saved copy beside a still-open conflict,
/// never the ✓ an applied action gets.
class _ConflictRow extends StatelessWidget {
  const _ConflictRow(
    this.row, {
    required this.state,
    required this.offered,
    required this.onResolve,
    required this.onCompare,
  });

  final SyncRunConflictRow row;
  final SyncRunViewState state;
  final List<ConflictChoice>? offered;
  final void Function(int index, ConflictChoice choice) onResolve;
  final void Function(SyncRunConflictRow row) onCompare;

  @override
  Widget build(BuildContext context) {
    final offered = this.offered;
    final theme = Theme.of(context);
    final label = PathLabel.stacked(row.path);
    return ValueListenableBuilder<SyncRunResultRow?>(
      valueListenable: state.resultCell(row.path),
      builder: (context, result, _) => ValueListenableBuilder<ConflictChoice>(
        valueListenable: state.conflictDecisionCell(row),
        builder: (context, choice, _) {
          final (local: keepsLocal, remote: keepsRemote) = _sides(choice);
          return Padding(
            key: Key('run-conflict-${row.path}'),
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2, right: 6),
                      child: Icon(
                        Icons.error_outline,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        label.leaf,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (offered != null && row.comparable)
                      IconButton(
                        key: Key('compare-${row.path}'),
                        icon: const Icon(Icons.difference_outlined),
                        tooltip: 'Compare',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => onCompare(row),
                      ),
                    if (offered != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          _conflictChoiceName(choice),
                          key: Key('decision-${row.path}'),
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: choice == ConflictChoice.unresolved
                                ? theme.colorScheme.outline
                                : theme.colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
                if (label.parent.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 22),
                    child: Text(
                      label.parent,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                // Both boxes as tall as the taller: a side with a file
                // carries a line more than one without.
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _ConflictSide(
                          key: Key('run-conflict-local-${row.path}'),
                          name: 'This device',
                          side: row.local,
                          selected: offered != null && keepsLocal,
                          onTap: _tapFor(offered, choice, ConflictChoice.keepA),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ConflictSide(
                          key: Key('run-conflict-remote-${row.path}'),
                          name: 'Remote',
                          side: row.remote,
                          selected: offered != null && keepsRemote,
                          onTap: _tapFor(offered, choice, ConflictChoice.keepB),
                        ),
                      ),
                    ],
                  ),
                ),
                if (result != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _result(context, result, choice),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The tap on the side that [side] keeps, or `null` — not tappable —
  /// outside the review or where that side cannot be kept.
  VoidCallback? _tapFor(
    List<ConflictChoice>? offered,
    ConflictChoice current,
    ConflictChoice side,
  ) {
    if (offered == null || !offered.contains(side)) return null;
    return () => onResolve(row.index, _toggled(current, side, offered));
  }

  Widget _result(
    BuildContext context,
    SyncRunResultRow result,
    ConflictChoice choice,
  ) {
    if (result.error case final error?) {
      return _NoticeLine.error('${result.action}: $error');
    }
    final keptOpen = choice == ConflictChoice.keepBoth;
    return Row(
      key: Key('run-conflict-result-${row.path}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          keptOpen ? Icons.file_copy_outlined : Icons.check_circle_outline,
          size: 16,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            keptOpen ? '${result.action} — still open' : result.action,
          ),
        ),
      ],
    );
  }
}

/// Which side boxes [choice] selects.
({bool local, bool remote}) _sides(ConflictChoice choice) => switch (choice) {
  ConflictChoice.unresolved => (local: false, remote: false),
  ConflictChoice.keepA => (local: true, remote: false),
  ConflictChoice.keepB => (local: false, remote: true),
  ConflictChoice.keepBoth => (local: true, remote: true),
};

/// The choice after a tap on the box that keeps [side] (`keepA`, this
/// device's, or `keepB`, the remote's): the tapped box flips, and the two boxes read back as a
/// choice — none is Skip, one is that side, both is Both. Where Both is not
/// offered, a second side moves the selection instead of adding to it.
ConflictChoice _toggled(
  ConflictChoice current,
  ConflictChoice side,
  List<ConflictChoice> offered,
) {
  final (:local, :remote) = _sides(current);
  final tappedLocal = side == ConflictChoice.keepA;
  final next = switch ((
    tappedLocal ? !local : local,
    tappedLocal ? remote : !remote,
  )) {
    (false, false) => ConflictChoice.unresolved,
    (true, false) => ConflictChoice.keepA,
    (false, true) => ConflictChoice.keepB,
    (true, true) => ConflictChoice.keepBoth,
  };
  return offered.contains(next) ? next : side;
}

/// One side of a conflict, boxed: whose side it is, then its status as an
/// icon and a word — so the conflict reads as "modified vs deleted" at a
/// glance rather than as a sentence to parse. While the review is up it is
/// also the control: [onTap] set, and [selected] filled in the theme's
/// primary container colour. The border is always drawn, transparent when
/// unselected, so selecting never changes the box's size.
class _ConflictSide extends StatelessWidget {
  const _ConflictSide({
    super.key,
    required this.name,
    required this.side,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final SyncRunConflictSide side;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final (icon, word) = switch (side.status) {
      SyncRunSideStatus.unchanged => (Icons.check, 'unchanged'),
      SyncRunSideStatus.created => (Icons.add, 'created'),
      SyncRunSideStatus.modified => (Icons.edit_outlined, 'modified'),
      SyncRunSideStatus.deleted => (Icons.delete_outline, 'deleted'),
      SyncRunSideStatus.none => (Icons.remove, 'no record'),
    };
    final radius = BorderRadius.circular(8);
    final foreground = selected ? scheme.onPrimaryContainer : null;
    final detail = textTheme.bodySmall?.copyWith(
      color: foreground ?? scheme.outline,
    );
    return Semantics(
      button: onTap != null,
      selected: selected,
      child: Material(
        color: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            width: 2,
            color: selected ? scheme.primary : Colors.transparent,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: foreground ?? scheme.outline,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(icon, size: 16, color: foreground),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(word, style: TextStyle(color: foreground)),
                    ),
                  ],
                ),
                // Two pieces that wrap between them, never mid-piece: the
                // box is half a phone's width.
                if (side.file case (:final modified, :final bytes))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Wrap(
                      spacing: 6,
                      children: [
                        Text(modified, style: detail),
                        Text(formatBytes(bytes), style: detail),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A line that reports something gone wrong — a failure, a conflict, a
/// caveat — with an icon in front of it as well as the theme's colour for
/// it. The icon is the point: colour alone does not carry the meaning to a
/// reader who cannot tell these hues apart, which is why the notice tiles on
/// Devices and Profiles pair the two, and this is the same pairing —
/// `error_outline` over `colorScheme.error` for something that failed,
/// `warning_amber_outlined` over `colorScheme.tertiary` for a caveat.
class _NoticeLine extends StatelessWidget {
  const _NoticeLine.error(this.message, {super.key})
    : icon = Icons.error_outline,
      isError = true;

  const _NoticeLine.warning(this.message, {super.key})
    : icon = Icons.warning_amber_outlined,
      isError = false;

  final String message;
  final IconData icon;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.error : scheme.tertiary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // The icon's box is taller than a line of text; this sits it on
          // the first line rather than above it.
          padding: const EdgeInsets.only(top: 2, right: 6),
          child: Icon(icon, size: 16, color: color),
        ),
        Flexible(
          child: Text(message, style: TextStyle(color: color)),
        ),
      ],
    );
  }
}

/// The confirmation the system back gesture — or Esc — puts in front of a
/// live run: leaving is an abort, worded as one, and the cancel is the
/// default way out, focused so Enter keeps the run going. Stop is not
/// offered here — it is one tap away in the app bar, and this dialog's
/// only job is to make the silent path deliberate.
class _AbortDialog extends StatelessWidget {
  const _AbortDialog();

  @override
  Widget build(BuildContext context) {
    return const DestructiveConfirmDialog(
      key: Key('run-abort-dialog'),
      title: 'Leave and stop this sync?',
      message:
          'This sync is still running. Leaving stops it where it is; '
          'anything already applied stays applied.',
      cancelLabel: 'Keep syncing',
      confirmLabel: 'Leave and stop',
      cancelKey: Key('run-abort-cancel'),
      confirmKey: Key('run-abort-confirm'),
    );
  }
}
