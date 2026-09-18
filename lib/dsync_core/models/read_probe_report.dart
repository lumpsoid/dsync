/// How one sample of [ReadProbeReport] read the corpus.
///
/// The three differ in *what sits between this code and the file*, which is
/// the whole question the probe exists to answer: `dart:io`'s asynchronous
/// file operations are not syscalls but messages to a native port handled by
/// a bounded VM thread pool (`_IOService._dispatch`, and
/// `Dart_NewConcurrentNativePort`'s `max_concurrency` parameter), so a
/// per-file cost measured through them is a round trip and not the
/// platform's floor.
enum ReadProbeMode {
  /// `File.openRead()` drained to its end — exactly what `LocalAgent.readFile`
  /// yields and what `Applier._copy` hands to the destination's `writeFile`.
  ///
  /// This is the shape a real run pays. It is one `open`, one `read` per 64
  /// KiB block (`_blockSize` in the SDK's `file_impl.dart`) and one `close`,
  /// each its own dispatch — so a file under 64 KiB still costs a minimum of
  /// four round trips through the pool, not one.
  asyncStream,

  /// `File.readAsBytes()` — the cheapest asynchronous shape there is.
  ///
  /// Present as the floor of the async path rather than because anything
  /// uses it: if [asyncStream] is much dearer than this, the gap is what
  /// streaming's extra dispatches cost and the fix is in how we read. If the
  /// two are close, streaming is not the problem and the cost is the
  /// dispatch itself.
  asyncBytes,

  /// `File.readAsBytesSync()` inside `depth` isolates — a real blocking
  /// syscall on a real thread, with no native port between the call and the
  /// kernel.
  ///
  /// This is the comparison that matters. It is the shape Unison has by
  /// construction, being native code with its own threads, and the one this
  /// project cannot reach through `dart:io`'s async API however deep it
  /// queues. A sync curve that scales where the async curves flatten says
  /// the limit is the VM's pool; both flattening together says the limit is
  /// the device.
  syncIsolates,
}

/// One (mode, depth) pair, and what reading the corpus that way cost.
class ReadProbeSample {
  const ReadProbeSample({
    required this.mode,
    required this.depth,
    required this.elapsed,
    required this.files,
    required this.bytes,
  });

  final ReadProbeMode mode;

  /// Reads in flight: outstanding futures for the async modes, isolates for
  /// [ReadProbeMode.syncIsolates].
  final int depth;

  final Duration elapsed;

  /// Files actually read, which is the corpus size — a sample that read
  /// fewer read something else and is not comparable.
  final int files;

  /// Bytes actually returned by the reads, summed. Not stat'd beforehand:
  /// what a read handed back is the thing that was paid for.
  final int bytes;

  double get filesPerSecond =>
      elapsed.inMicroseconds == 0 ? 0 : files * 1e6 / elapsed.inMicroseconds;

  double get bytesPerSecond =>
      elapsed.inMicroseconds == 0 ? 0 : bytes * 1e6 / elapsed.inMicroseconds;

  /// Wall time per file at this depth — *not* the cost of one read. At depth
  /// N it is that cost divided by however much of N actually overlapped,
  /// which is exactly what the sweep is measuring and why the figure is
  /// reported per sample rather than as one number.
  double get microsPerFile => files == 0 ? 0 : elapsed.inMicroseconds / files;
}

/// What reading this replica's own files costs on this device, swept across
/// read modes and concurrency depths (task 8347dd).
///
/// **Why it exists.** SPEC §17 reports a run's `readFile` as a per-operation
/// mean, and §5.3 reports a scan's content read as one line of a ladder.
/// Both are figures for the *shape this code currently has*: one read per
/// action, `Applier.concurrency` actions at a time, the read consumed inside
/// the remote write. Neither can say what the same files cost read a
/// different way, and that is the question — a phone that gives another tool
/// 64 MiB/s over the same storage is not a phone whose floor we have
/// measured.
class ReadProbeReport {
  const ReadProbeReport({
    required this.rootPath,
    required this.files,
    required this.corpusBytes,
    required this.treeFiles,
    required this.treeBytes,
    required this.samples,
  });

  /// The resolved root the corpus was taken from.
  final String rootPath;

  /// How many files every sample read.
  final int files;

  /// The corpus in bytes, as `stat` reports it — not as the reads returned
  /// it, so that it is the same measure as [treeBytes] and the two means
  /// below are comparable. A sample's own [ReadProbeSample.bytes] is what
  /// came back from the reads, and is lower by whatever could not be read.
  final int corpusBytes;

  /// Every file under the root, and their total size, whether or not the
  /// corpus sampled them.
  ///
  /// Here so the corpus can be checked against the thing it stands for. Cost
  /// on this path is per-file dominated, so a corpus whose mean file is twice
  /// the tree's reports up to ~2× the MiB/s the same device would give on a
  /// real run — the per-mode *ratios* survive that, the absolute rates do
  /// not, and only these two numbers can say which is being read.
  final int treeFiles;
  final int treeBytes;

  final List<ReadProbeSample> samples;

  /// Mean file size of the corpus, against [treeMeanFileSize]. Within a few
  /// percent of each other means the absolute rates can be taken at face
  /// value.
  double get meanFileSize => files == 0 ? 0 : corpusBytes / files;

  double get treeMeanFileSize => treeFiles == 0 ? 0 : treeBytes / treeFiles;

  /// The fastest sample, which is the report's headline: the best this
  /// device gave up under any shape tried.
  ReadProbeSample? get fastest {
    if (samples.isEmpty) return null;
    return samples.reduce(
      (a, b) => b.bytesPerSecond > a.bytesPerSecond ? b : a,
    );
  }

  Iterable<ReadProbeSample> forMode(ReadProbeMode mode) =>
      samples.where((s) => s.mode == mode);
}
