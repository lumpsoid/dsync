// Scratch probe for task 99d149 — where a scan's resident memory goes, stage
// by stage, on a synthetic tree. Not part of the build.
//
// A cold scan-only run on the phone's 14,471-file tree grows the process by
// ~41 MiB (task ac2f3a), and every copy of every listing priced in task
// 4b62a1 accounts for ~8 MiB of it. This walks the same pipeline the agent
// walks — archive load, scan, reconcile — and reads the resident set between
// the stages, so the growth is attributed to a stage before anyone guesses at
// a structure.
//
// **Stages in one process, variants in another.** The stage deltas have to
// come from a single process, because that is the quantity being divided up;
// the variants that answer "was it the collector" run the same stages under a
// different heap cap, which only a fresh VM can apply.
//
//   dart run benchmark/scan_memory_probe.dart                 # build + all
//   dart run benchmark/scan_memory_probe.dart --root <dir>    # reuse a tree
//   dart run benchmark/scan_memory_probe.dart --keep          # leave it
import 'dart:io';

import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/reconcile/reconciler.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';

/// The phone tree task ac2f3a measured: 14,471 files averaging 12.7 KiB.
const treeFiles = 14471;
const meanFileBytes = 12.7 * 1024;

/// Files per directory, so the walk has a realistic fan-out rather than one
/// directory with 14k children in it.
const filesPerDir = 100;

/// Heap caps the stages are re-run under. `0` is the VM's own sizing; the
/// others force the collector to work harder, which is what separates live
/// data from the headroom the old generation is carrying.
const heapCapsMiB = [0, 64, 32];

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'stages') {
    await _runStages(args[1]);
    return;
  }
  if (args.isNotEmpty && args.first == 'rung') {
    await _runRung(args[1], args[2]);
    return;
  }

  final keep = args.contains('--keep');
  final given = _flag(args, '--root');
  final root = given ?? await _buildTree();
  try {
    stdout.writeln('tree: $root');
    for (final cap in heapCapsMiB) {
      stdout.writeln(
        cap == 0 ? '\nheap: VM default' : '\nheap: --old_gen_heap_size=$cap',
      );
      final result = await Process.run(Platform.executable, [
        if (cap != 0) '--old_gen_heap_size=$cap',
        'run',
        Platform.script.toFilePath(),
        'stages',
        root,
      ], workingDirectory: Directory.current.path);
      stdout.write(result.stdout);
      stderr.write(result.stderr);
    }
    // Which rung of the walk the scan's growth is in. Each in its own
    // process, because what is being compared is one number per run.
    stdout.writeln('\nrungs, each in a fresh VM');
    for (final rung in _rungs) {
      final result = await Process.run(Platform.executable, [
        'run',
        Platform.script.toFilePath(),
        'rung',
        rung,
        root,
      ], workingDirectory: Directory.current.path);
      stdout.write(result.stdout);
      stderr.write(result.stderr);
    }
  } finally {
    if (given == null && !keep) {
      Directory(root).deleteSync(recursive: true);
    } else {
      stdout.writeln('\nkept: $root');
    }
  }
}

const _rungs = [
  'list',
  'list-stat',
  'list-stat-entry',
  'scan-warm',
  'scan-cold',
];

/// One rung of the walk, in a process of its own: how much resident memory
/// it costs to visit every path this way and hold nothing but a count.
///
/// The rungs are cumulative, so each one's cost is the difference from the
/// one above it — which is how "the walk allocates it" is told apart from
/// "our per-entry work allocates it".
Future<void> _runRung(String rung, String root) async {
  final before = ProcessInfo.currentRss;
  var seen = 0;
  Object? held;

  switch (rung) {
    // `dart:io`'s own recursive walk and nothing else: one
    // `FileSystemEntity` and one path `String` per child.
    case 'list':
      await for (final child in Directory(root).list(recursive: true)) {
        if (child is File) seen++;
      }
    // Plus the `stat` every scan needs (SPEC §5.1).
    case 'list-stat':
      await for (final child in Directory(root).list(recursive: true)) {
        if (child is! File) continue;
        await child.stat();
        seen++;
      }
    // The same walk with `dart:io`'s blocking calls instead of its
    // asynchronous ones. Every async file operation goes out through the IO
    // service — a request list, a response list and a future per call — and
    // the rungs above say that is ~2.3 KB per `stat`, which is most of what
    // a scan allocates (task 99d149).
    case 'list-sync':
      for (final child in Directory(root).listSync(recursive: true)) {
        if (child is File) seen++;
      }
    case 'list-statsync-entry':
      final entries = <ScanEntry>[];
      for (final child in Directory(root).listSync(recursive: true)) {
        if (child is! File) continue;
        final stat = child.statSync();
        entries.add(
          ScanEntry(
            path: child.path.substring(root.length + 1),
            reason: ScanReason.metadataMatched,
            size: stat.size,
            mtime: stat.modified.microsecondsSinceEpoch,
            mode: stat.mode & 0xfff,
            hash: _fakeHashFor(entries.length),
          ),
        );
      }
      seen = entries.length;
      held = entries;
    // Plus the `ScanEntry` the scan keeps for each — the live data, which
    // task 4b62a1 priced at 305 B.
    case 'list-stat-entry':
      final entries = <ScanEntry>[];
      await for (final child in Directory(root).list(recursive: true)) {
        if (child is! File) continue;
        final stat = await child.stat();
        entries.add(
          ScanEntry(
            path: child.path.substring(root.length + 1),
            reason: ScanReason.metadataMatched,
            size: stat.size,
            mtime: stat.modified.microsecondsSinceEpoch,
            mode: stat.mode & 0xfff,
            hash: _fakeHashFor(entries.length),
          ),
        );
      }
      seen = entries.length;
      held = entries;
    // The real thing, archive and all.
    case 'scan-warm':
      final store = _storeFor(root);
      final archive = await store.load();
      final result = await Scanner().scan(rootPath: root, archive: archive);
      seen = result.entries.length;
      held = [archive, result];
    // The same scan with nothing in the archive, so every path is `created`
    // and every file is hashed across `jobs` isolates (SPEC §5.2, §5.3) —
    // the case where the collector's sizing and the hashing interact.
    case 'scan-cold':
      final result = await Scanner().scan(
        rootPath: root,
        archive: const Archive(
          header: ArchiveHeader(
            schemaVersion: 2,
            profileId: 'probe',
            rootPath: '',
          ),
          entries: {},
        ),
      );
      seen = result.entries.length;
      held = result;
    default:
      stderr.writeln('unknown rung: $rung');
      exitCode = 2;
      return;
  }

  final grew = ProcessInfo.currentRss - before;
  final peak = ProcessInfo.maxRss - before;
  if (held != null) _keep(held);
  stdout.writeln(
    '  ${rung.padRight(18)}${_mib(grew).padLeft(10)} held'
    '${_mib(peak).padLeft(10)} peak'
    '${'${(grew / seen).round()} B'.padLeft(12)} an entry   $seen files',
  );
}

/// The measurement itself: one process, one reading between each stage.
Future<void> _runStages(String root) async {
  final report = _Stages();

  // 1. The archive, replayed from a real log the way `LocalAgent` loads it
  //    before a scan (SPEC §8.2).
  final store = _storeFor(root);
  final archive = await store.load();
  report.mark('archive load', extra: '${archive.entries.length} entries');

  // 2. The warm scan — every path matching the archive on size and mtime, so
  //    nothing is hashed and no isolate is spawned. This is the phone's
  //    no-change run, the one that grew 41 MiB.
  final ours = await Scanner().scan(rootPath: root, archive: archive);
  report.mark('scan (warm)', extra: '${ours.entries.length} entries');

  // 3. The peer's listing, which on a first sync arrives in full. Scanned
  //    again here rather than decoded, because what is being measured is the
  //    resident cost of holding it, not of parsing it (task 4b62a1 priced
  //    the decode).
  final theirs = await Scanner().scan(rootPath: root, archive: archive);
  report.mark('second listing', extra: '${theirs.entries.length} entries');

  // 4. Reconciliation over both, which is where the two listings and the
  //    archive are all live at once (SPEC §6).
  final plan = Reconciler().reconcile(ours.entries, theirs.entries);
  report.mark('reconcile', extra: '${plan.actions.length} actions');

  // Nothing above may be collected before the last reading is taken.
  _keep([archive, ours, theirs, plan]);
  stdout.write(report.format());
}

/// Resident set at each stage boundary, as deltas.
class _Stages {
  final int _start = ProcessInfo.currentRss;
  final _rows = <(String, int, int, String)>[];
  int _last = ProcessInfo.currentRss;

  void mark(String stage, {String extra = ''}) {
    final now = ProcessInfo.currentRss;
    _rows.add((stage, now - _last, now - _start, extra));
    _last = now;
  }

  String format() {
    final out = StringBuffer();
    out.writeln(
      '  ${'stage'.padRight(18)}${'added'.padLeft(10)}'
      '${'total'.padLeft(10)}${'per entry'.padLeft(12)}',
    );
    for (final (stage, added, total, extra) in _rows) {
      out.writeln(
        '  ${stage.padRight(18)}${_mib(added).padLeft(10)}'
        '${_mib(total).padLeft(10)}'
        '${'${(added / treeFiles).round()} B'.padLeft(12)}'
        '   $extra',
      );
    }
    out.writeln(
      '  ${'peak'.padRight(18)}'
      '${_mib(ProcessInfo.maxRss - _start).padLeft(10)} over the start',
    );
    return out.toString();
  }
}

JsonlArchiveStore _storeFor(String root) => JsonlArchiveStore(
  File('$root/.dsync-archive.jsonl'),
  ArchiveHeader(
    schemaVersion: JsonlArchiveStore.schemaVersion,
    profileId: 'probe',
    rootPath: root,
  ),
);

/// Builds the tree and the archive log that makes a scan of it a warm one.
Future<String> _buildTree() async {
  final root = Directory.systemTemp.createTempSync('dsync_scan_mem_').path;
  // `Directory.systemTemp` is tmpfs on this machine, which is RAM: a tree
  // there would be measured against the page cache rather than a disk. Put
  // it under the home filesystem instead.
  Directory(root).deleteSync();
  final home = Platform.environment['HOME'] ?? '/var/tmp';
  final real = Directory('$home/.cache').createTempSync('dsync_scan_mem_').path;

  stdout.writeln('building $treeFiles files under $real …');
  final entries = <ScanEntry>[];
  for (var i = 0; i < treeFiles; i++) {
    final path = 'dir${i ~/ filesPerDir}/file$i.bin';
    final file = File('$real/$path')..createSync(recursive: true);
    // Sizes spread around the tree's mean the way a real one is, since the
    // walk stats every file and the archive stores what it read back.
    final size = (meanFileBytes * (0.2 + (i % 17) / 10)).round();
    file.writeAsBytesSync(List<int>.filled(size, 65));
    final stat = file.statSync();
    entries.add(
      ScanEntry(
        path: path,
        reason: ScanReason.created,
        size: stat.size,
        mtime: stat.modified.microsecondsSinceEpoch,
        mode: stat.mode & 0xfff,
        hash: _fakeHashFor(i),
      ),
    );
  }

  final store = JsonlArchiveStore(
    File('$real/.dsync-archive.jsonl'),
    ArchiveHeader(
      schemaVersion: JsonlArchiveStore.schemaVersion,
      profileId: 'probe',
      rootPath: real,
    ),
  );
  for (final entry in entries) {
    await store.commitUpsert(
      ArchiveEntry(
        path: entry.path,
        size: entry.size!,
        mtime: entry.mtime!,
        mode: entry.mode!,
        hash: entry.hash!,
      ),
    );
  }
  await store.flush();
  return real;
}

/// A 64-character hex string, the shape SPEC §15.3 stores. Not a real digest
/// — nothing here verifies content, and hashing 180 MiB to build a fixture
/// would only measure this machine's SHA-256.
String _fakeHashFor(int i) {
  final digits = (i * 2654435761).toRadixString(16);
  return (digits * 64).substring(0, 64);
}

void _keep(Object holder) {
  if (holder.hashCode == 0) stdout.writeln('unreachable');
}

String? _flag(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}

String _mib(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
