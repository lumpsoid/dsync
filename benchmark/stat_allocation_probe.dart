// What a walk of a real tree allocates, rung by rung (task 26a874). Not part
// of the build.
//
// **The claim under test.** SPEC §5's table puts an asynchronous `stat` at
// ~2.3 KB of garbage per call and 61% of everything a scan allocates. That
// figure is the gap between two rungs, and the rung that produced it added
// three things at once: the IO service's round trip, a future, and an `await`
// inside an `await for`. The ladder below is built so every gap adds exactly
// one thing, which is what the old pair could not do:
//
//   noop          nothing at all. VM boot, kernel compile, JIT. Every rung
//                 pays it, so every rung's own cost is its figure minus this.
//   control       a known number of known-size strings, so the instrument can
//                 be checked against arithmetic before anything is read off it.
//   list          `Directory.list`, nothing else — the async listing floor.
//   list-sync     the same listing, blocking.
//   future-only   the async listing plus one `Future.value()` per file that is
//                 **never awaited**. The future object and its completion, but
//                 no suspension.
//   sync-only     the same with `Future.syncValue()`, which completes the future
//                 in place instead of through a microtask — so this rung is the
//                 future object and *nothing* else.
//   await-null    the async listing plus `await null` per file. A suspension
//                 and no fresh future — `await` on a non-future takes the VM's
//                 fast path rather than wrapping it.
//   await-future  the async listing plus one *awaited* `Future.value()` per
//                 file. Future object, microtask completion and suspension.
//   await-sync    the same with `Future.syncValue()`. `await-future` minus this
//                 is what the microtask and its callback entry cost, which is
//                 the gap that made `future-only` plus `await-null` fall 206 B
//                 a file short of `await-future`.
//   call-async    the async listing plus `await` on a call to an empty `async`
//                 function. Adds that function's own async frame on top, which
//                 is the shape `await child.stat()` really has.
//   stat          the async listing plus `await File.stat()` — today's shape,
//                 and the one the 2.3 KB was measured on.
//   stat-static   the same through `FileStat.stat(path)`, which skips the
//                 `File` the method form needs.
//   stat-batched  the same, `jobs` outstanding through `Future.wait` — what
//                 `Scanner._walkChildren` actually does (SPEC §5.3).
//   stat-sync     the async listing plus `statSync()`. Keeps the stream and the
//                 `await for`, drops the IO service. `stat` minus this is the
//                 asynchronous mechanism's price with the syscall held fixed.
//   sync-all      blocking listing, blocking stat. The other end of the range.
//
// The four async rungs share one limit worth stating: their futures complete on
// the microtask queue, where a real `dart:io` future parks until a port message
// wakes it. They price the objects an `await` costs, not the parking.
//
// **Three instruments were tried before this one and do not work.** Recorded
// here so they are not tried again:
//
//   `getAllocationProfile`'s `accumulatedSize` is **rebased at every GC**, so
//   it cannot measure a region that collects — and any walk of a real tree
//   collects several times. Measured: one identical body read back as 97, 123,
//   239 and 363 bytes an item over four runs, and went *negative* when the
//   collection landed between the two reads instead of before them. `reset:
//   true` does not zero it either; an empty region reported 10.71 MiB.
//
//   `setTraceClassAllocation` plus `getAllocationTraces` is exact on a class
//   allocated from a cold site — 1,000 then 1,000 then 50,000 read back
//   perfectly — and useless on a hot one, because the JIT inlines allocation
//   and the runtime call that records the sample is gone. Over the same walk it
//   reported `_File`, `_Directory` and `FileStat` at **exactly zero** across
//   4,254 files, and `_Future` at 12,855 or at 70 depending only on whether the
//   warm-up pass ran before or after tracing was switched on. It also
//   **segfaults the VM** without `--profiler`, in
//   `SampleBlockBuffer::ReserveSampleImpl` on Dart 3.13.3.
//
//   `ProcessInfo.currentRss` is a step function here, as SPEC §5 already says:
//   the semispace grows to its cap or it does not.
//
// So: `--verbose_gc`, summed per rung, in a fresh VM per rung. Coarse, and the
// ladder is what makes it say something — a difference between two rungs that
// differ by one line of code.
//
//   dart run benchmark/stat_allocation_probe.dart --root <dir>
//   dart run benchmark/stat_allocation_probe.dart --root <dir> --rung stat
//
// Point it at a real tree, and a large one. Resolution comes from the number of
// scavenges, so a tree small enough to finish inside two of them reports
// arithmetic on two samples. Every attempt in this project to measure a walk
// against a synthetic or partial tree also reported a different device (task
// 9d2158 §14).
//
// **How large is not a matter of taste for the four async rungs.** They differ
// from `list` by 300–900 B a file, and one scavenge is worth ~1.8 MiB whatever
// the tree — so over 11,785 files a whole rung's cost is one scavenge of
// quantisation and the readings are noise. Over 101,979 files the same rungs
// take 58–208 scavenges, which puts a scavenge at ~19 B a file. Read those four
// against a six-figure file count or not at all.
//
// **One result worth not re-deriving**, reproduced on both trees: `call-async`
// costs *less* than `await-future` (538 against 916 B a file over `list`). An
// `async` function whose body completes without parking is resumed on a fast
// path, while `Future.value()` allocates a future and then schedules a microtask
// and a listener to complete it. So `call-async` **understates** what
// `await child.stat()` pays — that call does park — and `await-future` is the
// closer of the two proxies despite being the more artificial-looking.
import 'dart:io';
import 'dart:typed_data';

/// Stats outstanding in the `stat-batched` rung — `Scanner`'s own default, so
/// that rung is the scanner's shape and not a differently-tuned lookalike.
const jobs = 4;

/// What the `control` rung allocates: this many byte lists of this size, each
/// dropped immediately.
///
/// **Discarded rather than held, and a byte list rather than a string.** The
/// first control here held 200,000 interpolated strings and read back 11.9 MiB
/// against an arithmetic of over 20 — because held objects are promoted out of
/// new space instead of being collected from it, and an interpolation's real
/// garbage is intermediates nobody counted. A dropped `Uint8List` has neither
/// problem: its size is exactly what was asked for and all of it is garbage, so
/// the rung's expected figure is a multiplication and the instrument either
/// reproduces it or is wrong.
const controlAllocations = 50000;
const controlBytes = 1024;

const rungs = [
  'noop',
  'control',
  'list',
  'list-sync',
  'future-only',
  'sync-only',
  'await-null',
  'await-future',
  'await-sync',
  'call-async',
  'stat',
  'stat-static',
  'stat-batched',
  'stat-sync',
  'sync-all',
];

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'rung') {
    await _runRung(args[1], args[2]);
    return;
  }

  final root = _flag(args, '--root');
  if (root == null || !Directory(root).existsSync()) {
    stderr.writeln(
      'usage: dart run benchmark/stat_allocation_probe.dart '
      '--root <dir> [--rung <name>]\n'
      'rungs: ${rungs.join(', ')}',
    );
    exitCode = 2;
    return;
  }

  final only = _flag(args, '--rung');
  if (only != null && !rungs.contains(only)) {
    stderr.writeln('unknown rung: $only\nrungs: ${rungs.join(', ')}');
    exitCode = 2;
    return;
  }

  stdout.writeln('tree: $root');
  stdout.writeln(
    '  ${'rung'.padRight(14)}${'ms'.padLeft(7)}${'garbage'.padLeft(12)}'
    '${'over noop'.padLeft(12)}${'B a file'.padLeft(11)}'
    '${'scavenges'.padLeft(11)}${'retained'.padLeft(11)}  files',
  );

  int? floor;
  for (final rung in only == null ? rungs : [only]) {
    final reading = await _spawnRung(rung, root);
    floor ??= reading.newGenBytes;
    stdout.writeln(reading.row(floor));
    if (rung == 'control') {
      final expected = controlAllocations * controlBytes;
      stdout.writeln(
        '  ${' ' * 14}expected ${_mib(expected)} '
        '($controlAllocations x $controlBytes B, all of it garbage) — '
        'read ${_mib(reading.newGenBytes - floor)}',
      );
    }
  }
}

/// One rung in a VM of its own.
///
/// **A fresh VM per rung is the whole method.** `--verbose_gc` reports the
/// process, not a region of it, so the only way to attribute a figure to a rung
/// is for the process to have done nothing else. It also means the `noop` rung
/// is a real measurement of the shared cost rather than an estimate of it.
Future<_Reading> _spawnRung(String rung, String root) async {
  final result = await Process.run(Platform.executable, [
    '--verbose_gc',
    'run',
    Platform.script.toFilePath(),
    'rung',
    rung,
    root,
  ], workingDirectory: Directory.current.path);
  if (result.exitCode != 0) {
    stderr.write(result.stdout);
    stderr.write(result.stderr);
    throw StateError('rung $rung exited ${result.exitCode}');
  }
  final counted = _CountedRun.parse(result.stdout as String);
  return _Reading(rung, counted, _GcLog.parse(result.stderr as String));
}

/// One rung, in the process spawned for it. Prints what it visited; the
/// allocation figure is read off `--verbose_gc` by the parent.
Future<void> _runRung(String rung, String root) async {
  final counts = _Counts();
  final clock = Stopwatch()..start();
  await _walk(rung, root, counts);
  clock.stop();
  stdout.writeln('${counts.files} ${clock.elapsedMilliseconds}');
}

Future<void> _walk(String rung, String root, _Counts counts) async {
  switch (rung) {
    case 'noop':
      break;
    case 'control':
      for (var i = 0; i < controlAllocations; i++) {
        counts.files++;
        // Read one byte back so the list cannot be optimised away.
        counts.folded ^= Uint8List(controlBytes)[i % controlBytes];
      }
    case 'list':
      await for (final child in _listAsync(root)) {
        if (child is File) counts.files++;
      }
    case 'list-sync':
      for (final child in _listSync(root)) {
        if (child is File) counts.files++;
      }
    case 'future-only':
      await for (final child in _listAsync(root)) {
        if (child is! File) continue;
        counts.files++;
        // Parked in a field, not dropped on the floor: an unused future is
        // something the compiler is entitled to remove, and a rung measuring a
        // removed allocation measures the rung below it. Same for `sync-only`.
        counts.sink = Future<void>.value();
      }
    case 'sync-only':
      await for (final child in _listAsync(root)) {
        if (child is! File) continue;
        counts.files++;
        counts.sink = Future<void>.syncValue(null);
      }
    case 'await-null':
      await for (final child in _listAsync(root)) {
        if (child is! File) continue;
        counts.files++;
        await null;
      }
    case 'await-future':
      await for (final child in _listAsync(root)) {
        if (child is! File) continue;
        counts.files++;
        await Future<void>.value();
      }
    case 'await-sync':
      await for (final child in _listAsync(root)) {
        if (child is! File) continue;
        counts.files++;
        await Future<void>.syncValue(null);
      }
    case 'call-async':
      await for (final child in _listAsync(root)) {
        if (child is! File) continue;
        counts.files++;
        await _emptyAsync();
      }
    case 'stat':
      await for (final child in _listAsync(root)) {
        if (child is! File) continue;
        counts.files++;
        counts.fold(await child.stat());
      }
    case 'stat-static':
      await for (final child in _listAsync(root)) {
        if (child is! File) continue;
        counts.files++;
        counts.fold(await FileStat.stat(child.path));
      }
    case 'stat-batched':
      // Held back a directory at a time would need the scanner's own
      // recursion; held back `jobs` at a time over the flat stream leaves the
      // same number of stats outstanding, which is the property being priced.
      final pending = <File>[];
      Future<void> drain() async {
        final batch = List<File>.of(pending);
        pending.clear();
        for (final stat in await Future.wait(batch.map((f) => f.stat()))) {
          counts.fold(stat);
        }
      }

      await for (final child in _listAsync(root)) {
        if (child is! File) continue;
        counts.files++;
        pending.add(child);
        if (pending.length == jobs) await drain();
      }
      if (pending.isNotEmpty) await drain();
    case 'stat-sync':
      await for (final child in _listAsync(root)) {
        if (child is! File) continue;
        counts.files++;
        counts.fold(child.statSync());
      }
    case 'sync-all':
      for (final child in _listSync(root)) {
        if (child is! File) continue;
        counts.files++;
        counts.fold(child.statSync());
      }
    default:
      throw ArgumentError('unknown rung: $rung');
  }
}

/// An `async` function that does nothing, called once per file by the
/// `call-async` rung.
///
/// Top level and not inlined by hand: the point is that calling it costs an
/// async frame of its own, which is what an `await child.stat()` pays before
/// the filesystem is touched at all.
Future<void> _emptyAsync() async {}

/// `followLinks: false` on both listings, the way `Scanner` walks (SPEC §5.1):
/// following them would stat targets outside the tree and count them here.
Stream<FileSystemEntity> _listAsync(String root) =>
    Directory(root).list(recursive: true, followLinks: false);

List<FileSystemEntity> _listSync(String root) =>
    Directory(root).listSync(recursive: true, followLinks: false);

/// The tally each rung threads through itself.
class _Counts {
  int files = 0;

  /// Folded `stat` fields, never read — the three SPEC §5.2 consumes. Present
  /// so a rung genuinely uses what it asked the OS for: a `stat` whose result
  /// is dropped is a `stat` the compiler is free to treat differently from the
  /// one the scanner makes. XOR for the reason `ScanProbe`'s counts use it —
  /// cheapest fold that touches every value and cannot overflow.
  int folded = 0;

  /// Where the `future-only` rung parks the future it allocates. Never read,
  /// for the reason that rung gives.
  Future<void>? sink;

  void fold(FileStat stat) {
    folded ^= stat.size;
    folded ^= stat.modified.microsecondsSinceEpoch;
    folded ^= stat.mode & 0xFFF;
  }
}

/// What a rung process reported about itself on stdout.
class _CountedRun {
  const _CountedRun(this.files, this.millis);

  factory _CountedRun.parse(String stdout) {
    final parts = stdout.trim().split(RegExp(r'\s+'));
    return _CountedRun(int.parse(parts[0]), int.parse(parts[1]));
  }

  final int files;
  final int millis;
}

/// `--verbose_gc`'s table, reduced to the two figures a rung is read on.
///
/// **New-space "used before", summed over scavenges, is the garbage.** Each
/// scavenge reports how full new space was when it ran; a program that fills
/// and empties it repeatedly has allocated the sum of those fills. It is
/// quantised by the semispace, which is why the ladder — not any single figure
/// — is what this script reports.
///
/// Only the `main` isolate counts. The kernel service and the VM service
/// isolates run their own collections, and they are the same in every rung.
class _GcLog {
  const _GcLog({
    required this.newGenBytes,
    required this.scavenges,
    required this.retainedOldGenBytes,
  });

  factory _GcLog.parse(String stderr) {
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
    return _GcLog(
      newGenBytes: (newGen * 1024 * 1024).round(),
      scavenges: scavenges,
      retainedOldGenBytes: (retained * 1024 * 1024).round(),
    );
  }

  final int newGenBytes;
  final int scavenges;
  final int retainedOldGenBytes;
}

/// One rung's line of the table.
class _Reading {
  const _Reading(this.rung, this.run, this.gc);

  final String rung;
  final _CountedRun run;
  final _GcLog gc;

  int get newGenBytes => gc.newGenBytes;

  /// [floor] is the `noop` rung's figure — VM boot, kernel compile and JIT,
  /// which every rung pays and none of them is about.
  String row(int floor) {
    final own = newGenBytes - floor;
    final perFile = run.files == 0 ? 0 : own / run.files;
    return '  ${rung.padRight(14)}${run.millis.toString().padLeft(7)}'
        '${_mib(newGenBytes).padLeft(12)}${_mib(own).padLeft(12)}'
        '${perFile.round().toString().padLeft(11)}'
        '${gc.scavenges.toString().padLeft(11)}'
        '${_mib(gc.retainedOldGenBytes).padLeft(11)}  ${run.files}';
  }
}

String _mib(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';

String? _flag(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}
