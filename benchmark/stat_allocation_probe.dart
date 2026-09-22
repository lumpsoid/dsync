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
// **The instrument is `gc_ladder.dart`** — `--verbose_gc` summed per rung, a
// fresh VM per rung, a `noop` rung for the floor. Three richer instruments were
// tried first and do not work; that file records which and why.
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

import 'gc_ladder.dart';

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

  final root = flagOf(args, '--root');
  if (root == null || !Directory(root).existsSync()) {
    stderr.writeln(
      'usage: dart run benchmark/stat_allocation_probe.dart '
      '--root <dir> [--rung <name>]\n'
      'rungs: ${rungs.join(', ')}',
    );
    exitCode = 2;
    return;
  }

  final only = flagOf(args, '--rung');
  if (only != null && !rungs.contains(only)) {
    stderr.writeln('unknown rung: $only\nrungs: ${rungs.join(', ')}');
    exitCode = 2;
    return;
  }

  stdout.writeln('tree: $root');
  await runLadder(
    // The floor rung always runs: without it a one-rung run reports itself
    // as its own floor and prints zero.
    rungs: only == null ? rungs : [rungs.first, only],
    script: Platform.script.toFilePath(),
    rungArgs: [root],
    onRung: (reading, floor) {
      if (reading.rung != 'control') return;
      final expected = controlAllocations * controlBytes;
      stdout.writeln(
        '  ${' ' * 14}expected ${formatMiB(expected)} '
        '($controlAllocations x $controlBytes B, all of it garbage) — '
        'read ${formatMiB(reading.newGenBytes - floor)}',
      );
    },
  );
}

/// One rung, in the process spawned for it. Prints what it visited; the
/// allocation figure is read off `--verbose_gc` by the parent.
Future<void> _runRung(String rung, String root) async {
  final counts = _Counts();
  final clock = Stopwatch()..start();
  await _walk(rung, root, counts);
  clock.stop();
  stdout.writeln(
    RungResult(units: counts.files, millis: clock.elapsedMilliseconds),
  );
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

