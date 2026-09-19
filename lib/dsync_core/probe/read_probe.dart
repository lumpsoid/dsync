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
  /// `Applier.defaultConcurrency` that a limit at the depth a run
  /// happens to use is visible as a limit rather than as the end of the
  /// chart.
  static const defaultDepths = [1, 2, 4, 8, 16, 32, 64];

  /// Sweeps [modes] across [depths] over a [fileLimit]-file sample of the
  /// tree under [rootPath].
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
    final tree = await _walk(root);
    final corpus = _sampleCorpus(tree);
    final paths = [for (final file in corpus) file.path];

    final samples = <ReadProbeSample>[];
    for (final mode in modes) {
      for (final depth in depths) {
        final sample = await _sample(paths, mode, depth);
        samples.add(sample);
        onSample?.call(sample);
      }
    }

    return ReadProbeReport(
      rootPath: root,
      files: corpus.length,
      corpusBytes: _totalBytes(corpus),
      treeFiles: tree.length,
      treeBytes: _totalBytes(tree),
      samples: samples,
    );
  }

  /// Every file under [root] with its size, in sorted path order.
  ///
  /// Sorted so two runs of the probe on an unchanged tree see the same tree
  /// in the same order, rather than whatever order the filesystem enumerated.
  ///
  /// Each file is `stat`ed here, once, so the report can put the corpus's
  /// mean file size beside the whole tree's — the one number that says
  /// whether the rates below stand for a real run. It is a walk's worth of
  /// extra `stat`s before any sample starts and none of it is inside a timed
  /// region.
  ///
  /// Symlinks are not followed and a directory that cannot be listed is
  /// skipped silently: this measures cost, and a probe that stopped to
  /// report a `SkippedPath` (SPEC §5) would be doing work the thing it
  /// models does not.
  Future<List<_TreeFile>> _walk(String root) async {
    final files = <_TreeFile>[];
    await for (final entity in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        files.add(_TreeFile(entity.path, (await entity.stat()).size));
      } on FileSystemException {
        // Gone between the walk and the stat, or unreadable. Skipped for the
        // same reason an unreadable file is skipped inside a sample.
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// [fileLimit] files spread evenly across the whole sorted walk — every
  /// `n`th file, taken from the front.
  ///
  /// **Why not the first N.** The tree's cost profile is per-file dominated,
  /// so the corpus's mean file size sets the absolute MiB/s the sweep
  /// reports. A contiguous prefix is one region of one subtree, and on this
  /// project's own replica that region averaged 27.1 KiB against the tree's
  /// 12.7 — flattering every rate by up to ~2×. A stride takes from every
  /// region instead, which is what makes the absolute number usable.
  ///
  /// **What it costs.** Directory locality, deliberately. A prefix reads
  /// whole directories in order; a stride skips between them, so every
  /// sample pays whatever a spread-out read pattern costs on emulated
  /// storage. That is the pattern a real apply has — reconcile hands the
  /// `Applier` changed paths from across the tree, not one directory at a
  /// time — so it is the more honest corpus as well as the more
  /// representative one.
  ///
  /// Deterministic: the same tree gives the same corpus on every run, which
  /// is what makes two sweeps subtractable.
  List<_TreeFile> _sampleCorpus(List<_TreeFile> tree) {
    if (tree.length <= fileLimit) return tree;
    final stride = tree.length / fileLimit;
    return [for (var i = 0; i < fileLimit; i++) tree[(i * stride).floor()]];
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

/// One file in the walk, and what `stat` said it weighs.
class _TreeFile {
  const _TreeFile(this.path, this.size);

  final String path;
  final int size;
}

int _totalBytes(List<_TreeFile> files) =>
    files.fold<int>(0, (sum, file) => sum + file.size);

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
