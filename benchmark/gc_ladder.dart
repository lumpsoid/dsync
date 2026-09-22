// Runs a ladder of rungs, each in a VM of its own, and reports what each one
// allocated (tasks 26a874, 55bee6). Not part of the build — imported by
// benchmark scripts only.
//
// **The method.** `--verbose_gc` reports a process, not a region of one, so the
// only way to attribute a figure to a rung is for the process to have done
// nothing else. Every rung is therefore a fresh VM running one rung, and **the
// first rung is the floor**: its figure is the shared cost every rung pays and
// none of them is about, and every later rung is reported above it. For a
// read-only ladder that floor is a `noop` — VM boot, kernel compile, JIT. For one
// that has to build a corpus first, it is a rung that builds the corpus and stops
// there, so the corpus does not land in the figures.
//
// New-space "used before", summed over scavenges, is the garbage: each scavenge
// reports how full new space was when it ran, and a program that fills and
// empties it repeatedly has allocated the sum of those fills. It is coarse, and
// the ladder is what makes it say something — a difference between two rungs
// that differ by one line of code.
//
// **Resolution is a function of tree size, and it bites.** One scavenge is worth
// ~1.8 MiB whatever the corpus, so a rung whose own cost is a megabyte is one
// scavenge of quantisation and its reading is noise. Watch the `scavenges`
// column: two rungs to be compared need tens of them, not a handful.
//
// **Why not the VM service.** Three richer instruments were tried and do not
// work, recorded so they are not tried again:
//
//   `getAllocationProfile`'s `accumulatedSize` is rebased at every GC, so it
//   cannot measure a region that collects — and any walk of a real tree
//   collects. One identical body read back as 97, 123, 239 and 363 bytes an item
//   over four runs, and went negative when the collection landed between the two
//   reads. `reset: true` does not zero it either; an empty region reported
//   10.71 MiB.
//
//   `setTraceClassAllocation` plus `getAllocationTraces` is exact on a class
//   allocated from a cold site — 1,000 then 1,000 then 50,000 read back
//   perfectly — and useless on a hot one, because the JIT inlines allocation and
//   the runtime call that records the sample is gone. Over one walk it reported
//   `_File`, `_Directory` and `FileStat` at exactly zero across 4,254 files. It
//   also segfaults the VM without `--profiler`.
//
//   `ProcessInfo.currentRss` is a step function here (SPEC §5): the semispace
//   grows to its cap or it does not.
import 'dart:io';

/// What one rung's process reported about itself, on stdout.
///
/// A rung prints this rather than the parent timing the subprocess: a `Process`
/// wall time includes VM boot and kernel compile, which is most of a fast rung.
class RungResult {
  const RungResult({required this.units, required this.millis});

  /// Whatever the rung counted — files visited, allocations made. The
  /// denominator every per-unit figure is divided by.
  final int units;

  final int millis;

  /// The line a rung writes on stdout, and the only thing it may write there.
  @override
  String toString() => '$units $millis';

  static RungResult parse(String stdout) {
    final parts = stdout.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) {
      throw StateError('a rung printed "${stdout.trim()}", not "<units> <ms>"');
    }
    return RungResult(
      units: int.parse(parts[0]),
      millis: int.parse(parts[1]),
    );
  }
}

/// `--verbose_gc`'s table, reduced to the figures a rung is read on.
///
/// Only the `main` isolate counts. The kernel service and the VM service
/// isolates run their own collections and they are the same in every rung.
class GcLog {
  const GcLog({
    required this.newGenBytes,
    required this.scavenges,
    required this.retainedOldGenBytes,
  });

  factory GcLog.parse(String stderr) {
    var newGen = 0.0;
    var scavenges = 0;
    var retained = 0.0;
    for (final line in stderr.split('\n')) {
      if (!line.startsWith('[ main ')) continue;
      final columns = line.split(',').map((c) => c.trim()).toList();
      if (columns.length < 13) continue;
      final usedBefore = double.tryParse(columns[5]);
      final oldAfter = double.tryParse(columns[12]);
      if (usedBefore == null || oldAfter == null) continue;
      if (columns[1].startsWith('Scavenge(') &&
          columns[1].contains('new space')) {
        newGen += usedBefore;
        scavenges++;
      }
      // The last line of any kind: what the old generation was left holding.
      retained = oldAfter;
    }
    return GcLog(
      newGenBytes: (newGen * 1024 * 1024).round(),
      scavenges: scavenges,
      retainedOldGenBytes: (retained * 1024 * 1024).round(),
    );
  }

  final int newGenBytes;
  final int scavenges;
  final int retainedOldGenBytes;
}

/// One rung's reading, ready to print.
class LadderReading {
  const LadderReading(this.rung, this.run, this.gc);

  final String rung;
  final RungResult run;
  final GcLog gc;

  int get newGenBytes => gc.newGenBytes;

  /// [floor] is the first rung's figure, which every rung pays and none of
  /// them is about.
  String row(int floor) {
    final own = newGenBytes - floor;
    final perUnit = run.units == 0 ? 0 : own / run.units;
    return '  ${rung.padRight(14)}${run.millis.toString().padLeft(7)}'
        '${formatMiB(newGenBytes).padLeft(12)}${formatMiB(own).padLeft(12)}'
        '${perUnit.round().toString().padLeft(11)}'
        '${gc.scavenges.toString().padLeft(11)}'
        '${formatMiB(gc.retainedOldGenBytes).padLeft(11)}  ${run.units}';
  }
}

/// Spawns each of [rungs] in its own VM and prints the table.
///
/// [script] is the calling script's own path and [rungArgs] whatever it needs
/// after the rung name — a ladder re-invokes the script that owns it rather than
/// taking a closure, because a closure would run in *this* VM and the whole
/// method is one rung per process.
///
/// [unitLabel] names the denominator, since a rung counts files in one script
/// and allocations in another.
///
/// [onRung] is called with each reading as it lands, so a script can print a
/// check of its own beneath a rung — a control rung comparing itself against
/// arithmetic, say.
Future<void> runLadder({
  required List<String> rungs,
  required String script,
  required List<String> rungArgs,
  String unitLabel = 'files',
  void Function(LadderReading reading, int floor)? onRung,
}) async {
  stdout.writeln(
    '  ${'rung'.padRight(14)}${'ms'.padLeft(7)}${'garbage'.padLeft(12)}'
    '${'over floor'.padLeft(12)}${'B a unit'.padLeft(11)}'
    '${'scavenges'.padLeft(11)}${'retained'.padLeft(11)}  $unitLabel',
  );

  int? floor;
  for (final rung in rungs) {
    final reading = await _spawn(rung, script, rungArgs);
    floor ??= reading.newGenBytes;
    stdout.writeln(reading.row(floor));
    onRung?.call(reading, floor);
  }
}

Future<LadderReading> _spawn(
  String rung,
  String script,
  List<String> rungArgs,
) async {
  final result = await Process.run(Platform.executable, [
    '--verbose_gc',
    'run',
    script,
    'rung',
    rung,
    ...rungArgs,
  ], workingDirectory: Directory.current.path);
  if (result.exitCode != 0) {
    stderr.write(result.stdout);
    stderr.write(result.stderr);
    throw StateError('rung $rung exited ${result.exitCode}');
  }
  return LadderReading(
    rung,
    RungResult.parse(result.stdout as String),
    GcLog.parse(result.stderr as String),
  );
}

String formatMiB(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';

/// Reads `--name value` or `--name=value` out of [args].
String? flagOf(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}
