import 'dart:async';

import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/run/run_metrics_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'run_controller.dart';

/// Opens the Timings sheet over the Run page (SPEC §17).
///
/// A modal sheet rather than a route, for the reason `RunPage`'s own doc
/// comment gives: that page holds no `Navigator` of its own, and the
/// decision sheet (SPEC §11.3) is already its persistent bottom sheet. This
/// one is *modal* and stacks over it — a run suspended on a conflict prompt
/// is a run whose timings someone may well want to read, and neither sheet
/// should close the other.
Future<void> showRunTimings(
  BuildContext context,
  SyncRunController controller,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => RunTimingsSheet(controller: controller),
);

/// Where the run went, on the device it went there on (SPEC §17).
///
/// **Why the head needs this at all.** The CLI already prints the same
/// numbers behind `--timings`, but a desktop's link to a desktop is not the
/// one that hurts: this head's whole cost profile — a phone's flash for every
/// archive commit, a phone's radio for every round trip, a phone's power
/// management deciding when either of those happens — exists nowhere else and
/// cannot be simulated from a laptop. A run that takes twenty minutes on a
/// tree of 14k small files is diagnosable only from the device that took
/// twenty minutes.
///
/// **Live, not a post-mortem.** The snapshot is re-taken on a timer while the
/// sheet is open, because the question "why is this so slow" is asked *during*
/// the slow run, not after it. [SyncRunController.metricsSnapshot] is safe to
/// call mid-run by construction — a phase still open simply is not in the map
/// yet.
class RunTimingsSheet extends StatefulWidget {
  const RunTimingsSheet({super.key, required this.controller});

  final SyncRunController controller;

  @override
  State<RunTimingsSheet> createState() => _RunTimingsSheetState();
}

class _RunTimingsSheetState extends State<RunTimingsSheet> {
  /// Slow enough that a run being measured is not also being profiled by its
  /// own report, fast enough that a number a user is watching visibly moves.
  static const _refreshInterval = Duration(seconds: 1);

  late RunMetrics _metrics = widget.controller.metricsSnapshot();
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(_refreshInterval, (_) {
      if (!mounted) return;
      setState(() => _metrics = widget.controller.metricsSnapshot());
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        // Tall enough to show a phase list and one replica's table without
        // scrolling on a phone, short enough that the run behind it is still
        // visible as context.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Timings', style: theme.textTheme.titleLarge),
                  ),
                  // The realistic path from a number on someone's phone to
                  // whoever is fixing the protocol is a paste into a message,
                  // so the shareable rendering is one tap from the readable
                  // one — and it is `dsync_core`'s own text, the same string
                  // `dsync sync --timings` prints, so a report from a phone
                  // and a report from a desktop can be read side by side.
                  IconButton(
                    key: const Key('run-timings-copy'),
                    icon: const Icon(Icons.copy_all),
                    tooltip: 'Copy report',
                    onPressed: _copy,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  _Headline(metrics: _metrics),
                  const SizedBox(height: 16),
                  _PhaseTable(metrics: _metrics),
                  for (final replica in _metrics.replicas.values) ...[
                    const SizedBox(height: 24),
                    _ReplicaTable(replica: replica),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: formatRunMetrics(_metrics)));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Timings report copied')));
  }
}

/// The three numbers that decide which question to ask next: how long, how
/// many requests, how many bytes.
///
/// They lead because they are the ones that separate the two failure modes
/// this report exists to tell apart — a run that is slow because the link is
/// slow moves the same bytes in the same number of requests as a fast one,
/// while a run that is slow because it is chatty shows it here before any
/// table is read.
class _Headline extends StatelessWidget {
  const _Headline({required this.metrics});

  final RunMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 24,
      runSpacing: 12,
      children: [
        _Stat(
          label: 'elapsed',
          value: formatMetricDuration(metrics.elapsed),
          style: theme,
        ),
        _Stat(
          label: 'agent operations',
          value: formatMetricCount(metrics.opCount),
          style: theme,
        ),
        _Stat(
          label: 'on the wire',
          value: formatMetricBytes(metrics.wireBytes),
          style: theme,
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.style});

  final String label;
  final String value;
  final ThemeData style;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(value, style: style.textTheme.headlineSmall),
      Text(
        label,
        style: style.textTheme.labelMedium?.copyWith(
          color: style.colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

/// Every phase in flow order, so the list reads as the run did.
///
/// Ordered by [RunPhase.values] rather than by duration — unlike the
/// operation tables below, which sort slowest-first. A phase list is a
/// timeline and reordering it would break the one thing it says; an operation
/// table is a ranking and leaving it unsorted would hide the one thing it
/// says.
class _PhaseTable extends StatelessWidget {
  const _PhaseTable({required this.metrics});

  final RunMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Phases', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        for (final phase in RunPhase.values)
          _Row(
            cells: [
              phase.name,
              // A phase the run never reached shows a dash, never "0 ms":
              // `compact` is skipped outright by a run that committed
              // nothing (SPEC §8.2), and reading that as "instant" would be
              // wrong in the one direction that matters.
              metrics.phases[phase] == null
                  ? '—'
                  : formatMetricDuration(metrics.phases[phase]!),
            ],
            flex: const [3, 2],
            muted: metrics.phases[phase] == null,
          ),
      ],
    );
  }
}

/// One replica's operations, slowest first.
class _ReplicaTable extends StatelessWidget {
  const _ReplicaTable({required this.replica});

  final ReplicaMetrics replica;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final ops = replica.ops.entries.toList()
      ..sort((a, b) => b.value.total.compareTo(a.value.total));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Replica ${replica.side} — ${replica.remote ? 'the peer' : 'this device'}',
          style: theme.textTheme.titleMedium,
        ),
        Text(
          replica.remote
              ? '${formatMetricCount(replica.opCount)} operations · '
                    '${formatMetricBytes(replica.wireBytesSent)} sent · '
                    '${formatMetricBytes(replica.wireBytesReceived)} received'
              : '${formatMetricCount(replica.opCount)} operations · '
                    '${formatMetricBytes(replica.payloadBytes)} of file content',
          style: subtitle,
        ),
        // What the transport was made to do, rather than only how much it
        // carried (SPEC §17): a send is a flush and costs about a link
        // latency whatever rides on it, so these are what say whether the
        // ceiling is the protocol's shape or the radio.
        //
        // `writes` and frames/write are on this side of the copy button and
        // not only in the copied report, because the phone is the only place
        // §4.2's coalescing can be measured at all — a flush there costs TLS
        // and a radio, which is what makes frames queue behind it. Omitted
        // rather than shown as zero for a transport that reported none.
        if (replica.remote)
          Text(
            '${formatMetricCount(replica.sends)} sends · '
            '${switch (replica.writes) {
              final count? => '${formatMetricCount(count)} writes · ',
              null => '',
            }}'
            '${formatMetricCount(replica.framesSent)} frames · '
            '${formatMetricBytes(replica.meanFrameBytes.round())} mean frame · '
            '${switch (replica.framesPerWrite) {
              final ratio? => '${ratio.toStringAsFixed(2)} frames/write · ',
              null => '',
            }}'
            '${replica.sendsPerOp.toStringAsFixed(2)} sends/operation',
            style: subtitle,
          ),
        const SizedBox(height: 8),
        // `queue`, `wire` and `far` rather than one `mean`, with `total` and
        // `max` left to the copied report: the splits are the whole point of
        // this table. A mean that rose because the window filled up, one that
        // rose because the link slowed, and one that rose because the
        // destination's disk slowed look identical bundled together, and the
        // three have different fixes. `far` is what the peer says the
        // operation cost *it*, so `wire` minus `far` is the link — and `—`
        // means the peer did not report, not that it was free.
        _Row(
          cells: const ['operation', 'count', 'queue', 'wire', 'far'],
          flex: const [4, 2, 2, 2, 2],
          header: true,
        ),
        for (final MapEntry(key: op, value: stats) in ops)
          _Row(
            cells: [
              op.name,
              formatMetricCount(stats.count),
              formatMetricDuration(stats.meanQueueWait),
              formatMetricDuration(stats.meanWireTime),
              formatMetricSplit(stats.meanFarSide),
            ],
            flex: const [4, 2, 2, 2, 2],
          ),
        if (replica.remote && replica.idle.isNotEmpty) ...[
          const SizedBox(height: 12),
          // The gaps between bytes moving. A phase that went idle for most of
          // itself was waiting on the link, and wants fewer round trips or
          // more of them in flight; one that was busy throughout wants
          // neither, and no byte count can tell the two apart.
          Text('Idle link', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final phase in RunPhase.values)
            if (replica.idle[phase] case final value?)
              _Row(
                cells: [phase.name, formatMetricDuration(value)],
                flex: const [3, 2],
              ),
        ],
      ],
    );
  }
}

/// One line of either table: a label on the left, figures right-aligned so
/// they can be compared down the column rather than read one at a time.
class _Row extends StatelessWidget {
  const _Row({
    required this.cells,
    required this.flex,
    this.header = false,
    this.muted = false,
  });

  final List<String> cells;
  final List<int> flex;
  final bool header;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style =
        (header ? theme.textTheme.labelSmall : theme.textTheme.bodySmall)
            ?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: muted || header
                  ? theme.colorScheme.onSurfaceVariant
                  : null,
            );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            Expanded(
              flex: flex[i],
              child: Text(
                cells[i],
                style: style,
                textAlign: i == 0 ? TextAlign.start : TextAlign.end,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}
