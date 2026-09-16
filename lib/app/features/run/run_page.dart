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
          SyncRunAwaitingDecisions(:final conflicts, :final actions) =>
            _DecisionSheet(
              conflicts: conflicts,
              actions: actions,
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
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _PhaseLine(state),
            if (state.header case final header?) _Header(header),
            if (state.scanTally case final tally?)
              _ScanTally(tally, deviceName: widget.request.deviceName),
            if (state.unreadablePaths.isNotEmpty)
              _Lines(
                key: const Key('run-unreadable'),
                title: 'Could not read',
                lines: state.unreadablePaths,
                error: true,
              ),
            if (state.skippedSymlinks.isNotEmpty)
              _Lines(
                key: const Key('run-symlinks'),
                title: 'Symlinks not followed',
                lines: state.skippedSymlinks,
                error: false,
              ),
            if (state.conflicts.isNotEmpty) _Conflicts(state.conflicts),
            if (state.plan.isNotEmpty)
              _Plan(
                state.plan,
                bytesToTransfer: state.bytesToTransfer,
                results: state.results,
              ),
          ],
        ),
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

class _Lines extends StatelessWidget {
  const _Lines({
    super.key,
    required this.title,
    required this.lines,
    required this.error,
  });

  final String title;
  final List<String> lines;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          for (final line in lines)
            Text(
              line,
              style: error ? TextStyle(color: theme.colorScheme.error) : null,
            ),
        ],
      ),
    );
  }
}

class _Conflicts extends StatelessWidget {
  const _Conflicts(this.conflicts);

  final List<SyncRunConflictRow> conflicts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        key: const Key('run-conflicts'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Conflicts (not resolved)', style: theme.textTheme.titleSmall),
          for (final row in conflicts)
            Text(
              '${row.path}: this device ${row.local}, the other side '
              '${row.remote}',
              style: TextStyle(color: theme.colorScheme.error),
            ),
        ],
      ),
    );
  }
}

/// The conflict sheet (SPEC §11.3): conflicts first, each with the choices
/// it offers, then every proposed action with a keep/skip switch, then
/// "Accept all" (the `--batch` answer) and "Confirm". Reads the rendered
/// rows and calls the controller's input methods; decides nothing itself.
class _DecisionSheet extends StatelessWidget {
  const _DecisionSheet({
    required this.conflicts,
    required this.actions,
    required this.deviceName,
    required this.controller,
  });

  final List<SyncRunConflictDecision> conflicts;
  final List<SyncRunActionDecision> actions;
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
              child: Text(
                'Review before applying',
                style: theme.textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final row in conflicts)
                    _ConflictDecision(
                      row,
                      deviceName: deviceName,
                      controller: controller,
                    ),
                  for (final row in actions)
                    SwitchListTile(
                      key: Key('decision-${row.path}'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(row.path),
                      subtitle: Text(
                        '${row.action} · ${formatBytes(row.bytes)}',
                      ),
                      value: row.kept,
                      onChanged: (kept) => kept
                          ? controller.keep(row.path)
                          : controller.skip(row.path),
                    ),
                ],
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

/// The plan, with each row marked off by its own result once it has one.
class _Plan extends StatelessWidget {
  const _Plan(
    this.plan, {
    required this.bytesToTransfer,
    required this.results,
  });

  final List<SyncRunPlanRow> plan;
  final int bytesToTransfer;
  final List<SyncRunResultRow> results;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byPath = {for (final result in results) result.path: result};
    return Column(
      key: const Key('run-plan'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Plan: ${plan.length} action(s), ${formatBytes(bytesToTransfer)} '
          'to transfer',
          style: theme.textTheme.titleSmall,
        ),
        for (final row in plan)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: _resultIcon(byPath[row.path], theme),
            title: Text(row.path),
            subtitle: Text(
              byPath[row.path]?.error ??
                  '${row.action} · ${formatBytes(row.bytes)}',
            ),
          ),
      ],
    );
  }

  Widget _resultIcon(SyncRunResultRow? result, ThemeData theme) {
    if (result == null) return const Icon(Icons.radio_button_unchecked);
    if (result.error == null) return const Icon(Icons.check_circle_outline);
    return Icon(Icons.error_outline, color: theme.colorScheme.error);
  }
}
