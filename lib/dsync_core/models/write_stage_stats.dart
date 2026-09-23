import 'package:dsync/dsync_core/models/write_stage.dart';

/// How many served `writeFile`s sat in each [WriteStage] over a session, and
/// for how long each (SPEC §17, task 9a89f7).
///
/// **Because the far span cannot say where a write waited.** A peer's
/// `writeFile` round trip can be ten times what its storage costs, and the
/// difference could be the link, the router's queue, the storage, or the send
/// path — the span is one number for all four. This says how many writes were
/// in each at once, which is the figure that separates "the server runs 16
/// writes and each is slow" from "the server runs one at a time".
///
/// **Residence sums, so the mean in flight is exact.** A stage's summed
/// per-write time divided by the [window] is its time-weighted mean
/// occupancy (Little's law), with no sampling and no per-write state kept
/// past the write. Divided by [files] instead it is what one write spent
/// there.
///
/// **Cumulative, and reported once**, on the `unlock` reply, for the reason
/// `WritePathStats` is.
class WriteStageStats {
  /// Writes that reached their reply (or failed) — the denominator of every
  /// per-write figure.
  final int files;

  /// From the first write's request being decoded to the last write's reply
  /// being flushed: the span the means are taken over.
  final Duration window;

  /// Summed per-write time in each stage. Every stage is present.
  final Map<WriteStage, Duration> residence;

  /// The most writes ever in each stage at once.
  ///
  /// **[WriteStage.queued] is never present.** A write enters it when its
  /// request is decoded but is only known to have done so once it is
  /// dispatched, so its live count is never known — only its sum is.
  final Map<WriteStage, int> peaks;

  /// The most writes ever between dispatch and reply at once — what this end
  /// actually ran concurrently.
  final int peakServing;

  /// Summed time every `fileBytes` frame of these writes sat decoded before
  /// its handler took it: bytes that had arrived and were waiting behind the
  /// router's head of line rather than on the link.
  final Duration held;

  /// How long, over the whole session, the router stopped reading the
  /// connection because a route was not taking frames — `FrameRouter.
  /// inputBlocked`. Session-wide rather than per write, and the one queue
  /// [held] cannot see: bytes that wait undecoded in the socket.
  final Duration inputBlocked;

  WriteStageStats({
    required this.files,
    required this.window,
    required Map<WriteStage, Duration> residence,
    required Map<WriteStage, int> peaks,
    required this.peakServing,
    required this.held,
    required this.inputBlocked,
  }) : residence = {
         for (final stage in WriteStage.values)
           stage: residence[stage] ?? Duration.zero,
       },
       peaks = {
         for (final MapEntry(key: stage, value: peak) in peaks.entries)
           if (stage != WriteStage.queued) stage: peak,
       };

  /// Time-weighted mean number of writes in [stage] across the [window].
  double meanInFlight(WriteStage stage) => _overWindow(residence[stage]!);

  /// Time-weighted mean number of writes between dispatch and reply — every
  /// stage but [WriteStage.queued].
  double get meanServing => _overWindow(
    WriteStage.values
        .where((stage) => stage != WriteStage.queued)
        .fold(Duration.zero, (sum, stage) => sum + residence[stage]!),
  );

  /// What one write spent in [stage].
  Duration perWrite(WriteStage stage) => _perFile(residence[stage]!);

  /// What one write's frames spent, summed, decoded and not yet taken.
  Duration get heldPerWrite => _perFile(held);

  double _overWindow(Duration total) => window == Duration.zero
      ? 0
      : total.inMicroseconds / window.inMicroseconds;

  Duration _perFile(Duration total) =>
      files == 0 ? Duration.zero : total ~/ files;
}
