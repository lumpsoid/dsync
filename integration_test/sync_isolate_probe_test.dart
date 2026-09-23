// Device measurement for task 4759eb — whether a file write done with sync
// dart:io in worker isolates scales where the async path does not. Not part
// of the build.
//
// On the phone an async dart:io call is ~210 µs of a round trip served one at
// a time whatever the concurrency, and the apply's write path is ~10 of them a
// file. A sync call skips the IO service and makes the syscall on the
// isolate's own thread. The per-file work here is the destination's whole
// write: open, write the bytes, close, set mtime, stat — synchronously.
//
// One thing varies per case:
//   async    — the control: that work with async calls, W at once on the
//              main isolate, as the apply does it today;
//   batch    — I worker isolates, each handed its share of the files up
//              front: what sync I/O scales to with no handoff at all;
//   perfile  — I worker isolates fed one file per message, the bytes sent as
//              TransferableTypedData, W in flight: what the handoff costs.
// Each runs as a fresh write (the directory emptied first) and an overwrite,
// into app-private storage and into /storage/emulated/0 (FUSE).
//
// That probe writes one flat directory, where the directory's lock serialises
// creates whatever the concurrency. `--dart-define=PROBE=spread` runs the
// second probe instead (tasks 5532c0, 7080d6): fresh writes into a tree of 30
// files a directory on FUSE, then an overwrite of every one of them with
// different bytes (seed 2 against the fresh pass's 1), each pass timed on its
// own, laid out as write_ops_probe.c lays it out —
//   grouped  consecutive files fill one directory at a time;
//   spread   consecutive files go to different directories, so files being
//            written at once sit in different directories —
// for C in 1, 4, 8, 16 files in flight. The one thing that varies is where
// LocalAgent.writeFile's file calls run:
//   async  — the control, and the real code: `LocalAgent.writeFile` itself,
//            on an agent rooted at the target, fed each file as a stream of
//            64 KiB chunks (what the Applier's prefetch hands it);
//   sync   — the same steps in the same order in sync form, one file per
//            message to C worker isolates, the bytes sent as
//            TransferableTypedData and the metadata sent back.
// Both dispatch the same way: C lanes on the main isolate pull the next file
// index from one shared counter, in plan (path) order — the Applier's single
// queue drained by its workers, and write_ops_probe.c's `next_file`. A sync
// lane owns one worker, so each worker holds one file at a time. The
// created-parent memo is one set on the main isolate, checked before a file
// is dispatched and filled when its write returns — the agent's own memo,
// kept where the agent lives, and C's `dir_made`: files in one directory
// dispatched before its first write returns each create it, in all three.
// A fresh LocalAgent per run settles its once-per-session mode step on an
// untimed first write; the sync workers chmod only if that agent does (on
// FUSE it skips, so neither does). The overwrite pass reuses that run's agent
// and the sync lanes' memo, so it finds every parent remembered and creates
// none — C's `overwrite`, which marks every `dir_made` up front. (A real
// overwrite session starts with an empty memo and pays one create of an
// existing directory per directory, ~1 in 30 files; neither probe does.)
//
// Per file, both Dart modes issue exactly these syscalls (checked with
// strace on Linux; the async and sync forms of dart:io are identical).
// Fresh:
//   stat parent (ENOENT), stat its parent, … up to one that exists, then
//     mkdir each missing one — only when the memo misses;
//   stat target (FFI, writeTargetProbe; ENOENT on a fresh write stops it);
//   stat target (dart:io's File::Open check; ENOENT);
//   openat O_RDWR|O_CREAT|O_TRUNC 0666; write per 64 KiB chunk; close;
//   stat + utimensat (setLastModified); [chmod, not on FUSE]; stat.
// Overwrite — no parent calls, and the target is there:
//   stat target + access W_OK (writeTargetProbe: one link, writable, so in
//     place);
//   stat target (dart:io's File::Open check);
//   openat O_RDWR|O_CREAT|O_TRUNC 0666; write per 64 KiB chunk; close;
//   stat + utimensat; [chmod, not on FUSE]; stat.
// Against write_ops_probe.c's per-file ops, what still differs:
//   - C calls chmod on every file; the real path skips it on FUSE. C's
//     `wall` therefore carries one chmod a file that no Dart cell does —
//     subtract C's `chmod` per_file only at threads=1, where wall ≈ total;
//   - C has neither of the two ENOENT stats before the open on a fresh
//     write, nor, on an overwrite, the three calls before it (the probe's
//     stat + access and dart:io's stat), which there find the file;
//   - C opens O_WRONLY, dart:io O_RDWR;
//   - C's mkdirs calls mkdir on every path component from `/` (EEXIST
//     ignored), Dart stats down to the first existing ancestor and mkdirs
//     only the missing ones (fresh only; neither creates on an overwrite);
//   - C has no byte handoff: no stream (async) or isolate message (sync);
//   - C's overwrite writes the same bytes again (0x5a both passes); Dart's
//     writes different ones (seed 2 over 1), as a real overwrite does;
//   - C's overwrite is a second process on the tree its fresh pass just left
//     (run_write_ops_probe.sh's pass loop); Dart's follows its fresh pass in
//     the same process, after an untimed listing;
//   - sizes share the distribution and seed, not the generator (drand48 vs
//     dart:math), so the files differ one by one.
// So a Dart `grouped`/`spread` cell at concurrency C compares with C's
// `wall_us_per_file` for the same layout, pass and threads=C, less that
// chmod — for an overwrite, rung 6's ~270 µs at 16 threads.
//
// Each fresh cell is ~30 s on the phone; its overwrite, at rung 5's ~1 ms a
// file or less, adds a few seconds, so the 32 cells (2 layouts × 2 modes × 4
// concurrencies × 2 repeats) run ~17–19 min where the fresh-only probe ran
// ~16.
//
//   adb shell appops set --uid com.example.dsync MANAGE_EXTERNAL_STORAGE allow
//   flutter drive --profile -d <id> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/sync_isolate_probe_test.dart \
//     [--dart-define=PROBE=spread]
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/posix_chmod.dart';
import 'package:dsync/dsync_core/agent/write_target_probe.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _files = int.fromEnvironment('FILES', defaultValue: 1500);
const _repeats = int.fromEnvironment('REPEATS', defaultValue: 2);
const _meanBytes = 13007; // SPEC §5.3's 179.5 MiB / 14,471
const _inFlight = 16;
const _isolateCounts = [1, 2, 4, 8];
const _probe = String.fromEnvironment('PROBE', defaultValue: 'flat');
const _fuseRoot = String.fromEnvironment(
  'ROOT',
  defaultValue: '/storage/emulated/0/dsync-sync-probe',
);
const _perDir = 30; // write_ops_probe.c's PER_DIR
const _concurrencies = [1, 4, 8, 16];
const _layouts = ['grouped', 'spread'];
const _mtimeUs = 1700000000000000;
final _mtime = DateTime.fromMicrosecondsSinceEpoch(_mtimeUs);
const _mode = 0x1A4; // 0644, write_ops_probe.c's
const _chunk = 64 * 1024; // what File.openRead yields, so the prefetch too

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'sync isolate probe',
    (tester) async {
      final results = <String, Object>{};
      final sizes = _sizes();
      final private = '${Directory.systemTemp.path}/dsync-sync-probe';
      await _awaitWritable(_fuseRoot);

      final workers = [
        for (var i = 0; i < _isolateCounts.last; i++) await _Worker.spawn(),
      ];

      Future<void> run(
        String mount,
        String root,
        String mode,
        int isolates,
        int repeat,
      ) async {
        final dir = Directory('$root/t');
        for (final pass in ['fresh', 'overwrite']) {
          if (pass == 'fresh') {
            if (dir.existsSync()) dir.deleteSync(recursive: true);
            dir.createSync(recursive: true);
          }
          final seed = pass == 'fresh' ? 1 : 2;
          final clock = Stopwatch()..start();
          switch (mode) {
            case 'async':
              await _asyncWrites(dir.path, sizes, seed);
            case 'batch':
              await Future.wait([
                for (var w = 0; w < isolates; w++)
                  workers[w].batch(dir.path, sizes, w, isolates, seed),
              ]);
            case 'perfile':
              await _perFile(
                workers.sublist(0, isolates),
                dir.path,
                sizes,
                seed,
              );
          }
          clock.stop();
          final landed = dir.listSync().length;
          final perFile = clock.elapsedMicroseconds ~/ _files;
          _log(
            'RESULT mount=$mount mode=$mode isolates=$isolates pass=$pass '
            'repeat=$repeat landed=$landed usPerFile=$perFile',
          );
          results['$mount-$mode-i$isolates-$pass-r$repeat'] = perFile;
        }
      }

      final cases = [
        for (final (mount, root) in [
          ('private', private),
          ('fuse', _fuseRoot),
        ]) ...[
          (mount, root, 'async', 0),
          for (final i in _isolateCounts) (mount, root, 'batch', i),
          for (final i in _isolateCounts) (mount, root, 'perfile', i),
        ],
      ];
      for (var repeat = 0; repeat < _repeats; repeat++) {
        for (var c = 0; c < cases.length; c++) {
          final (mount, root, mode, isolates) =
              cases[(c + repeat) % cases.length];
          await run(mount, root, mode, isolates, repeat);
        }
      }

      for (final worker in workers) {
        worker.close();
      }
      Directory(private).deleteSync(recursive: true);
      Directory(_fuseRoot).deleteSync(recursive: true);
      binding.reportData = results;
    },
    timeout: Timeout.none,
    skip: _probe != 'flat',
  );

  testWidgets(
    'spread fresh-write and overwrite probe',
    (tester) async {
      final results = <String, Object>{};
      final sizes = _sizes();
      await _awaitWritable(_fuseRoot);

      final workers = [
        for (var i = 0; i < _concurrencies.last; i++) await _Worker.spawn(),
      ];

      Future<void> run(String layout, String mode, int c, int repeat) async {
        final root = Directory('$_fuseRoot/t');
        if (root.existsSync()) root.deleteSync(recursive: true);
        root.createSync(recursive: true);
        final agent = await _settledAgent(root.path);
        // The sync lanes' created-parent memo, kept across both passes as the
        // agent keeps its own.
        final createdParents = <String>{};
        for (final (pass, seed) in [('fresh', 1), ('overwrite', 2)]) {
          final clock = Stopwatch()..start();
          switch (mode) {
            case 'async':
              await _asyncTree(agent, layout, sizes, c, seed);
            case 'sync':
              await _syncTree(
                workers.sublist(0, c),
                root.path,
                layout,
                sizes,
                seed,
                createdParents,
                applyMode: !agent.chmodUnavailable,
              );
          }
          clock.stop();
          final landed = root
              .listSync(recursive: true)
              .whereType<File>()
              .length;
          final perFile = clock.elapsedMicroseconds ~/ _files;
          _log(
            'RESULT probe=spread layout=$layout mode=$mode concurrency=$c '
            'pass=$pass repeat=$repeat landed=$landed usPerFile=$perFile',
          );
          final key = pass == 'fresh' ? '' : '-$pass';
          results['$layout-$mode-c$c$key-r$repeat'] = perFile;
        }
      }

      final cases = [
        for (final layout in _layouts)
          for (final mode in ['async', 'sync'])
            for (final c in _concurrencies) (layout, mode, c),
      ];
      for (var repeat = 0; repeat < _repeats; repeat++) {
        for (var i = 0; i < cases.length; i++) {
          final (layout, mode, c) = cases[(i + repeat) % cases.length];
          await run(layout, mode, c, repeat);
        }
      }

      for (final worker in workers) {
        worker.close();
      }
      Directory(_fuseRoot).deleteSync(recursive: true);
      binding.reportData = results;
    },
    timeout: Timeout.none,
    skip: _probe != 'spread',
  );
}

/// File [i]'s root-relative path in write_ops_probe.c's tree: `grouped` fills
/// one directory at a time, `spread` sends consecutive files to different
/// ones.
String _treePath(String layout, int i) {
  final dirs = (_files + _perDir - 1) ~/ _perDir;
  final k = (layout == 'spread' ? i % dirs : i ~/ _perDir) * _perDir;
  return 'd${k ~/ (_perDir * _perDir)}/d${(k ~/ _perDir) % _perDir}/f$i.bin';
}

/// A fresh session's agent on [root], its once-per-session mode step settled
/// by an untimed first write that is then removed. Its archive and lock are
/// never touched: `writeFile` reaches neither.
Future<LocalAgent> _settledAgent(String root) async {
  final state = '${Directory.systemTemp.path}/dsync-spread-state';
  final agent = LocalAgent(
    rootPath: root,
    archiveStore: JsonlArchiveStore(
      File('$state/archive.jsonl'),
      ArchiveHeader(
        schemaVersion: JsonlArchiveStore.schemaVersion,
        profileId: 'probe',
        rootPath: root,
      ),
    ),
    replicaLock: ReplicaLock(File('$state/lock')),
  );
  await agent.writeFile(
    '.settle',
    Stream.value(const [0]),
    mtime: _mtimeUs,
    mode: _mode,
  );
  File('$root/.settle').deleteSync();
  return agent;
}

/// [bytes] as the Applier's prefetch hands them to `writeFile`: the source
/// read's 64 KiB chunks.
Stream<List<int>> _chunked(Uint8List bytes) => Stream.fromIterable([
  for (var at = 0; at < bytes.length; at += _chunk)
    Uint8List.sublistView(bytes, at, min(at + _chunk, bytes.length)),
]);

/// The control, and the real code: [lanes] lanes pulling the next file from
/// one shared counter in plan order, each handing it to
/// `LocalAgent.writeFile` and checking the size it reports, as the Applier's
/// workers do.
Future<void> _asyncTree(
  LocalAgent agent,
  String layout,
  List<int> sizes,
  int lanes,
  int seed,
) async {
  var next = 0;
  Future<void> lane() async {
    while (next < sizes.length) {
      final i = next++;
      final written = await agent.writeFile(
        _treePath(layout, i),
        _chunked(_bytes(sizes[i], seed)),
        mtime: _mtimeUs,
        mode: _mode,
      );
      if (written.size != sizes[i]) throw StateError('f$i: ${written.size}');
    }
  }

  await Future.wait([for (var l = 0; l < lanes; l++) lane()]);
}

/// The same work in [workers]: one lane per worker, pulling the next file
/// from the shared counter and sending it over, so each worker holds one file
/// at a time. The created-parent memo, [createdParents], stays here, where the
/// agent's would — checked before a file is sent, filled when its write comes
/// back.
Future<void> _syncTree(
  List<_Worker> workers,
  String root,
  String layout,
  List<int> sizes,
  int seed,
  Set<String> createdParents, {
  required bool applyMode,
}) async {
  var next = 0;
  Future<void> lane(_Worker worker) async {
    while (next < sizes.length) {
      final i = next++;
      final path = resolveWithinRoot(root, _treePath(layout, i));
      final parent = File(path).parent.path;
      final written = await worker.writeFile(
        path,
        TransferableTypedData.fromList([_bytes(sizes[i], seed)]),
        createParent: !createdParents.contains(parent),
        applyMode: applyMode,
      );
      createdParents.add(parent);
      if (written.size != sizes[i]) throw StateError('f$i: ${written.size}');
    }
  }

  await Future.wait([for (final worker in workers) lane(worker)]);
}

/// `LocalAgent.writeFile`'s steps in sync form, in its order, for a target
/// the probe finds writable in place (every one here: absent on a fresh
/// write, a single-link writable file on an overwrite): the parent if the
/// memo missed, the write-target probe, open, the bytes a chunk per write,
/// close, mtime, the mode step if the agent takes it, the closing stat.
/// Returns what writeFile's FileMetadata carries.
_Written _writeFileSync(
  String path,
  Uint8List bytes, {
  required bool createParent,
  required bool applyMode,
}) {
  final target = File(path);
  if (createParent) target.parent.createSync(recursive: true);
  if (!probeWriteTarget(target.path).writesInPlace) {
    throw StateError('$path: not writable in place');
  }
  final file = target.openSync(mode: FileMode.write);
  try {
    for (var at = 0; at < bytes.length; at += _chunk) {
      file.writeFromSync(bytes, at, min(at + _chunk, bytes.length));
    }
  } finally {
    file.closeSync();
  }
  try {
    target.setLastModifiedSync(_mtime);
  } on FileSystemException {
    // Best-effort, as in writeFile.
  }
  if (applyMode) posixChmod(target.path, _mode);
  final stat = target.statSync();
  return (
    size: stat.size,
    mtime: stat.modified.microsecondsSinceEpoch,
    mode: stat.mode & 0xFFF,
  );
}

/// FileMetadata's fields, as a worker sends them back.
typedef _Written = ({int size, int mtime, int mode});

/// Seeded sizes averaging [_meanBytes], drawn exponentially like the apply
/// harness's tree.
List<int> _sizes() {
  final random = Random(4759);
  return [
    for (var i = 0; i < _files; i++)
      max(1, (-log(1 - random.nextDouble()) * _meanBytes).round()),
  ];
}

/// [size] bytes whose content depends on [seed], so an overwrite changes them.
Uint8List _bytes(int size, int seed) =>
    Uint8List(size)..fillRange(0, size, seed);

/// The destination's write, synchronously: open, write, close, mtime, stat.
void _writeSync(String path, Uint8List bytes) {
  final file = File(path)..writeAsBytesSync(bytes);
  file.setLastModifiedSync(_mtime);
  file.statSync();
}

/// The control: the same work through async calls, [_inFlight] at once on
/// this isolate.
Future<void> _asyncWrites(String dir, List<int> sizes, int seed) async {
  var next = 0;
  Future<void> lane() async {
    while (next < sizes.length) {
      final i = next++;
      final file = File('$dir/f$i');
      await file.writeAsBytes(_bytes(sizes[i], seed));
      await file.setLastModified(_mtime);
      await file.stat();
    }
  }

  await Future.wait([for (var l = 0; l < _inFlight; l++) lane()]);
}

/// One file per message, round-robin over [workers], [_inFlight] in flight.
Future<void> _perFile(
  List<_Worker> workers,
  String dir,
  List<int> sizes,
  int seed,
) async {
  var next = 0;
  Future<void> lane(int l) async {
    while (next < sizes.length) {
      final i = next++;
      await workers[i % workers.length].one(
        '$dir/f$i',
        TransferableTypedData.fromList([_bytes(sizes[i], seed)]),
      );
    }
  }

  await Future.wait([for (var l = 0; l < _inFlight; l++) lane(l)]);
}

/// A long-lived isolate doing sync writes. Spawned once, outside every timed
/// region.
class _Worker {
  final SendPort _send;
  final ReceivePort _replies;
  final Isolate _isolate;
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;

  _Worker._(this._send, this._replies, this._isolate) {
    _replies.listen((message) {
      switch (message) {
        case int id:
          _pending.remove(id)!.complete(null);
        case (int id, _Written written):
          _pending.remove(id)!.complete(written);
      }
    });
  }

  static Future<_Worker> spawn() async {
    final handshake = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, handshake.sendPort);
    final send = await handshake.first as SendPort;
    final replies = ReceivePort();
    send.send(replies.sendPort);
    return _Worker._(send, replies, isolate);
  }

  Future<Object?> _call(Object message) {
    final id = _nextId++;
    final done = _pending[id] = Completer<Object?>();
    _send.send((id, message));
    return done.future;
  }

  Future<void> batch(
    String dir,
    List<int> sizes,
    int lane,
    int lanes,
    int seed,
  ) => _call(('batch', dir, sizes, lane, lanes, seed));

  Future<_Written> writeFile(
    String path,
    TransferableTypedData bytes, {
    required bool createParent,
    required bool applyMode,
  }) async =>
      await _call(('writeFile', path, bytes, createParent, applyMode))
          as _Written;

  Future<void> one(String path, TransferableTypedData bytes) =>
      _call(('one', path, bytes));

  void close() {
    _replies.close();
    _isolate.kill();
  }
}

void _workerMain(SendPort handshake) {
  final inbox = ReceivePort();
  handshake.send(inbox.sendPort);
  late final SendPort replies;
  inbox.listen((message) {
    if (message is SendPort) {
      replies = message;
      return;
    }
    final (id, job) = message as (int, Object);
    switch (job) {
      case (
        'batch',
        String dir,
        List<int> sizes,
        int lane,
        int lanes,
        int seed,
      ):
        for (var i = lane; i < sizes.length; i += lanes) {
          _writeSync('$dir/f$i', _bytes(sizes[i], seed));
        }
      case (
        'writeFile',
        String path,
        TransferableTypedData bytes,
        bool createParent,
        bool applyMode,
      ):
        replies.send((
          id,
          _writeFileSync(
            path,
            bytes.materialize().asUint8List(),
            createParent: createParent,
            applyMode: applyMode,
          ),
        ));
        return;
      case ('one', String path, TransferableTypedData bytes):
        _writeSync(path, bytes.materialize().asUint8List());
    }
    replies.send(id);
  });
}

/// Waits for the All-files grant, which `adb shell appops` gives only once
/// the install has put the package there.
Future<void> _awaitWritable(String root) async {
  for (var attempt = 0; attempt < 120; attempt++) {
    try {
      Directory(root).createSync(recursive: true);
      File('$root/.probe')
        ..writeAsStringSync('x')
        ..deleteSync();
      return;
    } on FileSystemException {
      if (attempt % 10 == 0) _log('waiting for the All-files grant');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  throw StateError('$root never became writable');
}

void _log(String line) => debugPrint('[bench] $line');
