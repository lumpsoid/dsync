import 'package:flutter/material.dart';

import '../../format_bytes.dart';
import '../../format_count.dart';
import '../../format_path.dart';
import '../../run_request.dart';
import '../diagnostics/diagnostics_page.dart';
import 'run_controller.dart';
import 'run_plan_section.dart';
import 'run_scope.dart';
import 'run_timings_sheet.dart';
import 'run_view_state.dart';

/// The Run page: drive a run for [request] and render the core's run updates
/// (SPEC §9, §11.4). Widgets only, per the page role in `app_scope.dart`:
/// it switches over [SyncRunPhase] and lists the rendered rows in the order
/// the controller folded them.
///
/// **Owns its controller.** This page takes `runScope.create()` — never the
/// cached `controller` every other page reads — and disposes it in
/// [State.dispose]; the scope contract in `app_scope.dart` says why:
/// two runs must never share a loop, and an event arriving late from a
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

  /// What the body's plan section follows: the plan itself, and the phase
  /// that decides whether the body shows it at all. Built once and not per
  /// build, so a rebuild does not swap the section's listeners.
  late final Listenable _planSection = Listenable.merge([
    _controller.state.planChanged,
    _controller.state.phaseChanged,
  ]);

  /// What the top block (header, counts row, scan tally, path lists,
  /// conflicts) follows: the view state itself, plus `planChanged` for the
  /// one thing `recordPlan` writes silently — see the body's own doc
  /// comment. Built once for the same reason as [_planSection]: a rebuild
  /// of this state (the sheet's extent changing, say) must not tear down
  /// and resubscribe the block's listener.
  late final Listenable _topSection = Listenable.merge([
    _controller.state,
    _controller.state.planChanged,
  ]);

  /// How much of the body the decision sheet covers, measured from the
  /// sheet itself after it lays out: it sizes to its content up to a share
  /// of the screen, so only layout knows which of the two it landed on.
  /// The body pads its scroll view by this, so the bottom of it can still
  /// be scrolled out from behind the sheet. Zero while the sheet is down.
  double _sheetExtent = 0;

  void _setSheetExtent(double extent) {
    if (!mounted || _sheetExtent == extent) return;
    setState(() => _sheetExtent = extent);
  }

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onPause: _controller.pause,
      onResume: () => _controller.resumeFromBackground(widget.request),
    );
    _controller.start(widget.request);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// System back while the run is live: ask before leaving, because popping
  /// disposes the controller and that cancels the session mid-apply. Only
  /// the phases that have a session to lose are guarded — idle and
  /// connecting have applied nothing, and finished, stopped and failed are
  /// over, so back pops those with no prompt. Stop stays the deliberate
  /// path and is untouched: this only closes the silent one.
  bool _abortsRun(SyncRunPhase phase) => switch (phase) {
    SyncRunScanning() ||
    SyncRunApplying() ||
    SyncRunAwaitingDecisions() => true,
    SyncRunIdle() ||
    SyncRunConnecting() ||
    SyncRunFinished() ||
    SyncRunStopped() ||
    SyncRunPaused() ||
    SyncRunReplicaBusy() ||
    SyncRunFailed() => false,
  };

  /// Opens the Diagnostics page over this run's local replica.
  ///
  /// The reason a probe may not run is decided here rather than there: what
  /// counts as "a run is in flight" is this feature's own phase sum type, and
  /// the Diagnostics page takes a sentence it can show rather than a phase it
  /// would have to interpret.
  Future<void> _openDiagnostics(SyncRunViewState state) {
    final running = switch (state.phase) {
      SyncRunConnecting() ||
      SyncRunScanning() ||
      SyncRunApplying() ||
      SyncRunAwaitingDecisions() => true,
      SyncRunIdle() ||
      SyncRunFinished() ||
      SyncRunStopped() ||
      SyncRunPaused() ||
      SyncRunReplicaBusy() ||
      SyncRunFailed() => false,
    };
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiagnosticsPage(
          rootPath: widget.request.localRootPath,
          blockedReason: running
              ? 'A sync is running. Measuring now would compete with it for '
                    'the same storage, so neither figure would be honest — '
                    'wait for it to finish, or stop it.'
              : null,
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return ListenableBuilder(
      listenable: state.phaseChanged,
      builder: (context, child) => PopScope(
        canPop: !_abortsRun(state.phase),
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _confirmAbort();
        },
        child: child!,
      ),
      child: _buildScaffold(context, state),
    );
  }

  Widget _buildScaffold(BuildContext context, SyncRunViewState state) {
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
              SyncRunScanning() ||
              SyncRunApplying() ||
              SyncRunAwaitingDecisions() ||
              SyncRunFinished() ||
              SyncRunStopped() ||
              SyncRunPaused() ||
              SyncRunReplicaBusy() ||
              SyncRunFailed() => IconButton(
                key: const Key('run-timings'),
                icon: const Icon(Icons.speed_outlined),
                tooltip: 'Timings',
                onPressed: () => showRunTimings(context, _controller),
              ),
            },
          ),
          // Offered in every phase, unlike Timings: the page it opens is
          // useful before a run as well as after one, and it says for itself
          // why its probes are disabled while a run is in flight. The report
          // it leads to is read *beside* the Timings one — §17's `readFile`
          // and apply throughput against what this device's files cost to
          // read any other way — which is why the two are one tap apart.
          IconButton(
            key: const Key('run-diagnostics'),
            icon: const Icon(Icons.biotech_outlined),
            tooltip: 'Diagnostics',
            onPressed: () => _openDiagnostics(state),
          ),
          ListenableBuilder(
            listenable: state,
            // Resume is offered where a run can be continued but is not
            // continued on its own: a failure, and a pause the app has not
            // come back from yet (the tablet on the desk that is picked up
            // and read rather than unlocked). A finished or stopped run is
            // an outcome, not an interruption, and is not re-run from here.
            builder: (context, _) => switch (state.phase) {
              SyncRunPaused() ||
              SyncRunReplicaBusy() ||
              SyncRunFailed() => TextButton(
                key: const Key('run-resume'),
                onPressed: () => _controller.resume(widget.request),
                child: const Text('Resume'),
              ),
              SyncRunIdle() ||
              SyncRunConnecting() ||
              SyncRunScanning() ||
              SyncRunApplying() ||
              SyncRunAwaitingDecisions() ||
              SyncRunFinished() ||
              SyncRunStopped() => const SizedBox.shrink(),
            },
          ),
          ListenableBuilder(
            listenable: state,
            builder: (context, _) => switch (state.phase) {
              SyncRunIdle() ||
              SyncRunConnecting() ||
              SyncRunScanning() ||
              SyncRunApplying() ||
              SyncRunAwaitingDecisions() => TextButton(
                key: const Key('run-stop'),
                onPressed: _controller.stop,
                child: const Text('Stop'),
              ),
              SyncRunFinished() ||
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
      // The conflict sheet (SPEC §11.3), as the Scaffold's persistent
      // bottom sheet rather than a modal one: it is a rendering of the
      // awaiting-decisions phase and leaves with it, so there is nothing to
      // pop, no barrier over Stop, and no way to drag it away and strand a
      // run that is waiting on an answer.
      bottomSheet: ListenableBuilder(
        listenable: state,
        builder: (context, _) => switch (state.phase) {
          SyncRunAwaitingDecisions(
            :final conflicts,
            :final actions,
            :final bytesToTransfer,
          ) =>
            _MeasuredHeight(
              onExtent: _setSheetExtent,
              child: _DecisionSheet(
                conflicts: conflicts,
                actions: actions,
                bytesToTransfer: bytesToTransfer,
                deviceName: widget.request.deviceName,
                controller: _controller,
              ),
            ),
          SyncRunIdle() ||
          SyncRunConnecting() ||
          SyncRunScanning() ||
          SyncRunApplying() ||
          SyncRunFinished() ||
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
      // (`_topSection`), plus `planChanged` for the one field none of that
      // touches: `recordPlan` folds the plan's group counts silently, on
      // `planChanged` alone, so the counts row would otherwise wait on the
      // next unrelated notification to show them. The plan rows deliberately
      // do not follow `state`: the plan arrives whole in one `RunPlanEvent`,
      // and the apply loop then reports one result per action. So the plan
      // section follows `planChanged` and the phase (`_planSection`) — never
      // the progress or the path lists — and each row follows the cell for
      // its own path (`SyncRunViewState.resultCell`), which is what keeps
      // applying action N from rebuilding the rows above it — see the view
      // state's class doc comment and `RunPlanRow` (`run_plan_section.dart`).
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            // Padded by the sheet's own height while it is up: without it
            // the last of these sections sits behind the sheet with no way
            // to scroll it into view.
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + _sheetExtent),
            sliver: SliverMainAxisGroup(
              slivers: [
                ListenableBuilder(
                  listenable: _topSection,
                  builder: (context, _) => SliverMainAxisGroup(
                    slivers: [
                      SliverToBoxAdapter(child: _StageStrip(state)),
                      if (state.header case final header?)
                        SliverToBoxAdapter(child: _Header(header)),
                      SliverToBoxAdapter(
                        child: _CountsRow(
                          state,
                          deviceName: widget.request.deviceName,
                        ),
                      ),
                      if (state.scanTally case final tally?)
                        SliverToBoxAdapter(
                          child: _ScanTally(
                            tally,
                            deviceName: widget.request.deviceName,
                          ),
                        ),
                      if (state.unreadablePaths.isNotEmpty)
                        RunListSection(
                          sectionKey: const Key('run-unreadable'),
                          title: 'Could not read',
                          itemCount: state.unreadablePaths.length,
                          itemBuilder: (context, index) => Text(
                            state.unreadablePaths[index],
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      if (state.skippedSymlinks.isNotEmpty)
                        RunListSection(
                          sectionKey: const Key('run-symlinks'),
                          title: 'Symlinks not followed',
                          itemCount: state.skippedSymlinks.length,
                          itemBuilder: (context, index) =>
                              Text(state.skippedSymlinks[index]),
                        ),
                      // Hidden while the sheet is up: the sheet lists the
                      // same conflicts, with the directions to resolve them.
                      // Everything above stays — the header, the tally and
                      // the two path lists are not in the sheet and are the
                      // context someone wants while deciding.
                      if (state.phase is! SyncRunAwaitingDecisions &&
                          state.conflicts.isNotEmpty)
                        RunListSection(
                          sectionKey: const Key('run-conflicts'),
                          title: 'Conflicts (not resolved)',
                          itemCount: state.conflicts.length,
                          itemBuilder: (context, index) {
                            final row = state.conflicts[index];
                            return _NoticeLine.error(
                              '${row.path}: this device ${row.local}, the '
                              'other side ${row.remote}',
                            );
                          },
                        ),
                    ],
                  ),
                ),
                // Hidden while the sheet is up for the same reason as the
                // conflicts above, and back the moment the decision is
                // made: from then on these rows carry each action's result
                // icon, which is what the sheet's rows do not do.
                ListenableBuilder(
                  listenable: _planSection,
                  builder: (context, _) =>
                      state.plan.isEmpty ||
                          state.phase is SyncRunAwaitingDecisions
                      ? const SliverToBoxAdapter(child: SizedBox.shrink())
                      : RunPlanSection(
                          state,
                          deviceName: widget.request.deviceName,
                        ),
                ),
              ],
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
      SyncRunConnecting() => _Stage.connect,
      SyncRunScanning() => _Stage.scan,
      SyncRunAwaitingDecisions() => _Stage.review,
      SyncRunApplying() => _Stage.apply,
      SyncRunFinished() => _Stage.done,
      SyncRunIdle() ||
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
      SyncRunScanning() => Text(
        state.dryRun
            ? 'Scanning both folders (dry run)…'
            : 'Scanning both folders…',
      ),
      SyncRunAwaitingDecisions() => const Text(
        'Waiting for your review',
        key: Key('run-awaiting'),
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

/// The header card (Design C.1): `This device ⇄ <device>`, then the two
/// roots — each middle-elided by [elidePath] rather than tail-clipped, so
/// the leaf that tells two saved runs apart survives a long Android path
/// — then the last-synced line and, if either side has no archive, the
/// first-sync warning.
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
            'This device ⇄ ${header.deviceName}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text('This device: ${elidePath(header.localRoot)}'),
          Text('${header.deviceName}: ${elidePath(header.remoteRoot)}'),
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

/// The scan tally (Design C.4): one line — "N files checked · M changed" —
/// with a disclosure to today's per-side breakdown, which is where the
/// metadata/hash split SPEC §5.2 wants reaches the page. Expansion is this
/// widget's own state for the same reason as [_PlanGroupSection] in
/// `run_plan_section.dart`: it renders no run update, so a rebuild of what
/// wraps it must not reset it.
class _ScanTally extends StatefulWidget {
  const _ScanTally(this.tally, {required this.deviceName});

  final SyncRunScanTally tally;
  final String deviceName;

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
            if (_expanded) ...[
              const SizedBox(height: 4),
              _tallyLine('This device', tally.local),
              _tallyLine(widget.deviceName, tally.remote),
            ],
          ],
        ),
      ),
    );
  }

  /// Both unchanged counts stay separate: the fast path versus a rehash
  /// that found nothing changed (SPEC §5.2), which is the whole point of
  /// the tally reaching a head at all.
  Widget _tallyLine(String side, SyncRunScanSide s) => Text(
    '$side: ${s.total} paths — ${s.metadataMatched} unchanged by metadata, '
    '${s.hashMatched} unchanged by hash, ${s.modified} modified, '
    '${s.created} created, ${s.deleted} deleted',
  );
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
  const _CountsRow(this.state, {required this.deviceName});

  final SyncRunViewState state;
  final String deviceName;

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
    return _PendingCounts(
      key: const Key('run-summary'),
      state: state,
      deviceName: deviceName,
    );
  }
}

/// The counts row before the run is over: how much of the plan moves in
/// each direction (Design C.3), folded once by `recordPlan` and read from
/// [SyncRunViewState.planSections] rather than walked here, plus the
/// unresolved-conflict count already on [SyncRunViewState.conflicts]. The
/// live Applied/Failed pair joins them while the run applies the plan —
/// what `_PlanTally` used to show under the plan's own disclosure.
class _PendingCounts extends StatelessWidget {
  const _PendingCounts({
    super.key,
    required this.state,
    required this.deviceName,
  });

  final SyncRunViewState state;
  final String deviceName;

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
                'to $deviceName ${formatCount(toDevice.count)}'
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
    children: [Icon(icon, size: 16), const SizedBox(width: 4), Text(text)],
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

/// Reports its child's laid-out height to [onExtent], and zero once it
/// leaves the tree. The run page pads its body by the decision sheet's real
/// extent, and the sheet's height is its content's, bounded by a share of
/// the screen — a number only layout has.
class _MeasuredHeight extends StatefulWidget {
  const _MeasuredHeight({required this.onExtent, required this.child});

  final ValueChanged<double> onExtent;
  final Widget child;

  @override
  State<_MeasuredHeight> createState() => _MeasuredHeightState();
}

class _MeasuredHeightState extends State<_MeasuredHeight> {
  @override
  void dispose() {
    // After the frame that removes this, not during it: the listener is a
    // rebuild of the page, and the page is mid-build right now.
    final onExtent = widget.onExtent;
    WidgetsBinding.instance.addPostFrameCallback((_) => onExtent(0));
    super.dispose();
  }

  void _report() {
    if (!mounted) return;
    final size = context.size;
    if (size != null) widget.onExtent(size.height);
  }

  @override
  Widget build(BuildContext context) {
    // The first layout, and every rebuild's; the notifier below catches the
    // resizes that no rebuild of this widget accompanies.
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _report());
        return false;
      },
      child: SizeChangedLayoutNotifier(child: widget.child),
    );
  }
}

/// The conflict sheet (SPEC §11.3): what the plan weighs, conflicts first,
/// each with the choices it offers, then every proposed action with a
/// keep/skip switch, then "Accept all" (the `--batch` answer) and "Confirm".
/// Reads the rendered rows and calls the controller's input methods; decides
/// nothing itself.
///
/// The page's body hides its own plan and conflict lists while this is up,
/// so these are the only rows for those paths on screen — and the only ones
/// that do anything.
class _DecisionSheet extends StatelessWidget {
  const _DecisionSheet({
    required this.conflicts,
    required this.actions,
    required this.bytesToTransfer,
    required this.deviceName,
    required this.controller,
  });

  final List<SyncRunConflictDecision> conflicts;
  final List<SyncRunActionDecision> actions;
  final int bytesToTransfer;
  final String deviceName;
  final SyncRunController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('run-decisions'),
      elevation: 8,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Review before applying',
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    'Plan: ${actions.length} action(s), '
                    '${formatBytes(bytesToTransfer)} to transfer',
                    key: const Key('run-plan-summary'),
                    style: theme.textTheme.titleSmall,
                  ),
                ],
              ),
            ),
            Flexible(
              // A builder, not a `ListView(children: [...])`: the sheet's
              // plan is the whole run's, and every row it holds is a
              // `SwitchListTile` with a `SegmentedButton` in the conflicts
              // above it. `shrinkWrap: true` would defeat that by measuring
              // every child anyway; the enclosing `ConstrainedBox` bounds
              // this list's height, which is what the shrink-wrap was for.
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                // Conflicts first, then actions: SPEC §11.3's order, and
                // the order the events arrived in.
                itemCount: conflicts.length + actions.length,
                itemBuilder: (context, index) {
                  if (index < conflicts.length) {
                    return _ConflictDecision(
                      conflicts[index],
                      deviceName: deviceName,
                      controller: controller,
                    );
                  }
                  final row = actions[index - conflicts.length];
                  return SwitchListTile(
                    key: Key('decision-${row.path}'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(row.path),
                    subtitle: Text('${row.action} · ${formatBytes(row.bytes)}'),
                    value: row.kept,
                    onChanged: (kept) => kept
                        ? controller.keep(row.path)
                        : controller.skip(row.path),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('run-accept-all'),
                    onPressed: controller.acceptAll,
                    child: const Text('Accept all, leave conflicts'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('run-confirm'),
                    onPressed: controller.confirm,
                    child: const Text('Confirm'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One conflict's row: both sides' status words and a segmented choice
/// over exactly the directions the row offers.
class _ConflictDecision extends StatelessWidget {
  const _ConflictDecision(
    this.row, {
    required this.deviceName,
    required this.controller,
  });

  final SyncRunConflictDecision row;
  final String deviceName;
  final SyncRunController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: Key('decision-${row.path}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(row.path, style: theme.textTheme.titleSmall),
          _NoticeLine.error(
            'Conflict: this device ${row.local}, $deviceName ${row.remote}',
          ),
          const SizedBox(height: 4),
          SegmentedButton<SyncRunConflictChoice>(
            segments: [
              for (final choice in row.offered)
                ButtonSegment(value: choice, label: Text(_label(choice))),
            ],
            selected: {row.choice},
            onSelectionChanged: (selected) =>
                controller.resolveConflict(row.path, selected.single),
          ),
        ],
      ),
    );
  }

  String _label(SyncRunConflictChoice choice) => switch (choice) {
    SyncRunConflictChoice.unresolved => 'Leave',
    SyncRunConflictChoice.keepLocal => 'Keep this device',
    SyncRunConflictChoice.keepRemote => 'Keep $deviceName',
    SyncRunConflictChoice.keepBoth => 'Keep both',
  };
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

/// The confirmation the system back gesture puts in front of a live run:
/// leaving is an abort, worded as one, and the cancel is the default way
/// out. Stop is not offered here — it is one tap away in the app bar, and
/// this dialog's only job is to make the silent path deliberate.
class _AbortDialog extends StatelessWidget {
  const _AbortDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('run-abort-dialog'),
      title: const Text('Leave and stop this sync?'),
      content: const Text(
        'This sync is still running. Leaving stops it where it is; '
        'anything already applied stays applied.',
      ),
      actions: [
        TextButton(
          key: const Key('run-abort-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep syncing'),
        ),
        FilledButton(
          key: const Key('run-abort-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Leave and stop'),
        ),
      ],
    );
  }
}
