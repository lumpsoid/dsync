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
// second probe instead (task 5532c0): fresh writes into a tree of 30 files a
// directory on FUSE, laid out as write_ops_probe.c lays it out —
//   grouped  consecutive files fill one directory at a time;
//   spread   consecutive files go to different directories, so files being
//            written at once sit in different directories —
// comparing sync writes in C worker isolates with the async control C at once
// on the main isolate, for C in 1, 4, 8, 16. The per-file work adds the parent
// directory, created once per directory as LocalAgent does (each isolate keeps
// its own set, as each agent would). Read it against write_ops_probe.c's
// native `spread` table.
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
final _mtime = DateTime.fromMicrosecondsSinceEpoch(1700000000000000);

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
    'spread fresh-write probe',
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
        final clock = Stopwatch()..start();
        switch (mode) {
          case 'async':
            await _asyncTree(root.path, layout, sizes, c);
          case 'sync':
            await Future.wait([
              for (var w = 0; w < c; w++)
                workers[w].tree(root.path, layout, sizes, w, c),
            ]);
        }
        clock.stop();
        final landed = root.listSync(recursive: true).whereType<File>().length;
        final perFile = clock.elapsedMicroseconds ~/ _files;
        _log(
          'RESULT probe=spread layout=$layout mode=$mode concurrency=$c '
          'pass=fresh repeat=$repeat landed=$landed usPerFile=$perFile',
        );
        results['$layout-$mode-c$c-r$repeat'] = perFile;
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

/// File [i]'s directory in write_ops_probe.c's tree: `grouped` fills one
/// directory at a time, `spread` sends consecutive files to different ones.
String _treeDir(String root, String layout, int i) {
  final dirs = (_files + _perDir - 1) ~/ _perDir;
  final k = (layout == 'spread' ? i % dirs : i ~/ _perDir) * _perDir;
  return '$root/d${k ~/ (_perDir * _perDir)}/d${(k ~/ _perDir) % _perDir}';
}

/// The control for the tree: the same work as [_writeTreeSync] through async
/// calls, [lanes] at once on this isolate, each directory created once.
Future<void> _asyncTree(
  String root,
  String layout,
  List<int> sizes,
  int lanes,
) async {
  final created = <String, Future<void>>{};
  var next = 0;
  Future<void> lane() async {
    while (next < sizes.length) {
      final i = next++;
      final dir = _treeDir(root, layout, i);
      await created.putIfAbsent(
        dir,
        () => Directory(dir).create(recursive: true),
      );
      final file = File('$dir/f$i.bin');
      await file.writeAsBytes(_bytes(sizes[i], 1));
      await file.setLastModified(_mtime);
      await file.stat();
    }
  }

  await Future.wait([for (var l = 0; l < lanes; l++) lane()]);
}

/// Lane [lane] of [lanes] of the tree, synchronously: the parent the first
/// time this isolate meets it, then [_writeSync].
void _writeTreeSync(
  String root,
  String layout,
  List<int> sizes,
  int lane,
  int lanes,
) {
  final created = <String>{};
  for (var i = lane; i < sizes.length; i += lanes) {
    final dir = _treeDir(root, layout, i);
    if (created.add(dir)) Directory(dir).createSync(recursive: true);
    _writeSync('$dir/f$i.bin', _bytes(sizes[i], 1));
  }
}

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
  final _pending = <int, Completer<void>>{};
  var _nextId = 0;

  _Worker._(this._send, this._replies, this._isolate) {
    _replies.listen((message) => _pending.remove(message as int)!.complete());
  }

  static Future<_Worker> spawn() async {
    final handshake = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, handshake.sendPort);
    final send = await handshake.first as SendPort;
    final replies = ReceivePort();
    send.send(replies.sendPort);
    return _Worker._(send, replies, isolate);
  }

  Future<void> _call(Object message) {
    final id = _nextId++;
    final done = _pending[id] = Completer<void>();
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

  Future<void> tree(
    String root,
    String layout,
    List<int> sizes,
    int lane,
    int lanes,
  ) => _call(('tree', root, layout, sizes, lane, lanes));

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
        'tree',
        String root,
        String layout,
        List<int> sizes,
        int lane,
        int lanes,
      ):
        _writeTreeSync(root, layout, sizes, lane, lanes);
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
