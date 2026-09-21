// Measures what loading an archive log costs in memory (task e377a3). Not
// part of the build.
//
//   dart run benchmark/archive_load_probe.dart
//   dart run benchmark/archive_load_probe.dart --entries 100000
//
// The question is whether replaying the log allocates on the order of one
// line at a time or on the order of the whole file. With no mode given this
// re-runs itself per mode in a fresh process and reports two numbers:
//
//  - peak RSS over the load, sampled on a timer. Coarse — it counts garbage
//    the collector has not got to yet — but it is what the process actually
//    asks the OS for.
//  - the smallest `--old_gen_heap_size` the load completes in, binary
//    searched. This is the number that answers the question: a reader that
//    holds the whole file needs a heap the size of the file, and one that
//    holds a line does not.
//
// `stream` is `JsonlArchiveStore.load` as it stands. `whole` is the
// `readAsLines` replay it replaced, kept here only so the two numbers are
// comparable — it is not a second implementation anyone calls.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/models/archive.dart';

Future<void> main(List<String> args) async {
  final entries = int.parse(_flag(args, '--entries') ?? '14471');
  final mode = _flag(args, '--mode');

  if (mode == null) {
    for (final each in ['stream', 'whole']) {
      final run = await _spawn(each, entries, heapMib: null);
      stdout.write(run.stdout);
      stderr.write(run.stderr);
      stdout.writeln(
        '  smallest old-gen heap it completes in: '
        '${await _heapFloor(each, entries)} MiB',
      );
    }
    return;
  }

  final dir = await Directory.systemTemp.createTemp('dsync-archive-probe');
  try {
    final log = File('${dir.path}/probe.jsonl');
    const header = ArchiveHeader(
      schemaVersion: JsonlArchiveStore.schemaVersion,
      profileId: 'probe',
      rootPath: '/probe',
    );
    await _writeLog(log, header, entries);

    final baseline = ProcessInfo.currentRss;
    var peak = baseline;
    final sampler = Timer.periodic(const Duration(microseconds: 500), (_) {
      final rss = ProcessInfo.currentRss;
      if (rss > peak) peak = rss;
    });

    final clock = Stopwatch()..start();
    final loaded = mode == 'whole'
        ? await _loadWhole(log)
        : (await JsonlArchiveStore(log, header).load()).entries;
    clock.stop();
    sampler.cancel();

    final bytes = await log.length();
    stdout.writeln(
      '$mode: ${loaded.length} entries from ${_mib(bytes)} of log in '
      '${clock.elapsedMilliseconds} ms, peak RSS +${_mib(peak - baseline)}',
    );
  } finally {
    await dir.delete(recursive: true);
  }
}

Future<ProcessResult> _spawn(
  String mode,
  int entries, {
  required int? heapMib,
}) {
  return Process.run(Platform.executable, [
    if (heapMib != null) '--old_gen_heap_size=$heapMib',
    Platform.script.toFilePath(),
    '--entries',
    '$entries',
    '--mode',
    mode,
  ]);
}

/// The smallest old-gen heap, in MiB, the load still completes in. Binary
/// searched over whole MiB: a run that needs more dies with an out-of-memory
/// exit rather than a wrong answer, so the bound is exact to a MiB.
Future<int> _heapFloor(String mode, int entries) async {
  var low = 4;
  var high = 512;
  while (low < high) {
    final mid = (low + high) ~/ 2;
    final run = await _spawn(mode, entries, heapMib: mid);
    if (run.exitCode == 0) {
      high = mid;
    } else {
      low = mid + 1;
    }
  }
  return low;
}

/// A compacted log: the header, then one upsert per live path, which is what
/// a run leaves behind (SPEC §8.2).
Future<void> _writeLog(File log, ArchiveHeader header, int entries) async {
  final sink = log.openWrite();
  sink.writeln(
    jsonEncode({
      'op': 'header',
      'schemaVersion': header.schemaVersion,
      'profileId': header.profileId,
      'rootPath': header.rootPath,
    }),
  );
  for (var i = 0; i < entries; i++) {
    sink.writeln(
      jsonEncode({
        'op': 'upsert',
        'path': 'media/camera/folder${i % 97}/IMG_$i.jpg',
        'size': 1024 * 1024 + i,
        'mtime': 1758000000 + i,
        'mode': 420,
        'hash': (i % 16).toRadixString(16) * 64,
      }),
    );
  }
  await sink.flush();
  await sink.close();
}

/// The replay `JsonlArchiveStore._load` used before task e377a3: every line
/// of the file as Dart strings at once, then a second list of the same lines.
///
/// Ends with the same retained-map copies the real `load` makes, so the two
/// modes differ in how the lines are read and in nothing else.
Future<Map<String, ArchiveEntry>> _loadWhole(File log) async {
  final entries = <String, ArchiveEntry>{};
  final lines = (await log.readAsLines())..removeWhere((line) => line.isEmpty);
  final records = lines.skip(1).toList();
  for (final line in records) {
    final record = jsonDecode(line) as Map<String, dynamic>;
    final path = record['path'] as String;
    if (record['op'] == 'delete') {
      entries.remove(path);
    } else {
      entries[path] = ArchiveEntry(
        path: path,
        size: record['size'] as int,
        mtime: record['mtime'] as int,
        mode: record['mode'] as int,
        hash: record['hash'] as String,
      );
    }
  }
  final retained = <String, ArchiveEntry>{}..addAll(entries);
  return Map.unmodifiable(retained);
}

String _mib(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';

String? _flag(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}
