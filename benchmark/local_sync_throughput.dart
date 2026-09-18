// Scratch benchmark for task 0f7dfc — where a sync's wall time actually goes
// once requests are pipelined (SPEC §4.2) and archive commits are batched
// (SPEC §8.2). Not part of the build.
//
// It exists to answer one question the phone cannot: a real run measured
// 1.40 MiB/s over a link that does far better than that, so the ceiling is
// either the link or this code. Running the identical code path between two
// directories on one machine takes the link out of it.
//
//   dart run benchmark/local_sync_throughput.dart
//   dart run benchmark/local_sync_throughput.dart --files 14471 --mib 180
//   dart run benchmark/local_sync_throughput.dart --transport local
//   dart run benchmark/local_sync_throughput.dart --latency-ms 10
//
// `--transport unix` is the interesting one: same `SocketChannel`,
// `FlushedSink`, `FrameRouter`, `RequestWindow` and `Applier` as the phone
// uses, without TLS or a radio. `local` is the floor — no protocol at all.
//
// `--latency-ms` is what makes a local run resemble the phone at all. The
// identical tree costs 2.8 s of apply over a unix socket and 131.5 s over
// Wi-Fi, so whatever the difference is, it is not work — it is what this
// code does while it waits. The flag puts the waiting back, through a
// forwarding proxy that delays each direction by half of it.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Where the compiled CLI is. Built by this script if it is not there yet.
const _cliPath = '/tmp/dsync-benchmark';

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);

  final root = await Directory.systemTemp.createTemp('dsync_throughput');
  stdout.writeln('workspace: ${root.path}');
  try {
    await _buildCli();

    final source = Directory('${root.path}/a')..createSync();
    final dest = Directory('${root.path}/b')..createSync();
    final state = Directory('${root.path}/state')..createSync();

    stdout.writeln(
      'generating ${options.files} files, ${options.mib} MiB '
      '(${(options.mib * 1024 / options.files).toStringAsFixed(1)} KiB '
      'average)…',
    );
    final generated = await _generateTree(source, options);
    stdout.writeln('generated ${_mib(generated)} MiB');
    stdout.writeln('');

    await switch (options.transport) {
      'unix' => _syncOverUnixSocket(root, source, dest, state, options.latency),
      'local' => _syncLocally(source, dest, state),
      final other => throw ArgumentError('unknown transport: $other'),
    };
  } finally {
    if (!options.keep) await root.delete(recursive: true);
  }
}

/// Builds the CLI once, so the run measures the release code rather than the
/// JIT warming up.
Future<void> _buildCli() async {
  if (File(_cliPath).existsSync()) return;
  stdout.writeln('compiling $_cliPath…');
  final built = await Process.run('dart', [
    'compile',
    'exe',
    'bin/dsync.dart',
    '-o',
    _cliPath,
  ]);
  if (built.exitCode != 0) {
    throw StateError('compile failed:\n${built.stderr}');
  }
}

/// Writes a tree shaped like the one the phone run measured: mostly small
/// files with a long tail, spread over nested directories.
///
/// The tail matters. A run whose files are all one size cannot show
/// head-of-line blocking, and the phone run's `writeFile` max of 4.7 s
/// against a 21 ms mean says the real tree has one.
Future<int> _generateTree(Directory root, _Options options) async {
  final random = Random(20260918);
  final totalBytes = options.mib * 1024 * 1024;

  // 1% of the files carry 60% of the bytes; the rest share the remainder.
  final largeCount = max(1, options.files ~/ 100);
  final largeBytes = (totalBytes * 0.6) ~/ largeCount;
  final smallBytes = (totalBytes * 0.4) ~/ (options.files - largeCount);

  var written = 0;
  for (var i = 0; i < options.files; i++) {
    final isLarge = i % 100 == 0 && i ~/ 100 < largeCount;
    final size = isLarge
        ? largeBytes
        : max(1, smallBytes + random.nextInt(smallBytes) - smallBytes ~/ 2);

    // Three levels, ~20 files per leaf, so the tree walks like a real one.
    final dir = Directory(
      '${root.path}/d${i ~/ 8000}/d${(i ~/ 400) % 20}/d${(i ~/ 20) % 20}',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);

    await File('${dir.path}/f$i.bin').writeAsBytes(_bytes(size, i));
    written += size;
  }
  return written;
}

/// One block of random bytes, sliced at a per-file offset to give every file
/// distinct content.
///
/// Drawing every byte from a `Random` instead costs minutes for a 180 MiB
/// tree and buys nothing: nothing in this path compresses, so all the content
/// has to be is distinct and not a run of zeroes.
final Uint8List _block = () {
  final random = Random(20260918);
  return Uint8List.fromList(
    List<int>.generate(1 << 20, (_) => random.nextInt(256)),
  );
}();

Uint8List _bytes(int size, int seed) {
  final out = Uint8List(size);
  final offset = (seed * 7919) % _block.length;
  for (var written = 0; written < size;) {
    final from = (offset + written) % _block.length;
    final take = min(size - written, _block.length - from);
    out.setRange(written, written + take, _block, from);
    written += take;
  }
  return out;
}

/// A sync over `dsync agent --listen` (SPEC §4.2's unix socket): the same
/// protocol stack the phone drives, minus TLS and the radio.
Future<void> _syncOverUnixSocket(
  Directory root,
  Directory source,
  Directory dest,
  Directory state,
  Duration latency,
) async {
  final socketPath = '${root.path}/agent.sock';
  final agent = await Process.start(
    _cliPath,
    ['agent', '--listen', socketPath],
    environment: {'XDG_STATE_HOME': '${state.path}/remote'},
  );
  agent.stdout.drain<void>();
  final agentErrors = <String>[];
  agent.stderr.listen((bytes) => agentErrors.add(String.fromCharCodes(bytes)));

  ServerSocket? proxy;
  try {
    await _waitForSocket(socketPath);
    var reachedAt = socketPath;
    if (latency > Duration.zero) {
      reachedAt = '${root.path}/proxy.sock';
      proxy = await _startDelayProxy(reachedAt, socketPath, latency ~/ 2);
      stdout.writeln(
        'through a proxy adding ${latency.inMilliseconds} ms round trip',
      );
    }
    await _runSync(
      source.path,
      'unix://$reachedAt:${dest.path}',
      state,
      agentErrors,
    );
  } finally {
    await proxy?.close();
    agent.kill();
    await agent.exitCode;
  }
}

/// Forwards [listenPath] to [targetPath], holding every chunk for [oneWay]
/// first — a link with latency and nothing else.
///
/// Each chunk is forwarded on its own timer rather than through a queue this
/// awaits, so the proxy adds delay without also adding a bottleneck of its
/// own: any number of chunks are in flight at once, exactly as on a real
/// link.
Future<ServerSocket> _startDelayProxy(
  String listenPath,
  String targetPath,
  Duration oneWay,
) async {
  final server = await ServerSocket.bind(
    InternetAddress(listenPath, type: InternetAddressType.unix),
    0,
  );
  server.listen((client) async {
    final upstream = await Socket.connect(
      InternetAddress(targetPath, type: InternetAddressType.unix),
      0,
    );
    void pipe(Socket from, Socket to) {
      from.listen(
        (chunk) => Timer(oneWay, () {
          try {
            to.add(chunk);
          } catch (_) {
            // The far end went away while this chunk was in flight.
          }
        }),
        onDone: () => Timer(oneWay, () => to.close().catchError((_) {})),
        onError: (_) {},
      );
    }

    pipe(client, upstream);
    pipe(upstream, client);
  });
  return server;
}

/// Both replicas in this process, no protocol at all — the floor every
/// transport number is read against.
Future<void> _syncLocally(Directory source, Directory dest, Directory state) =>
    _runSync(source.path, dest.path, state, const []);

Future<void> _runSync(
  String a,
  String b,
  Directory state,
  List<String> agentErrors,
) async {
  final stopwatch = Stopwatch()..start();
  final run = await Process.run(
    _cliPath,
    ['sync', a, b, '--batch', '--timings'],
    environment: {'XDG_STATE_HOME': '${state.path}/local'},
  );
  stopwatch.stop();

  stdout.writeln(run.stderr);
  stdout.writeln('exit ${run.exitCode} in ${stopwatch.elapsed}');
  if (agentErrors.isNotEmpty) {
    stdout.writeln('agent said: ${agentErrors.join()}');
  }
}

Future<void> _waitForSocket(String path) async {
  for (var i = 0; i < 100; i++) {
    if (File(path).existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('the agent never bound $path');
}

class _Options {
  final int files;
  final int mib;
  final String transport;
  final Duration latency;
  final bool keep;

  const _Options({
    required this.files,
    required this.mib,
    required this.transport,
    required this.latency,
    required this.keep,
  });

  static _Options parse(List<String> args) {
    var files = 2000;
    var mib = 25;
    var transport = 'unix';
    var latencyMs = 0;
    var keep = false;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--files':
          files = int.parse(args[++i]);
        case '--mib':
          mib = int.parse(args[++i]);
        case '--transport':
          transport = args[++i];
        case '--latency-ms':
          latencyMs = int.parse(args[++i]);
        case '--keep':
          keep = true;
        default:
          throw ArgumentError('unknown argument: ${args[i]}');
      }
    }
    return _Options(
      files: files,
      mib: mib,
      transport: transport,
      latency: Duration(milliseconds: latencyMs),
      keep: keep,
    );
  }
}

String _mib(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);
