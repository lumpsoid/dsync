import 'dart:io';
import 'dart:isolate';

import 'package:dsync/dsync_core/models/read_probe_report.dart';

/// Reads one replica's files several ways and reports what each way cost
/// (task 8347dd).
///
/// **What it is for.** An apply phase left the link idle 75% of the time with
/// nothing queueing, and the standing explanation was that the phone's
/// storage could not be read faster. That explanation rests on two figures —
/// §5.3's ~800 µs per file and §17's `readFile` mean — which were both
/// measured through `dart:io`'s asynchronous API, at the one concurrency the
/// code happens to use. Neither can distinguish the device from the way this
/// project asks it. This sweeps both axes so the answer comes from a curve
/// rather than from a single point.
///
/// **Read the shape, not the peak.** Each mode's numbers against depth say
/// something different: a curve that rises and then flattens at a small
/// fixed depth is a pool, one flat from depth 1 is something serialising
/// every read, and one that climbs until it stops is the storage. The modes
/// separate where that limit lives — see [ReadProbeMode].
///
/// **Instrumentation, not a feature.** Nothing in the engine calls this, it
/// changes nothing and it writes nothing: it opens files that are already
/// there, reads them, and counts. It lives in `dsync_core` rather than in
/// `benchmark/` for the reason [ScanProbe] does — the device whose cost
/// profile is in question is a phone, and a desktop figure cannot stand in
/// for one.
class ReadProbe {
  /// How many files each sample reads.
  ///
  /// Not the whole tree, deliberately. Every sample must read the *same*
  /// corpus for the numbers to be subtractable, and a sweep is
  /// `modes × depths` full passes — over 14k files that is an hour. Six
  /// thousand files is a few seconds per sample on a phone, which is far
  /// enough above this device's noise (SPEC §5.3 quotes ±2 s on walks an
  /// order of magnitude longer) to read a curve from.
  final int fileLimit;

  const ReadProbe({this.fileLimit = 6000});

  /// The depths [run] sweeps unless told otherwise: doublings, so a curve is
  /// read across a range rather than around a point, and far enough past
  /// `Applier.defaultConcurrency` (16) that a limit at the depth a run
  /// happens to use is visible as a limit rather than as the end of the
  /// chart.
  static const defaultDepths = [1, 2, 4, 8, 16, 32, 64];

  /// Sweeps [modes] across [depths] over the first [fileLimit] files under
  /// [rootPath], in sorted path order.
  ///
  /// [onSample] is called as each sample lands, because the sweep takes
  /// minutes on the device it exists for and a head showing nothing until
  /// the end is a head that gets killed.
  ///
  /// **The corpus is collected once** and every sample reads that same list.
  /// A per-sample walk would put ~10 s of `Directory.list` (§5.3) inside
  /// figures whose whole point is the reads.
  ///
  /// **Nothing here drops the page cache** — that needs root on Android — so
  /// the first sample is whatever state the device was already in and every
  /// later one is warm. The sweep is still the comparison worth having,
  /// since the modes are being compared against each other and all but the
  /// first are equally warm; but the first sample of the first mode must not
  /// be read as a cold measurement. Run the sweep twice if that matters.
  Future<ReadProbeReport> run({
    required String rootPath,
    List<int> depths = defaultDepths,
    List<ReadProbeMode> modes = ReadProbeMode.values,
    void Function(ReadProbeSample sample)? onSample,
  }) async {
    final root = await Directory(rootPath).resolveSymbolicLinks();
    final corpus = await _collect(root);

    final samples = <ReadProbeSample>[];
    for (final mode in modes) {
      for (final depth in depths) {
        final sample = await _sample(corpus, mode, depth);
        samples.add(sample);
        onSample?.call(sample);
      }
    }

    return ReadProbeReport(
      rootPath: root,
      files: corpus.length,
      samples: samples,
    );
  }

  /// The first [fileLimit] files under [root] in sorted path order.
  ///
  /// Sorted so two runs of the probe on an unchanged tree read the same
  /// files, and so the corpus is a contiguous region of the tree rather than
  /// whatever order the filesystem enumerated — the second matters on
  /// emulated storage, where directory locality is not nothing.
  ///
  /// Symlinks are not followed and a directory that cannot be listed is
  /// skipped silently: this measures cost, and a probe that stopped to
  /// report a `SkippedPath` (SPEC §5) would be doing work the thing it
  /// models does not.
  Future<List<String>> _collect(String root) async {
    final paths = <String>[];
    await for (final entity in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      if (entity is File) paths.add(entity.path);
    }
    paths.sort();
    return paths.length <= fileLimit ? paths : paths.sublist(0, fileLimit);
  }

  Future<ReadProbeSample> _sample(
    List<String> corpus,
    ReadProbeMode mode,
    int depth,
  ) async {
    final clock = Stopwatch()..start();
    final bytes = switch (mode) {
      ReadProbeMode.asyncStream => await _readAsync(
        corpus,
        depth,
        _drainStream,
      ),
      ReadProbeMode.asyncBytes => await _readAsync(
        corpus,
        depth,
        _readAllBytes,
      ),
      ReadProbeMode.syncIsolates => await _readInIsolates(corpus, depth),
    };
    clock.stop();
    return ReadProbeSample(
      mode: mode,
      depth: depth,
      elapsed: clock.elapsed,
      files: corpus.length,
      bytes: bytes,
    );
  }

  /// [depth] workers on this isolate pulling from one shared cursor, which is
  /// how `Applier` has its reads outstanding — N in flight, each taking the
  /// next path when its own finishes, rather than N fixed shards that let a
  /// worker finish early and idle.
  ///
  /// The cursor needs no lock: this is one isolate, and nothing is awaited
  /// between reading `next` and incrementing it.
  ///
  /// [read] is the one thing that differs between the two async modes, so it
  /// is the parameter: a mode switch inside the loop would need a branch for
  /// [ReadProbeMode.syncIsolates] that cannot be reached from here.
  Future<int> _readAsync(
    List<String> corpus,
    int depth,
    Future<int> Function(File file) read,
  ) async {
    var next = 0;
    var bytes = 0;

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= corpus.length) return;
        try {
          // Read into a local and add afterwards. `bytes += await …` would
          // load `bytes` *before* suspending, so two workers resuming either
          // side of the same load would each write back a total missing the
          // other's — a lost update, and one that only shows up at depth.
          final length = await read(File(corpus[index]));
          bytes += length;
        } on FileSystemException {
          // Skipped, exactly as `_readShardSync` skips it — cost, not
          // correctness, and a corpus is only comparable across samples if
          // every mode treats an unreadable file the same way.
        }
      }
    }

    await Future.wait([for (var i = 0; i < depth; i++) worker()]);
    return bytes;
  }

  /// [depth] isolates, each reading its own shard synchronously.
  ///
  /// Shards are round-robin rather than contiguous so each isolate walks the
  /// same spread of the tree: contiguous shards over a sorted list would give
  /// one isolate a directory of large files and another a directory of small
  /// ones, and the sample would then be timing the unluckiest shard.
  ///
  /// Only a byte count comes back. Returning what was read would send
  /// tens of megabytes through a port per sample and measure that instead.
  Future<int> _readInIsolates(List<String> corpus, int depth) async {
    final shards = List.generate(depth, (_) => <String>[]);
    for (var i = 0; i < corpus.length; i++) {
      shards[i % depth].add(corpus[i]);
    }
    final counts = await Future.wait<int>([
      for (final shard in shards) Isolate.run<int>(() => _readShardSync(shard)),
    ]);
    return counts.fold<int>(0, (sum, count) => sum + count);
  }
}

/// [ReadProbeMode.asyncStream]'s read: what `LocalAgent.readFile` yields,
/// drained the way a `writeFile` on the far side drains it.
Future<int> _drainStream(File file) =>
    file.openRead().fold<int>(0, (sum, chunk) => sum + chunk.length);

/// [ReadProbeMode.asyncBytes]'s read.
Future<int> _readAllBytes(File file) async => (await file.readAsBytes()).length;

/// One isolate's shard, read with the blocking call — no `_IOService` port,
/// no VM thread pool, just this thread and the kernel.
///
/// Top level because it is an isolate entry point, and the bytes are folded
/// into a count here rather than returned for the reason [ReadProbe] gives.
int _readShardSync(List<String> paths) {
  var bytes = 0;
  for (final path in paths) {
    try {
      bytes += File(path).readAsBytesSync().length;
    } on FileSystemException {
      // A file that vanished or cannot be read is skipped, exactly as the
      // async modes skip it. Cost, not correctness.
    }
  }
  return bytes;
}
