// What writing a file costs, step by step, against the floor of writing it as
// plainly as possible (task 4c55fd). Not part of the build.
//
// **The question.** A cold pull with the phone as destination applied 14,471
// files in 508.2 s — 35.1 ms a file serialized, against 5.0 ms for the same tree
// pushed to a desktop. `LocalAgent.writeFile` already accumulates its nine steps
// (SPEC §7.2, §7.4) but that breakdown is only reported for a *remote* agent, so
// the pulling side — the phone — is exactly the one nobody can see into. This
// ladder is the desktop half: what each of those steps allocates and costs when
// nothing else is in the way, and what the floor underneath them is.
//
// **The rungs are cumulative and end at `LocalAgent.writeFile`'s own shape:**
//
//   setup         builds the corpus and stops. **The floor** — every rung reads
//                 the size list, builds the paths and fills the source buffer,
//                 so none of that lands in the figures above.
//   bare-sync     `writeAsBytesSync` straight to the destination. No temp, no
//                 rename, no stamp, no stat. Task 4c55fd's hypothesis 4: without
//                 this number nothing above can be called a win or a limit.
//   bare-async    the same through `writeAsBytes`.
//   sink          `openWrite` + `addStream` + `flush` + `close`, which is how
//                 `writeFile` actually writes. `sink` against `bare-async` is
//                 hypothesis 1 — the streaming sink against a whole-file write —
//                 and the read path's answer to the same question was emphatic
//                 (SPEC §5.3: blocking reads beat `openRead` 28.4 to 10.9 MiB/s).
//   temp-rename   the sink into a temp path, then `rename` onto the target.
//   mtime         plus `setLastModified` (SPEC §7.4).
//   mode          plus `posixChmod` — the real one, so the FFI call this project
//                 ships is what gets measured and not a stand-in.
//   full          plus the closing `stat`. This is `writeFile`'s nine steps.
//   sync-full     the same nine steps with blocking calls throughout.
//
// **`--depth` is the concurrency axis, and it defaults to 1.** `Applier` runs 16
// writes in flight and task 4c55fd's hypothesis 3 is whether that is past the
// knee. The knee itself is a property of the storage and so belongs on the device
// — but a desktop curve is the control that says whether a knee on the phone is
// the phone or is this code, which is the same job `benchmark/read_probe.dart`
// does for `ReadProbe`. Workers pull from one shared cursor rather than taking
// fixed shards, which is how `Applier` has its writes outstanding: N in flight,
// each taking the next path when its own finishes.
//
// The two blocking rungs ignore depth in effect — a worker that never awaits runs
// its whole share before another gets the turn — so read them at depth 1 and
// treat them as the floor the async curve is measured against.
//
// **The destination is scratch and is treated as disposable.**
// `$HOME/.cache/dsync/scratch/<name>`: under XDG's cache root, which already
// means "safe to delete", with `scratch` making it explicit. Not
// `Directory.systemTemp` — that is tmpfs on this machine, so a write there would
// be measured against RAM (`scan_memory_probe.dart` documents the same trap). Not
// `temp` either: this project already spells two other things that way —
// `temp_file.dart`'s in-replica temp files that `writeFile` renames from, and the
// tmpfs above — and a third meaning would collide with both.
//
// **The corpus is written once by the parent before any rung runs**, so every
// rung overwrites an existing file rather than the first one creating and the
// rest replacing. That models a re-sync rather than a first pull, which is the
// honest framing: a first pull's per-file `create` is what
// `LocalAgent._createdParents` already removes, so it is not a step this ladder
// would be measuring anyway.
//
//   dart run benchmark/write_allocation_probe.dart --source <dir>
//   dart run benchmark/write_allocation_probe.dart --source <dir> --rung full
//   dart run benchmark/write_allocation_probe.dart --source <dir> --cap 0
//   dart run benchmark/write_allocation_probe.dart --source <dir> \
//     --rung full --depth 16
//
// **`--cap` clamps every file's size, and `--cap 0` is the reason it exists.**
// The first reading off this ladder put `writeFile` at 37.9 KB of garbage a file
// over a corpus whose mean file is 17.8 KB — about twice the bytes written —
// which says the cost is *per byte* and not per call. A ladder run at `--cap 0`
// writes the same number of files with no payload at all, so what it reports is
// the fixed per-call term alone, and the difference against a full run divided by
// the bytes written is the per-byte one. Those two have completely different
// fixes: fewer calls against fewer copies.
//
// `--source` is read for its **size distribution only** — nothing is copied and
// nothing under it is written to. The distribution is the point: cost here is
// per-file dominated *and* byte-weighted by a tail, so a corpus of mean-sized
// files would report a different device (task 9d2158 §14).
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/agent/posix_chmod.dart';

import 'gc_ladder.dart';

const rungs = [
  'setup',
  'bare-sync',
  'bare-async',
  'sink',
  'temp-rename',
  'mtime',
  'mode',
  'full',
  'sync-full',
];

/// Files per directory in the scratch tree, so the writes have a realistic
/// fan-out rather than one directory with every file in it.
const filesPerDirectory = 100;

/// The chunk the sink rungs feed. 64 KiB, which is `ReadAhead`'s own per-stream
/// cap and `dart:io`'s stream block, so a file under it arrives in one piece —
/// as 90.9% of the measured tree's files do (SPEC §7.2).
const chunkBytes = 64 * 1024;

/// The mode and mtime the stamping rungs apply. Fixed values: what is being
/// measured is the call, and a per-file value would mean reading one.
const appliedMode = 0x1A4; // 0644
const appliedMtimeMicros = 1700000000000000;

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'rung') {
    await _runRung(args[1], args[2], args[3], int.parse(args[4]));
    return;
  }

  final source = flagOf(args, '--source');
  if (source == null || !Directory(source).existsSync()) {
    stderr.writeln(
      'usage: dart run benchmark/write_allocation_probe.dart '
      '--source <dir> [--rung <name>]\n'
      '  <dir> is read for its file-size distribution only; nothing under it '
      'is written to.\n'
      'rungs: ${rungs.join(', ')}',
    );
    exitCode = 2;
    return;
  }

  final capText = flagOf(args, '--cap');
  final cap = capText == null ? null : int.tryParse(capText);
  if (capText != null && (cap == null || cap < 0)) {
    stderr.writeln('--cap wants a non-negative byte count, got "$capText"');
    exitCode = 2;
    return;
  }

  final only = flagOf(args, '--rung');
  if (only != null && !rungs.contains(only)) {
    stderr.writeln('unknown rung: $only\nrungs: ${rungs.join(', ')}');
    exitCode = 2;
    return;
  }

  final depthText = flagOf(args, '--depth');
  final depth = depthText == null ? 1 : int.tryParse(depthText);
  if (depth == null || depth < 1) {
    stderr.writeln('--depth wants a positive count, got "$depthText"');
    exitCode = 2;
    return;
  }

  final scratch = _scratchDirectory('write-probe');
  final sizes = _sizesUnder(source);
  if (cap != null) {
    for (var i = 0; i < sizes.length; i++) {
      if (sizes[i] > cap) sizes[i] = cap;
    }
  }
  if (sizes.isEmpty) {
    stderr.writeln('no files under $source');
    exitCode = 2;
    return;
  }
  final sizesFile = File('${scratch.path}/sizes.bin');
  sizesFile.writeAsBytesSync(Uint64List.fromList(sizes).buffer.asUint8List());

  final dest = Directory('${scratch.path}/tree');
  final bytes = sizes.fold<int>(0, (a, b) => a + b);
  stdout.writeln(
    'sizes from: $source (${sizes.length} files, ${_mib(bytes)}'
    '${cap == null ? '' : ', capped at $cap B'})',
  );
  stdout.writeln(
    'mean file:  ${sizes.isEmpty ? 0 : (bytes / sizes.length).round()} B',
  );
  stdout.writeln('writing to: ${dest.path}  (depth $depth)');
  try {
    _seedTree(dest, sizes);
    await runLadder(
      // The floor rung always runs, even for a single named rung: it is what
      // the corpus build is subtracted out with, and without it a one-rung run
      // reports itself as its own floor and prints zero.
      rungs: only == null ? rungs : [rungs.first, only],
      script: Platform.script.toFilePath(),
      rungArgs: [sizesFile.path, dest.path, '$depth'],
    );
  } finally {
    // The parent cleans up, never a rung: a `deleteSync(recursive: true)` walks
    // the tree and allocates per entry, and inside a rung that would land in its
    // figure.
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    stdout.writeln('removed: ${scratch.path}');
  }
}

/// `$HOME/.cache/dsync/scratch/<name>`, emptied if it is already there.
///
/// Refuses to run without `HOME` rather than falling back to `/tmp`: a fallback
/// would land on tmpfs on most machines and silently measure RAM.
Directory _scratchDirectory(String name) {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError(
      'HOME is not set, and there is no safe fallback — see this file\'s header',
    );
  }
  final dir = Directory('$home/.cache/dsync/scratch/$name');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  return dir;
}

/// Every file size under [root], in bytes.
///
/// The whole tree, and there is no way to ask for less: three samples of one
/// were tried for `ReadProbe` and reported mean file sizes of +113%, +24% and
/// −23% against the tree's, because the bytes sit in a tail that a partial
/// corpus keeps only its own fraction of (task 9d2158 §14).
List<int> _sizesUnder(String root) {
  final sizes = <int>[];
  for (final entity in Directory(
    root,
  ).listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    try {
      sizes.add(entity.statSync().size);
    } on FileSystemException {
      // Gone between the walk and the stat. Not this probe's problem.
    }
  }
  return sizes;
}

/// Creates the destination tree and writes every file once, so that every rung
/// overwrites rather than the first rung creating — see the header.
void _seedTree(Directory dest, List<int> sizes) {
  final source = _sourceBuffer(sizes);
  for (var i = 0; i < sizes.length; i++) {
    final file = File(_pathFor(dest.path, i));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(Uint8List.sublistView(source, 0, sizes[i]));
  }
}

/// One rung, in the process spawned for it.
Future<void> _runRung(
  String rung,
  String sizesPath,
  String destPath,
  int depth,
) async {
  // Every rung pays this, including the `setup` rung that is the floor, so it
  // cancels out of every figure above.
  final sizes = Uint64List.sublistView(
    File(sizesPath).readAsBytesSync(),
  ).toList();
  final source = _sourceBuffer(sizes);
  final paths = [for (var i = 0; i < sizes.length; i++) _pathFor(destPath, i)];
  final mtime = DateTime.fromMicrosecondsSinceEpoch(appliedMtimeMicros);

  final clock = Stopwatch()..start();
  // One shared cursor, no lock: this is one isolate and nothing is awaited
  // between reading `next` and incrementing it.
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= sizes.length) return;
      await _write(
        rung,
        paths[index],
        Uint8List.sublistView(source, 0, sizes[index]),
        mtime,
      );
    }
  }

  await Future.wait([for (var i = 0; i < depth; i++) worker()]);
  clock.stop();
  stdout.writeln(
    RungResult(units: sizes.length, millis: clock.elapsedMilliseconds),
  );
}

Future<void> _write(
  String rung,
  String path,
  Uint8List bytes,
  DateTime mtime,
) async {
  switch (rung) {
    case 'setup':
      return;
    case 'bare-sync':
      File(path).writeAsBytesSync(bytes);
    case 'bare-async':
      await File(path).writeAsBytes(bytes);
    case 'sink':
      await _writeThroughSink(File(path), bytes);
    case 'temp-rename':
      final temp = File('$path.tmp');
      await _writeThroughSink(temp, bytes);
      await temp.rename(path);
    case 'mtime':
      final temp = File('$path.tmp');
      await _writeThroughSink(temp, bytes);
      await temp.setLastModified(mtime);
      await temp.rename(path);
    case 'mode':
      final temp = File('$path.tmp');
      await _writeThroughSink(temp, bytes);
      await temp.setLastModified(mtime);
      posixChmod(temp.path, appliedMode);
      await temp.rename(path);
    case 'full':
      final temp = File('$path.tmp');
      await _writeThroughSink(temp, bytes);
      await temp.setLastModified(mtime);
      posixChmod(temp.path, appliedMode);
      await temp.rename(path);
      final stat = await File(path).stat();
      // Read back, so the closing stat is one a caller wanted: `writeFile`
      // returns these three as the `FileMetadata` the archive commits (§7.3).
      _consume(stat.size ^ stat.mode ^ stat.modified.microsecondsSinceEpoch);
    case 'sync-full':
      final temp = File('$path.tmp');
      temp.writeAsBytesSync(bytes);
      temp.setLastModifiedSync(mtime);
      posixChmod(temp.path, appliedMode);
      temp.renameSync(path);
      final stat = File(path).statSync();
      _consume(stat.size ^ stat.mode ^ stat.modified.microsecondsSinceEpoch);
    default:
      throw ArgumentError('unknown rung: $rung');
  }
}

/// The write `LocalAgent.writeFile` actually performs: an `IOSink` fed a stream
/// of 64 KiB chunks, flushed and closed.
Future<void> _writeThroughSink(File file, Uint8List bytes) async {
  final sink = file.openWrite();
  await sink.addStream(_chunked(bytes));
  await sink.flush();
  await sink.close();
}

/// [bytes] in `chunkBytes` pieces, as views rather than copies — a `sublist`
/// here would put a copy of the whole corpus inside every sink rung's figure and
/// measure that instead of the write.
Stream<List<int>> _chunked(Uint8List bytes) async* {
  if (bytes.length <= chunkBytes) {
    yield bytes;
    return;
  }
  for (var offset = 0; offset < bytes.length; offset += chunkBytes) {
    final end = offset + chunkBytes;
    yield Uint8List.sublistView(
      bytes,
      offset,
      end > bytes.length ? bytes.length : end,
    );
  }
}

/// One buffer as long as the longest file, filled once and viewed per write.
///
/// Content is not random: a filesystem that compresses would make a
/// low-entropy buffer cheap to write, but ext4 and Android's f2fs do not, and a
/// per-file random buffer would put its own generation inside every rung.
Uint8List _sourceBuffer(List<int> sizes) {
  // At least one byte, so `sublistView(buffer, 0, 0)` is legal under `--cap 0`.
  final longest = sizes.fold<int>(1, (a, b) => a > b ? a : b);
  final buffer = Uint8List(longest);
  for (var i = 0; i < longest; i++) {
    buffer[i] = i & 0xFF;
  }
  return buffer;
}

String _pathFor(String root, int index) =>
    '$root/d${index ~/ filesPerDirectory}/f$index.bin';

/// Keeps a read from being optimised away without printing anything.
void _consume(int value) {
  if (value == 0x5EED5EED5EED) stdout.writeln('unreachable');
}

String _mib(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
