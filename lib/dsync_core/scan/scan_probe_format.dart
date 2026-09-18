import 'package:dsync/dsync_core/models/scan_probe_report.dart';
import 'package:dsync/dsync_core/run/run_metrics_report.dart';

/// Renders a [ScanProbeReport] as plain text (task 1a341e).
///
/// **In `dsync_core`, and formatted with SPEC §17's own formatters.** The
/// realistic path from a number measured on someone's phone to whoever is
/// fixing the scanner is a paste into a message, exactly as
/// [formatRunMetrics] exists for — and a duration in this report is read
/// directly against a `scan` phase duration in that one, so the two must
/// agree on what "36.7 s" looks like. One formatter, not two that drift.
String formatScanProbe(ScanProbeReport report) {
  final out = StringBuffer();
  out.writeln('scan probe: ${report.rootPath}');

  final first = report.passes.firstOrNull;
  if (first == null) {
    out.writeln('  no passes run');
    return out.toString();
  }

  final floor = first[ScanProbeLayer.stat];
  if (floor != null) {
    out.writeln(
      '  ${formatMetricCount(floor.files)} files, '
      '${formatMetricBytes(floor.bytes)}, '
      '${formatMetricCount(floor.directories ?? 0)} directories',
    );
  }

  for (final pass in report.passes) {
    out.writeln();
    // Pass 0 is whatever cache state the device was already in; nothing here
    // can drop a page cache on Android, so no pass is labelled "cold".
    out.writeln('pass ${pass.index}${pass.index == 0 ? '' : ' (warm)'}');
    out.writeln(
      '  ${'layer'.padRight(24)}${'elapsed'.padLeft(10)}'
      '${'files'.padLeft(9)}${'µs/file'.padLeft(10)}',
    );
    for (final layer in ScanProbeLayer.values) {
      final result = pass[layer];
      if (result == null) continue;
      out.writeln(
        '  ${scanProbeLayerLabel(layer).padRight(24)}'
        '${formatMetricDuration(result.elapsed).padLeft(10)}'
        '${formatMetricCount(result.files).padLeft(9)}'
        '${result.microsPerFile.toStringAsFixed(0).padLeft(10)}',
      );
    }

    out.writeln();
    out.writeln('  attribution');
    var anyNegative = false;
    for (final step in _steps) {
      final above = pass[step.above];
      final below = step.below == null ? null : pass[step.below!];
      if (above == null || (step.below != null && below == null)) continue;
      final cost = above.elapsed - (below?.elapsed ?? Duration.zero);
      anyNegative |= cost.isNegative;
      out.writeln(
        '    ${step.name.padRight(40)}${_formatDelta(cost).padLeft(10)}'
        '   ${step.derivation}',
      );
    }
    if (anyNegative) {
      // A rung cannot cost less than the rung it strictly contains, so a
      // negative difference is this pass's noise floor made visible — and it
      // is the scale every *positive* figure in the block above has to be
      // read against before any of them is called a cost.
      out.writeln(
        '    (a negative step is noise: that rung came out cheaper than the '
        'one it contains)',
      );
    }

    final floorPass = pass[ScanProbeLayer.stat];
    final full = pass[ScanProbeLayer.scanEmptyArchive];
    if (floorPass != null && full != null) {
      out.writeln();
      // The one line task 1a341e actually asked for: the platform's floor,
      // and everything this project's code adds on top of it.
      out.writeln(
        '  platform floor (list+stat)      '
        '${formatMetricDuration(floorPass.elapsed).padLeft(10)}'
        '   ${_percent(floorPass.elapsed, full.elapsed)} of the full scan',
      );
      out.writeln(
        '  this code, on top of the floor  '
        '${_formatDelta(full.elapsed - floorPass.elapsed).padLeft(10)}'
        '   ${_percent(full.elapsed - floorPass.elapsed, full.elapsed)} of the full scan',
      );
    }
  }

  return out.toString();
}

/// A rung's name, as both renderings of this report show it.
///
/// Public for the same reason [formatMetricBytes] is: the Flutter head lays
/// the same rungs out as a widget table rather than as text, and a row read
/// on screen and the same row pasted out of the copy button must not be
/// called two different things.
String scanProbeLayerLabel(ScanProbeLayer layer) => switch (layer) {
  ScanProbeLayer.list => 'list',
  ScanProbeLayer.stat => 'list+stat',
  ScanProbeLayer.rules => '+§5.1 rules',
  ScanProbeLayer.scanWarmArchive => 'scan (warm archive)',
  ScanProbeLayer.scanEmptyArchive => 'scan (empty archive)',
};

/// One named step, and the two rungs whose difference is its cost.
///
/// Held as data rather than written out as arithmetic in the renderer so the
/// derivation prints alongside every figure: SPEC §17's rule is that a
/// conclusion comes from a number the report prints, and a *subtracted*
/// number only qualifies if the reader can see which two it came from.
class _Step {
  final String name;
  final ScanProbeLayer above;
  final ScanProbeLayer? below;
  final String derivation;

  const _Step(this.name, this.above, this.below, this.derivation);
}

const _steps = [
  _Step('Directory.list + sort', ScanProbeLayer.list, null, '(list)'),
  _Step(
    'FileStat per file',
    ScanProbeLayer.stat,
    ScanProbeLayer.list,
    '(list+stat − list)',
  ),
  _Step(
    '§5.1 rules + path building',
    ScanProbeLayer.rules,
    ScanProbeLayer.stat,
    '(+§5.1 rules − list+stat)',
  ),
  _Step(
    'archive + §16 + ScanResult',
    ScanProbeLayer.scanWarmArchive,
    ScanProbeLayer.rules,
    '(scan warm − +§5.1 rules)',
  ),
  _Step(
    'SHA-256 hashing',
    ScanProbeLayer.scanEmptyArchive,
    ScanProbeLayer.scanWarmArchive,
    '(scan empty − scan warm)',
  ),
];

/// A signed difference between two rungs.
///
/// [formatMetricDuration] is SPEC §17's formatter and every value it was
/// written for is a duration that happened, so it has no sign to render — a
/// negative here would come out as raw microseconds in a column of
/// milliseconds. The sign is applied around it rather than inside it: §17's
/// report has no negative numbers to break.
String _formatDelta(Duration value) => value.isNegative
    ? '-${formatMetricDuration(-value)}'
    : formatMetricDuration(value);

String _percent(Duration part, Duration whole) => whole.inMicroseconds == 0
    ? '—'
    : '${(100 * part.inMicroseconds / whole.inMicroseconds).toStringAsFixed(0)}%';
