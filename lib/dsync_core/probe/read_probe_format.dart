import 'package:dsync/dsync_core/models/read_probe_report.dart';
import 'package:dsync/dsync_core/run/run_metrics_report.dart';

/// Renders a [ReadProbeReport] as plain text (task 8347dd).
///
/// Formatted with SPEC §17's own formatters, for the reason `formatScanProbe`
/// gives: a rate here is read directly against `readFile`'s per-operation
/// figure and apply's throughput there, so the two reports must agree on what
/// a number looks like.
///
/// **The table is per mode, not one flat list**, because the thing being read
/// off it is each mode's curve against depth — where it flattens and at what
/// value. A single table sorted by anything else hides exactly that.
String formatReadProbe(ReadProbeReport report) {
  final out = StringBuffer();
  out.writeln('read probe: ${report.rootPath}');
  out.writeln(
    '  tree ${formatMetricCount(report.files)} files, '
    '${formatMetricBytes(report.bytes)}, '
    'mean ${formatMetricBytes(report.meanFileSize.round())}/file',
  );

  if (report.samples.isEmpty) {
    out.writeln('  nothing measured');
    return out.toString();
  }

  for (final mode in ReadProbeMode.values) {
    final samples = report.forMode(mode).toList();
    if (samples.isEmpty) continue;
    out.writeln();
    out.writeln(readProbeModeLabel(mode));
    out.writeln(
      '  ${'depth'.padLeft(5)}${'elapsed'.padLeft(10)}'
      '${'files/s'.padLeft(10)}${'MiB/s'.padLeft(9)}${'µs/file'.padLeft(10)}',
    );
    for (final sample in samples) {
      out.writeln(
        '  ${sample.depth.toString().padLeft(5)}'
        '${formatMetricDuration(sample.elapsed).padLeft(10)}'
        '${sample.filesPerSecond.toStringAsFixed(0).padLeft(10)}'
        '${_mibPerSecond(sample).toStringAsFixed(2).padLeft(9)}'
        '${sample.microsPerFile.toStringAsFixed(0).padLeft(10)}',
      );
    }
  }

  final fastest = report.fastest;
  if (fastest != null) {
    out.writeln();
    out.writeln(
      'fastest: ${readProbeModeLabel(fastest.mode)} at depth '
      '${fastest.depth} — ${_mibPerSecond(fastest).toStringAsFixed(2)} MiB/s, '
      '${fastest.microsPerFile.toStringAsFixed(0)} µs/file',
    );
  }

  out.writeln();
  out.writeln(
    'The first sample of the first mode is the only one whose cache state is '
    'unknown; nothing here can drop a page cache on Android. Read each mode '
    'as a curve — where it flattens, and at what value — rather than as a '
    'best figure. Every sample read the whole tree, so the mean file size '
    'above is the tree\'s own and the rates below are the rates for it; '
    'three sampled corpora were tried before this and each reported a '
    'different device.',
  );

  return out.toString();
}

/// What each mode is called on screen and in the text. Short enough for a
/// phone-width heading; [ReadProbeMode] carries what each one means.
String readProbeModeLabel(ReadProbeMode mode) => switch (mode) {
  ReadProbeMode.asyncStream => 'async openRead (what a run does)',
  ReadProbeMode.asyncBytes => 'async readAsBytes',
  ReadProbeMode.syncIsolates => 'sync readAsBytesSync, in isolates',
};

double _mibPerSecond(ReadProbeSample sample) =>
    sample.bytesPerSecond / (1024 * 1024);
