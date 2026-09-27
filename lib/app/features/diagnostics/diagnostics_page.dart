import 'package:flutter/material.dart';

import 'diagnostics_controller.dart';
import 'diagnostics_scope.dart';
import 'diagnostics_view_state.dart';
import 'scan_cost_sheet.dart';

/// The Diagnostics page: measure what this device costs, over the replica a
/// run is (or was) syncing.
///
/// Reached from the Run page's app bar, which is where the question these
/// answer is actually asked — "why was that slow" is asked looking at a run,
/// and the root a probe needs is the one that run was over (the running
/// entry's folder, from the run's view). It is a page rather than another
/// sheet because its probe runs for minutes and ends in a report of its own; a
/// sheet that spawns sheets is not a place to wait. (The read-rate probe
/// measured the Dart core's I/O and went with it, plan D11.)
///
/// **Nothing here starts, changes or reads a run.** The probe lists files
/// that are already on this device and counts — see [DiagnosticsController].
///
/// [blockedReason] is the one thing the Run feature tells this page: a
/// non-null value disables the probe and is shown as the reason. A probe
/// competing with a live run for the same storage measures neither honestly
/// and slows the run it was opened to explain.
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({
    super.key,
    required this.rootPath,
    required this.blockedReason,
  });

  /// The local replica root the probe measures, fixed for this page's life.
  final String rootPath;

  /// Why the probe may not run, or `null` when it may.
  final String? blockedReason;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  // The cached scope controller rather than `create()`, for the reason the
  // Run setup page gives: a probe is asynchronous and runs for minutes, and a
  // controller disposed by a page the user left would have its view state
  // written to after disposal.
  final DiagnosticsController _controller = diagnosticsScope.controller;

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(widget.rootPath, style: Theme.of(context).textTheme.bodySmall),
            if (widget.blockedReason case final reason?) ...[
              const SizedBox(height: 12),
              _Blocked(reason: reason),
            ],
            const SizedBox(height: 20),
            _Probe(
              keyPrefix: 'scan-cost',
              title: 'Scan cost',
              description:
                  'Walks the tree several times, adding one step each pass, '
                  'so a scan\'s time splits into the platform\'s floor and '
                  'this app\'s own code. Minutes.',
              busy: switch (state.scanCost) {
                ScanCostMeasuring() => const _Busy(),
                _ => null,
              },
              error: switch (state.scanCost) {
                ScanCostFailed(:final message) => message,
                _ => null,
              },
              onRun: _blocked ? null : _measureScanCost,
              onShow: switch (state.scanCost) {
                ScanCostMeasured(:final report) => () => showScanCost(
                  context,
                  report,
                ),
                _ => null,
              },
            ),
          ],
        ),
      ),
    );
  }

  bool get _blocked => widget.blockedReason != null;

  Future<void> _measureScanCost() =>
      _controller.measureScanCost(widget.rootPath);
}

/// Why the probe is disabled. An icon as well as the colour, so the
/// warning does not depend on colour alone.
class _Blocked extends StatelessWidget {
  const _Blocked({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(reason, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

/// One probe's block: what it does, the button that runs it, whatever it is
/// doing now, and the way back to its last report.
///
/// The two probes differ only in their text and their callbacks, so they are
/// one widget configured twice rather than two that would drift apart.
class _Probe extends StatelessWidget {
  const _Probe({
    required this.keyPrefix,
    required this.title,
    required this.description,
    required this.busy,
    required this.error,
    required this.onRun,
    required this.onShow,
  });

  final String keyPrefix;
  final String title;
  final String description;

  /// What to show while it runs, or `null` when it is not running. A widget
  /// rather than a flag because the two probes have different things to say
  /// about their progress — one knows how far along it is and one does not.
  final Widget? busy;

  final String? error;

  /// `null` disables the run button — a probe already running, or one the
  /// page is blocking.
  final Future<void> Function()? onRun;

  /// `null` when there is no report yet.
  final VoidCallback? onShow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = busy != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(description, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        if (running)
          busy!
        else
          FilledButton.tonal(
            key: Key('$keyPrefix-run'),
            onPressed: onRun == null ? null : () => onRun!(),
            child: const Text('Measure'),
          ),
        if (error case final message?) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline,
                size: 20,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (onShow != null) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            key: Key('$keyPrefix-show'),
            onPressed: onShow,
            icon: const Icon(Icons.article_outlined),
            label: const Text('Show report'),
          ),
        ],
      ],
    );
  }
}

/// A probe in flight, labelled so a screen reader has something to read.
class _Busy extends StatelessWidget {
  const _Busy();

  @override
  Widget build(BuildContext context) {
    const text = 'Measuring';
    return Row(
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            semanticsLabel: text,
          ),
        ),
        const SizedBox(width: 12),
        Text(text, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}
