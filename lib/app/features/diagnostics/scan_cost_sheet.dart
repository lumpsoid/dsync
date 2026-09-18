import 'package:dsync/dsync_core/models/scan_probe_report.dart';
import 'package:dsync/dsync_core/run/run_metrics_report.dart';
import 'package:dsync/dsync_core/scan/scan_probe_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens the scan-cost report over the Diagnostics page (task 1a341e).
Future<void> showScanCost(BuildContext context, ScanProbeReport report) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ScanCostSheet(report: report),
    );

/// Where a scan's time goes on the device it goes there on (task 1a341e).
///
/// The sibling of the Timings sheet, one level down. SPEC §17 measures a run
/// by §13's phases and reports `scan` as one number; this is the split
/// *inside* that number, which §17 deliberately does not carry (see
/// [RunPhase]'s own doc comment). The two are read together — a `scan` phase
/// duration there, and where those seconds went here — which is why this
/// renders with §17's own formatters rather than its own.
///
/// Every rung is a full walk of the tree doing strictly what the rung below
/// it did plus one named step, so the difference between two adjacent rows is
/// that step's cost. On screen this shows the ladder and the one subtraction
/// task 1a341e asked for — the platform's floor against what this code adds
/// on top of it. The *per-step* attribution, each figure printed beside the
/// two rows it came from, is in the text behind the copy button: SPEC §17's
/// rule is that a conclusion comes from a number the report shows, and a
/// subtracted number only qualifies if its derivation is visible, which is a
/// block of text rather than something a phone-width table can carry.
class ScanCostSheet extends StatelessWidget {
  const ScanCostSheet({super.key, required this.report});

  final ScanProbeReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
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
                    child: Text('Scan cost', style: theme.textTheme.titleLarge),
                  ),
                  // Same reasoning as the Timings sheet's copy button: the
                  // realistic path from a number measured on a phone to
                  // whoever is fixing the scanner is a paste into a message,
                  // and the text is `dsync_core`'s own — identical to what
                  // `benchmark/scan_probe.dart` prints, so a phone report and
                  // a desktop report can be read side by side.
                  IconButton(
                    key: const Key('scan-cost-copy'),
                    icon: const Icon(Icons.copy_all),
                    tooltip: 'Copy report',
                    onPressed: () => _copy(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Text(report.rootPath, style: theme.textTheme.bodySmall),
                  for (final pass in report.passes) ...[
                    const SizedBox(height: 20),
                    _Pass(pass: pass),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: formatScanProbe(report)));
    messenger.showSnackBar(
      const SnackBar(content: Text('Scan cost report copied')),
    );
  }
}

class _Pass extends StatelessWidget {
  const _Pass({required this.pass});

  final ScanProbePass pass;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final floor = pass[ScanProbeLayer.stat];
    final full = pass[ScanProbeLayer.scanEmptyArchive];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          // Nothing here can drop Android's page cache, so no pass is called
          // cold: pass 0 is whatever state the device was already in, and
          // every later one is warm. A later pass matching pass 0 says the
          // cost is CPU and therefore code; one much faster says it is I/O.
          pass.index == 0 ? 'Pass 0' : 'Pass ${pass.index} (warm)',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Table(
          columnWidths: const {
            0: FlexColumnWidth(),
            1: IntrinsicColumnWidth(),
            2: IntrinsicColumnWidth(),
          },
          children: [
            _row(theme, 'layer', 'elapsed', 'µs/file', header: true),
            for (final layer in ScanProbeLayer.values)
              if (pass[layer] case final result?)
                _row(
                  theme,
                  scanProbeLayerLabel(layer),
                  formatMetricDuration(result.elapsed),
                  result.microsPerFile.toStringAsFixed(0),
                ),
          ],
        ),
        if (floor != null && full != null) ...[
          const SizedBox(height: 12),
          // The one line task 1a341e asked for.
          Text(
            'Platform floor ${formatMetricDuration(floor.elapsed)} · '
            'this code ${formatMetricDuration(full.elapsed - floor.elapsed)}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }

  TableRow _row(
    ThemeData theme,
    String label,
    String elapsed,
    String perFile, {
    bool header = false,
  }) {
    final style = header
        ? theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          )
        : theme.textTheme.bodySmall;
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(label, style: style),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Text(elapsed, style: style, textAlign: TextAlign.right),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Text(perFile, style: style, textAlign: TextAlign.right),
        ),
      ],
    );
  }
}
