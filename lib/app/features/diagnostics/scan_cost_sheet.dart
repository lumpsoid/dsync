import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_link/models/scan_probe_layer.dart';
import '../../core_link/models/scan_probe_result.dart';

/// Opens the scan-cost report over the Diagnostics page (task 1a341e).
Future<void> showScanCost(BuildContext context, ScanProbeResult report) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ScanCostSheet(report: report),
    );

/// Where a scan's time goes on the device it goes there on (task 1a341e).
///
/// The sibling of the Timings sheet, one level down: SPEC §17 measures a
/// run by §13's phases and reports `scan` as one number; this is the split
/// *inside* that number.
///
/// Every rung is a full walk of the tree doing strictly what the rung below
/// it did plus one named step, so the difference between two adjacent rows
/// is that step's cost. On screen this shows the ladder, per pass; the
/// per-step attribution, each figure printed beside the two rows it came
/// from, is the core's own text behind the copy button — SPEC §17's rule
/// is that a conclusion comes from a number the report shows, and a
/// subtracted number only qualifies if its derivation is visible, which is
/// a block of text rather than something a phone-width table can carry.
class ScanCostSheet extends StatelessWidget {
  const ScanCostSheet({super.key, required this.report});

  final ScanProbeResult report;

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
                  // and the text is the core's own report, so a phone
                  // report and a desktop one can be read side by side.
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
                  Text(report.root, style: theme.textTheme.bodySmall),
                  for (final (index, pass) in report.passes.indexed) ...[
                    const SizedBox(height: 20),
                    _Pass(index: index, layers: pass),
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
    await Clipboard.setData(ClipboardData(text: report.report));
    messenger.showSnackBar(
      const SnackBar(content: Text('Scan cost report copied')),
    );
  }
}

class _Pass extends StatelessWidget {
  const _Pass({required this.index, required this.layers});

  final int index;
  final List<ScanProbeLayer> layers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          // Nothing here can drop Android's page cache, so no pass is called
          // cold: pass 0 is whatever state the device was already in, and
          // every later one is warm. A later pass matching pass 0 says the
          // cost is CPU and therefore code; one much faster says it is I/O.
          index == 0 ? 'Pass 0' : 'Pass $index (warm)',
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
            for (final layer in layers)
              _row(
                theme,
                layer.label,
                _elapsed(layer.elapsed),
                layer.microsPerFile.toStringAsFixed(0),
              ),
          ],
        ),
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

/// A rung's time as the table shows it: milliseconds under ten seconds,
/// seconds with a tenth above.
String _elapsed(Duration elapsed) => elapsed < const Duration(seconds: 10)
    ? '${elapsed.inMilliseconds} ms'
    : '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s';
