import 'package:dsync/dsync_core/models/read_probe_report.dart';
import 'package:dsync/dsync_core/probe/read_probe_format.dart';
import 'package:dsync/dsync_core/run/run_metrics_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens the read-rate report over the Diagnostics page (task 8347dd).
Future<void> showReadRate(BuildContext context, ReadProbeReport report) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ReadRateSheet(report: report),
    );

/// What this device's own files cost to read, by read mode and by how many
/// reads are in flight (task 8347dd).
///
/// **What it is read against.** SPEC §17 gives `readFile`'s mean during a run
/// and apply's throughput; §5.3 gives what a scan pays to read content. Both
/// describe the one shape this code has — `Applier.defaultConcurrency` reads
/// in flight, each consumed inside a remote write, all through `dart:io`'s
/// asynchronous API. This sheet is the same files read every other way, so
/// those numbers can be placed on a curve instead of standing alone.
///
/// **One table per mode**, because the thing to read off it is each mode's
/// shape against depth — where it stops rising, and at what value. That is
/// what separates a limit in the VM's thread pool from a limit in the
/// device, and a single table ordered any other way hides it. The subtraction
/// that matters — the asynchronous modes against the synchronous one at the
/// same depth — is left to the eye here and spelled out in the text behind
/// the copy button, on the same rule the Scan cost sheet follows: a
/// conclusion drawn from a derived number needs its derivation visible.
class ReadRateSheet extends StatelessWidget {
  const ReadRateSheet({super.key, required this.report});

  final ReadProbeReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fastest = report.fastest;
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
                    child: Text('Read rate', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    key: const Key('read-rate-copy'),
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
                  // The mean is what the rates below are read against: cost
                  // here is per-file dominated, so it is the number that says
                  // what a MiB/s on this screen means.
                  Text(
                    'Tree ${formatMetricCount(report.files)} files, '
                    '${formatMetricBytes(report.bytes)}, mean '
                    '${formatMetricBytes(report.meanFileSize.round())}/file',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (fastest != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Fastest: ${readProbeModeLabel(fastest.mode)} at depth '
                      '${fastest.depth}, '
                      '${_mibPerSecond(fastest).toStringAsFixed(2)} MiB/s',
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                  for (final mode in ReadProbeMode.values)
                    if (report.forMode(mode).isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _Mode(mode: mode, samples: report.forMode(mode).toList()),
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
    await Clipboard.setData(ClipboardData(text: formatReadProbe(report)));
    messenger.showSnackBar(
      const SnackBar(content: Text('Read rate report copied')),
    );
  }
}

class _Mode extends StatelessWidget {
  const _Mode({required this.mode, required this.samples});

  final ReadProbeMode mode;
  final List<ReadProbeSample> samples;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(readProbeModeLabel(mode), style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Table(
          columnWidths: const {
            0: IntrinsicColumnWidth(),
            1: FlexColumnWidth(),
            2: IntrinsicColumnWidth(),
          },
          children: [
            _row(theme, 'depth', 'MiB/s', 'µs/file', header: true),
            for (final sample in samples)
              _row(
                theme,
                sample.depth.toString(),
                _mibPerSecond(sample).toStringAsFixed(2),
                sample.microsPerFile.toStringAsFixed(0),
              ),
          ],
        ),
      ],
    );
  }
}

TableRow _row(
  ThemeData theme,
  String first,
  String second,
  String third, {
  bool header = false,
}) {
  final style = header
      ? theme.textTheme.labelSmall
      : theme.textTheme.bodyMedium;
  return TableRow(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(first, style: style),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 12),
        child: Text(second, style: style, textAlign: TextAlign.end),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(third, style: style, textAlign: TextAlign.end),
      ),
    ],
  );
}

double _mibPerSecond(ReadProbeSample sample) =>
    sample.bytesPerSecond / (1024 * 1024);
