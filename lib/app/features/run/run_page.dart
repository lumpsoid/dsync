import 'package:flutter/material.dart';

import '../../run_request.dart';
import 'run_controller.dart';
import 'run_scope.dart';
import 'run_view_state.dart';

/// The Run page: drive a run for [request] and render its `RunEvent`s
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
/// **Backgrounding does not stop the run.** No `WidgetsBindingObserver`
/// here: `SyncRunController`'s doc comment says what bounds a wedged
/// session (the heartbeat deadline), and why a lifecycle callback that
/// stopped the run would be wrong.
///
/// **The screen is not kept awake.** SPEC's requirement stands and is not
/// met: the Flutter SDK pinned in `pubspec.yaml` exposes no keep-screen-on
/// API (`SystemChrome` has none), and meeting it needs either the
/// `wakelock_plus` plugin or a `MethodChannel` into `android/` and `ios/`
/// — a dependency or platform code, both out of this feature's hands. A
/// device that sleeps mid-run is the backgrounding case above: the run is
/// not torn down by the page, and the heartbeat deadline is what ends it
/// if the OS suspends the process for long enough.
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

  /// What the body's plan section follows: the plan itself, and the phase
  /// that decides whether the body shows it at all. Built once and not per
  /// build, so a rebuild does not swap the section's listeners.
  late final Listenable _planSection = Listenable.merge([
    _controller.state.planChanged,
    _controller.state.phaseChanged,
  ]);

  @override
  void initState() {
    super.initState();
    _controller.start(widget.request);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return Scaffold(
      appBar: AppBar(
        title: Text('Sync with ${widget.request.deviceName}'),
        actions: [
          ListenableBuilder(
            listenable: state,
            builder: (context, _) => switch (state.phase) {
              SyncRunIdle() ||
              SyncRunConnecting() ||
              SyncRunRunning() ||
              SyncRunAwaitingDecisions() => TextButton(
                key: const Key('run-stop'),
                onPressed: _controller.stop,
                child: const Text('Stop'),
              ),
              SyncRunFinished() ||
              SyncRunStopped() ||
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
            _DecisionSheet(
              conflicts: conflicts,
              actions: actions,
              bytesToTransfer: bytesToTransfer,
              deviceName: widget.request.deviceName,
              controller: _controller,
            ),
          SyncRunIdle() ||
          SyncRunConnecting() ||
          SyncRunRunning() ||
          SyncRunFinished() ||
          SyncRunStopped() ||
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
      // conflicts — and follows the view state itself. The plan deliberately
      // does not: it arrives whole in one `RunPlanEvent`, and the apply loop
      // then reports one result per action. So the plan section follows
      // `planChanged` and the phase (`_planSection`) — never the progress
      // or the path lists — and each row follows the cell for its own path
      // (`SyncRunViewState.resultCell`), which is what keeps applying action
      // N from rebuilding the rows above it — see the view state's class doc
      // comment and `_PlanRow`. The one part of the section that does follow
      // the view state is `_PlanTally`, which is a line and no rows.
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverMainAxisGroup(
              slivers: [
                ListenableBuilder(
                  listenable: state,
                  builder: (context, _) => SliverMainAxisGroup(
                    slivers: [
                      SliverToBoxAdapter(child: _PhaseLine(state)),
                      if (state.header case final header?)
                        SliverToBoxAdapter(child: _Header(header)),
                      if (state.scanTally case final tally?)
                        SliverToBoxAdapter(
                          child: _ScanTally(
                            tally,
                            deviceName: widget.request.deviceName,
                          ),
                        ),
                      if (state.unreadablePaths.isNotEmpty)
                        _ListSection(
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
                        _ListSection(
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
                        _ListSection(
                          sectionKey: const Key('run-conflicts'),
                          title: 'Conflicts (not resolved)',
                          itemCount: state.conflicts.length,
                          itemBuilder: (context, index) {
                            final row = state.conflicts[index];
                            return Text(
                              '${row.path}: this device ${row.local}, the '
                              'other side ${row.remote}',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
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
                      : _PlanSection(state),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One section of path rows: its title, then its rows, built lazily — the
/// rows the viewport holds are the rows that exist. The title is a sliver of
/// its own, so it is on the page whenever the section is, whatever part of
/// the section's list the viewport holds, and [sectionKey] is on that list:
/// "this section is shown at all" is still assertable while its rows come
/// and go with the scroll.
class _ListSection extends StatelessWidget {
  const _ListSection({
    required this.sectionKey,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
  });

  final Key sectionKey;
  final String title;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      // The section's trailing space, which was the padding of the box that
      // used to hold the title and the rows together.
      padding: const EdgeInsets.only(bottom: 16),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          SliverList.builder(
            key: sectionKey,
            itemCount: itemCount,
            itemBuilder: itemBuilder,
          ),
        ],
      ),
    );
  }
}

/// The run's phase, first on the page: what is happening now, or how it
/// ended.
class _PhaseLine extends StatelessWidget {
  const _PhaseLine(this.state);

  final SyncRunViewState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorStyle = TextStyle(color: theme.colorScheme.error);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: switch (state.phase) {
        SyncRunIdle() => const SizedBox.shrink(),
        SyncRunConnecting() => const Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Connecting…'),
          ],
        ),
        SyncRunRunning() => _Progress(state.progress, dryRun: state.dryRun),
        SyncRunAwaitingDecisions() => const Text(
          'Waiting for your decisions below.',
          key: Key('run-awaiting'),
        ),
        SyncRunFinished(
          :final applied,
          :final skipped,
          :final conflicts,
          :final failed,
          :final unreadable,
        ) =>
          Column(
            key: const Key('run-summary'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state.dryRun ? 'Dry run finished' : 'Finished',
                style: theme.textTheme.titleMedium,
              ),
              if (state.dryRun) const Text('Nothing was applied.'),
              // Five numbers, always: two of them (skipped, unreadable)
              // answer different questions and are never summed.
              Text('Applied: $applied'),
              Text('Skipped: $skipped'),
              Text('Conflicts: $conflicts'),
              Text('Failed: $failed', style: failed > 0 ? errorStyle : null),
              Text(
                'Unreadable: $unreadable',
                style: unreadable > 0 ? errorStyle : null,
              ),
            ],
          ),
        SyncRunStopped(:final completedActions) => Text(
          stoppedMessage(completedActions),
          key: const Key('run-stopped'),
        ),
        SyncRunFailed(:final message) => Text(
          message,
          key: const Key('run-failed'),
          style: errorStyle,
        ),
      },
    );
  }
}

/// While running: a bar once the apply phase has reported anything, an
/// indeterminate one before that (scanning, reconciling).
class _Progress extends StatelessWidget {
  const _Progress(this.progress, {required this.dryRun});

  final SyncRunProgress? progress;
  final bool dryRun;

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    return Column(
      key: const Key('run-progress'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          progress == null
              ? (dryRun ? 'Scanning (dry run)…' : 'Scanning…')
              : 'Applying ${progress.completed} of ${progress.total}…',
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: progress == null || progress.total == 0
              ? null
              : progress.completed / progress.total,
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.header);

  final SyncRunHeader header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        key: const Key('run-header'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This device: ${header.localRoot}'),
          Text('${header.deviceName}: ${header.remoteRoot}'),
          const SizedBox(height: 4),
          Text(header.history),
          if (header.firstSyncWarning case final warning?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                warning,
                key: const Key('run-first-sync-warning'),
                style: TextStyle(color: theme.colorScheme.tertiary),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScanTally extends StatelessWidget {
  const _ScanTally(this.tally, {required this.deviceName});

  final SyncRunScanTally tally;
  final String deviceName;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        key: const Key('run-scan-tally'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Scanned', style: Theme.of(context).textTheme.titleSmall),
          _tallyLine('This device', tally.local),
          _tallyLine(deviceName, tally.remote),
        ],
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

/// The plan section: its rows, except while the run is applying them.
///
/// Once the apply loop is running there is nothing left to decide, and
/// thousands of paths scrolling under the progress bar is not what someone
/// watches — the question is how far along it is and whether anything is
/// failing, which the progress line and this section's summary answer
/// together. So [SyncRunRunning] collapses the rows behind a disclosure and
/// every other phase shows them: finished, stopped and failed are over, and
/// the rows are the record of what happened.
///
/// Expansion is this widget's own state and not the view state's: it is a
/// rendering of no `RunEvent`, and it stays as the user left it — the outer
/// builder rebuilds this widget for the plan and the phase, which does not
/// touch [State].
class _PlanSection extends StatefulWidget {
  const _PlanSection(this.state);

  final SyncRunViewState state;

  @override
  State<_PlanSection> createState() => _PlanSectionState();
}

class _PlanSectionState extends State<_PlanSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final title =
        'Plan: ${state.plan.length} action(s), '
        '${formatBytes(state.bytesToTransfer)} to transfer';
    Widget row(BuildContext context, int index) =>
        _PlanRow(state: state, row: state.plan[index]);

    if (state.phase is! SyncRunRunning) {
      return _ListSection(
        sectionKey: const Key('run-plan'),
        title: title,
        itemCount: state.plan.length,
        itemBuilder: row,
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 16),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: InkWell(
              key: const Key('run-plan-disclosure'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        _PlanTally(state),
                      ],
                    ),
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (_expanded)
            SliverList.builder(
              key: const Key('run-plan'),
              itemCount: state.plan.length,
              itemBuilder: row,
            ),
        ],
      ),
    );
  }
}

/// What the results say so far, under the collapsed plan's title: the reason
/// to expand is a failure, so the failed count is what has to be readable
/// without expanding, in the error colour as the finished summary shows it.
///
/// Derived from `SyncRunViewState.results` here rather than counted into the
/// view state: the two numbers are this section's rendering and nothing else
/// asks for them. It follows the view state itself — which the apply loop
/// wakes once per action with its progress — and is deliberately the only
/// part of the section that does, so a result does not rebuild the title
/// above it or the rows below.
class _PlanTally extends StatelessWidget {
  const _PlanTally(this.state);

  final SyncRunViewState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        var applied = 0;
        var failed = 0;
        for (final result in state.results) {
          result.error == null ? applied++ : failed++;
        }
        return Row(
          key: const Key('run-plan-tally'),
          children: [
            Text('Applied: $applied'),
            const SizedBox(width: 12),
            Text(
              'Failed: $failed',
              style: failed > 0
                  ? TextStyle(color: Theme.of(context).colorScheme.error)
                  : null,
            ),
          ],
        );
      },
    );
  }
}

/// One plan row: what its action does, and its own result in the leading
/// icon once it has one. Follows the cell for its own path and nothing
/// else — which is what makes applying action N repaint action N's row
/// rather than the plan: the section above it follows `planChanged`, and a
/// result does not touch that.
class _PlanRow extends StatelessWidget {
  const _PlanRow({required this.state, required this.row});

  final SyncRunViewState state;
  final SyncRunPlanRow row;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SyncRunResultRow?>(
      valueListenable: state.resultCell(row.path),
      builder: (context, result, _) => ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: _resultIcon(result, Theme.of(context)),
        title: Text(row.path),
        subtitle: Text(
          result?.error ?? '${row.action} · ${formatBytes(row.bytes)}',
        ),
      ),
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
          Text(
            'Conflict: this device ${row.local}, $deviceName ${row.remote}',
            style: TextStyle(color: theme.colorScheme.error),
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
  };
}

/// The leading icon of a plan row: nothing reported yet, applied, or failed.
Widget _resultIcon(SyncRunResultRow? result, ThemeData theme) {
  if (result == null) return const Icon(Icons.radio_button_unchecked);
  if (result.error == null) return const Icon(Icons.check_circle_outline);
  return Icon(Icons.error_outline, color: theme.colorScheme.error);
}
