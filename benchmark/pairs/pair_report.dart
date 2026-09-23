import 'package:dsync/dsync_core/run/run_metrics_report.dart';

import 'pair_order.dart';
import 'pair_run.dart';

/// How far over its own arm's median a run's total may land before it is
/// flagged as slow. 9d2158 §9.0's rule is that a slow run is the anomaly and
/// is re-run before anything is reasoned from it; this is the line that makes
/// "slow" a reading rather than a judgement. Set at the link's measured
/// run-to-run spread on a phase total, ~13%, rounded up.
const slowRunMargin = 0.15;

/// The phases a pair is compared on besides the run total.
const comparedPhases = ['scan', 'apply'];

/// The summary of one interleaved session (task 84fc92): every run with its
/// radio, each pair's ratio, each arm's own spread, and the runs that must be
/// re-taken before the comparison is read.
///
/// Pure: it is handed the runs and returns text, so the rules it applies are
/// tested with plain values.
String renderPairReport({
  required List<String> arms,
  required PairOrder order,
  required String pass,
  required List<PairRun> runs,
}) {
  final out = StringBuffer()
    ..writeln(
      'interleaved pairs: ${arms[1]} against ${arms[0]}, '
      '${order.name}, $pass pass, ${runs.length} runs',
    )
    ..writeln();

  final medians = [
    for (var arm = 0; arm < 2; arm++)
      _median([
        for (final run in runs)
          if (run.arm == arm) run.timings.total.inMicroseconds.toDouble(),
      ]),
  ];

  out.writeln(
    'run  ${'arm'.padRight(_armWidth(arms))}'
    '${'total'.padLeft(10)}'
    '${[for (final phase in comparedPhases) phase.padLeft(10)].join()}',
  );
  for (final (index, run) in runs.indexed) {
    out.writeln(
      '${'${index + 1}'.padRight(5)}${arms[run.arm].padRight(_armWidth(arms))}'
      '${formatMetricDuration(run.timings.total).padLeft(10)}'
      '${[for (final phase in comparedPhases) _phase(run, phase).padLeft(10)].join()}',
    );
  }

  out
    ..writeln()
    ..writeln('radio, start and end of each run');
  for (final (index, run) in runs.indexed) {
    final retry = switch ((run.radioStart, run.radioEnd)) {
      (final start?, final end?) => start.retryShareUntil(end),
      _ => null,
    };
    out
      ..writeln(
        '${'${index + 1}'.padRight(5)}start '
        '${run.radioStart?.describe() ?? 'not read'}',
      )
      ..writeln(
        '${''.padRight(5)}end   ${run.radioEnd?.describe() ?? 'not read'}'
        '${retry == null ? '' : ', tx retried ${(retry * 100).toStringAsFixed(1)}%'}',
      );
  }

  out
    ..writeln()
    ..writeln('per pair, ${arms[1]} / ${arms[0]}');
  final first = [
    for (final run in runs)
      if (run.arm == 0) run,
  ];
  final second = [
    for (final run in runs)
      if (run.arm == 1) run,
  ];
  final pairs = first.length < second.length ? first.length : second.length;
  final ratios = <String, List<double>>{
    for (final measure in ['total', ...comparedPhases]) measure: [],
  };
  for (var pair = 0; pair < pairs; pair++) {
    final cells = <String>[];
    for (final measure in ratios.keys) {
      final a = _measure(first[pair], measure);
      final b = _measure(second[pair], measure);
      if (a == null || b == null || a == 0) {
        cells.add('$measure —');
        continue;
      }
      ratios[measure]!.add(b / a);
      cells.add('$measure ${(b / a).toStringAsFixed(3)}');
    }
    out.writeln('  pair ${pair + 1}   ${cells.join('   ')}');
  }
  for (final MapEntry(key: measure, value: values) in ratios.entries) {
    if (values.isEmpty) continue;
    values.sort();
    final agree = values.every((r) => r < 1) || values.every((r) => r > 1);
    out.writeln(
      '  $measure: median ${_median(values).toStringAsFixed(3)}, '
      'range ${values.first.toStringAsFixed(3)}–'
      '${values.last.toStringAsFixed(3)}, '
      '${agree ? 'every pair agrees on direction' : 'pairs disagree on direction'}',
    );
  }

  out
    ..writeln()
    ..writeln('spread within each arm, total (max − min) / median');
  for (var arm = 0; arm < 2; arm++) {
    final totals = [
      for (final run in runs)
        if (run.arm == arm) run.timings.total.inMicroseconds.toDouble(),
    ]..sort();
    if (totals.isEmpty) continue;
    final spread = (totals.last - totals.first) / medians[arm];
    out.writeln('  ${arms[arm]}: ${(spread * 100).toStringAsFixed(1)}%');
  }

  final flags = _flags(arms, runs, medians);
  out
    ..writeln()
    ..writeln(
      flags.isEmpty
          ? 'no run flagged: none slow, the radio held through every run'
          : 're-run before reading the comparison:',
    );
  for (final flag in flags) {
    out.writeln('  $flag');
  }
  return out.toString();
}

List<String> _flags(
  List<String> arms,
  List<PairRun> runs,
  List<double> medians,
) {
  final flags = <String>[];
  final baseline = runs.isEmpty ? null : runs.first.radioStart;
  for (final (index, run) in runs.indexed) {
    final label = 'run ${index + 1} (${arms[run.arm]})';
    final over = run.timings.total.inMicroseconds / medians[run.arm] - 1;
    if (over > slowRunMargin) {
      flags.add(
        '$label: slow, ${(over * 100).toStringAsFixed(0)}% over its arm\'s '
        'median',
      );
    }
    final changes = run.radioChanges;
    if (changes == null) {
      flags.add('$label: radio not read at its start or end');
    } else if (changes.isNotEmpty) {
      flags.add('$label: radio moved during the run: ${changes.join(', ')}');
    }
    final start = run.radioStart;
    if (index > 0 && baseline != null && start != null) {
      final drift = baseline.associationChangesTo(start);
      if (drift.isNotEmpty) {
        flags.add(
          '$label: started on a different association from run 1: '
          '${drift.join(', ')}',
        );
      }
    }
  }
  return flags;
}

double? _measure(PairRun run, String measure) => measure == 'total'
    ? run.timings.total.inMicroseconds.toDouble()
    : run.timings.phases[measure]?.inMicroseconds.toDouble();

String _phase(PairRun run, String phase) => switch (run.timings.phases[phase]) {
  final elapsed? => formatMetricDuration(elapsed),
  null => '—',
};

int _armWidth(List<String> arms) =>
    [3, ...arms.map((arm) => arm.length)].reduce((a, b) => a > b ? a : b) + 2;

double _median(List<double> values) {
  if (values.isEmpty) return double.nan;
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}
