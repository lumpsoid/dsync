import 'dart:async';
import 'dart:collection';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/read_ahead_stats.dart';

/// Reports the read-ahead's counters once an apply is over (SPEC §17).
///
/// A callback for the reason `ApplyProgress` and `ExchangeSink` are: this holds
/// figures it already has and knows nothing about the ledger they end up in.
typedef ReadAheadReport = void Function(ReadAheadStats stats);

/// Owns the *source* side of an apply: reads files ahead of the writers, so
/// that a destination's `writeFile` finds bytes waiting rather than starting
/// the read itself (SPEC §7.2, task 9d2158 §10.3).
///
/// **Why a stage and not another `await` in the worker.** `Applier._copy` was
/// `dest.writeFile(path, source.readFile(path))`, and that stream is lazy: the
/// read cannot begin until the write subscribes, so the destination waits out
/// the whole source read before it has a byte to write. Measured
/// phone-to-desktop over `peer://`, the peer's `starved` — its own report of
/// how much of its `writeFile` span was spent waiting on inbound bytes —
/// equalled the source's `readFile` to within 4% on five of five runs, and was
/// 53–62% of the serialized budget: the largest single term in the apply.
///
/// So the read is a stage of its own. The apply is three stages over three
/// resources, each bounded by the thing that actually constrains it: this one
/// by bytes held (source storage, or the inbound wire), the writers by
/// `Applier.concurrency` (the destination), and `CommitPipeline` by its batch
/// size (a round trip carrying JSON). What this replaces is one `concurrency`
/// counter governing all three.
///
/// **A remote source makes the read a wire operation**, and nothing here
/// changes for it: the buffer then holds bytes arriving on one link while the
/// write drains onto the other. Same budget, different resource — and in that
/// direction it is [maxStreams] that matters more than [budgetBytes], because
/// a `RemoteAgent.readFile` holds one of the connection's 32 window slots
/// (SPEC §4.2) for the whole stream.
///
/// **Bounded in bytes, and there is no file-size threshold.** The bound is on
/// bytes *buffered per stream*, not on bytes per file, so a file larger than
/// the whole budget occupies one slot and one chunk and streams the rest under
/// backpressure exactly as it did before this existed. The bypass path §10.3
/// anticipated — and the threshold that would select it — are both absent
/// rather than chosen, which is the argument task `eebe79` owed and never
/// paid: there is no number to justify because there is no branch.
class ReadAhead {
  /// The most this may hold across every prefetch at once.
  ///
  /// **A megabyte, because that is the guarantee already on the books.** SPEC
  /// §7.2 bounds the apply's buffers on the memory-constrained end at sixteen
  /// streaming writes holding one chunk each, ~1 MiB. In the measured
  /// direction the phone is the *source*, so that megabyte is on the desktop
  /// and this one is the phone's — the same figure, on the device the bound was
  /// written for, and the first apply-path buffer this project has ever had a
  /// reading of ([ReadAheadStats.peakBufferedBytes]).
  static const defaultBudgetBytes = 1024 * 1024;

  /// Bytes one prefetch may hold before its source subscription is paused.
  ///
  /// Sixty-four kilobytes, which is what `File.openRead` yields anyway, so a
  /// file at or above it is paused after its first chunk and a file below it —
  /// the 12.7 KiB mean of the measured tree — is read whole.
  static const defaultStreamBytes = 64 * 1024;

  /// How many reads may be open beyond the writer count — see [maxStreams].
  ///
  /// **Eight, as headroom rather than as the lead itself.** What paces the
  /// prefetch is the queue between the pump and the workers, not this: a slot
  /// is released when the writer takes the last chunk, which on a remote
  /// destination is when the bytes reach the wire and not when the peer replies,
  /// so slots turn over faster than writes finish and the pump is normally
  /// ahead by a queue's worth of files. This is the margin that keeps it from
  /// blocking on a slot while writes are still handing bytes over. Eight rather
  /// than more because the reads are concurrent and §4 finding 1 puts a device
  /// `dart:io` read on a bounded native-port pool, where deeper concurrency
  /// inflates every one of them.
  static const defaultLead = 8;

  /// Total bytes buffered, across every prefetch. Bounds memory.
  final int budgetBytes;

  /// Bytes one prefetch holds before it pauses its source. Bounds nothing on
  /// its own — it is what makes [budgetBytes] a bound on a stream of any
  /// length.
  final int streamBytes;

  /// How many source reads may be open at once. Bounds memory too, but that is
  /// not why it exists: [budgetBytes] alone would admit ~80 concurrent reads of
  /// a tree of 12.7 KiB files, and two things make that wrong, neither of them
  /// memory. A remote source's `readFile` holds a window slot for its whole
  /// stream against a 32-slot window (SPEC §4.2), which has to leave room for
  /// that replica's own commits; and a device read is a message to a bounded
  /// native-port pool (§4 finding 1), which queues.
  ///
  /// So the two bounds bind in different places, on purpose: on a tree of small
  /// files this one binds, and on a workload of files above [streamBytes]
  /// [budgetBytes] does — which is the right outcome there, because a large
  /// file's starvation is per *chunk*, and one chunk of read-ahead per stream is
  /// the whole of what can be won on it.
  ///
  /// **A slot is held from [begin] until the writer has taken the last chunk**,
  /// which is not the same as until the write finishes: a destination consumes
  /// bytes and then does its own six filesystem steps, and a remote one has
  /// them on the wire long before its reply. So this is a bound on reads in
  /// flight and not on files ahead of the writers, and a read that *stalls* is
  /// what makes it visible.
  final int maxStreams;

  int _reservedBytes = 0;
  int _openStreams = 0;
  int _bufferedBytes = 0;
  int _peakBufferedBytes = 0;
  int _prefetched = 0;
  int _completeOnHandover = 0;

  /// Callers of [begin] with no slot yet. Woken head-first as slots free; a
  /// waiter that still does not fit puts itself back at the front, so the
  /// order admissions were asked for is the order they are granted.
  final Queue<Completer<void>> _waiting = Queue();

  ReadAhead({
    required this.maxStreams,
    this.budgetBytes = defaultBudgetBytes,
    this.streamBytes = defaultStreamBytes,
  }) : assert(maxStreams >= 1, 'A read-ahead with no streams reads nothing'),
       assert(
         streamBytes <= budgetBytes,
         'One stream may not reserve more than the whole budget — a prefetch '
         'that can never be admitted deadlocks the apply',
       );

  /// Everything counted so far. Taken once, after the apply.
  ReadAheadStats get stats => ReadAheadStats(
    prefetched: _prefetched,
    completeOnHandover: _completeOnHandover,
    peakBufferedBytes: _peakBufferedBytes,
  );

  /// Starts reading [path] from [source] now, returning once there is a slot
  /// for it.
  ///
  /// [size] is the source's scanned size and is what the reservation is taken
  /// against — the read cannot exceed [streamBytes] of buffer whatever it
  /// turns out to be, so reserving `min(size, streamBytes)` lets a tree of
  /// small files hold many more prefetches inside the same budget than a tree
  /// of large ones.
  ///
  /// The returned [Prefetch] is owed exactly one of [Prefetch.bytes] or
  /// [Prefetch.discard]: both release the slot, and neither happening holds a
  /// source read open for the rest of the run.
  Future<Prefetch> begin(
    String path, {
    required Agent source,
    required int size,
  }) async {
    final reservation = size < streamBytes ? size : streamBytes;
    var requeued = false;
    while (!_admits(reservation)) {
      final slot = Completer<void>();
      // Back of the queue the first time, front of it afterwards: a waiter
      // woken by a release that still does not fit has not lost its turn.
      requeued ? _waiting.addFirst(slot) : _waiting.add(slot);
      requeued = true;
      await slot.future;
    }
    _reservedBytes += reservation;
    _openStreams++;
    _prefetched++;
    return Prefetch._(this, source.readFile(path), reservation);
  }

  /// **Admission is the only thing the shared budget gates, and that is the
  /// invariant that makes this deadlock-free.** An admitted prefetch pauses
  /// only against its own [streamBytes], never against what its neighbours
  /// hold, so a stream a writer is draining can always make progress and
  /// therefore always releases what it reserved. A shared budget that could
  /// pause an admitted stream would let prefetches nobody is consuming yet
  /// starve the one that is.
  bool _admits(int reservation) =>
      _openStreams < maxStreams && _reservedBytes + reservation <= budgetBytes;

  void _buffered(int bytes) {
    _bufferedBytes += bytes;
    if (_bufferedBytes > _peakBufferedBytes) {
      _peakBufferedBytes = _bufferedBytes;
    }
  }

  void _drained(int bytes) => _bufferedBytes -= bytes;

  void _release(int reservation) {
    _reservedBytes -= reservation;
    _openStreams--;
    if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
  }
}

/// One file being read ahead of the writer that will want it.
///
/// Created by [ReadAhead.begin], which has already started the source read:
/// by the time a worker takes this, some or all of the file is in hand.
class Prefetch {
  final ReadAhead _owner;
  final int _reservation;

  /// Chunks read and not yet consumed. [_held] is their total length, kept
  /// beside them rather than summed on demand because it is read on every
  /// chunk in both directions.
  final Queue<List<int>> _chunks = Queue();
  int _held = 0;

  late final StreamSubscription<List<int>> _source;
  bool _sourcePaused = false;
  bool _sourceDone = false;
  Object? _error;
  StackTrace? _stack;

  /// What [bytes] hands the writer.
  ///
  /// **A controller rather than an `async*` generator**, and the difference is
  /// cancellation. A generator can only be torn down where it yields, so one
  /// parked on a stalled read ignores `cancel()` until a byte arrives — which
  /// is exactly the state a `writeFile` that failed part-way leaves it in, and
  /// a source read that has stalled is exactly when giving the slot back
  /// matters. A controller's `onCancel` fires at once.
  late final StreamController<List<int>> _out;

  /// Whether the writer has asked us to stop for now. Tracked from the
  /// controller's own callbacks rather than read off `isPaused`, which also
  /// answers "nobody is listening yet" and must not be confused with it here.
  bool _writerPaused = false;

  /// Whether the writer has subscribed. Nothing leaves the buffer before it
  /// has, so that what [ReadAheadStats.peakBufferedBytes] counts is bytes this
  /// is holding rather than bytes a controller is holding on its behalf.
  bool _listening = false;

  /// Whether the writer cancelled — the one exit on which there is nothing
  /// left to close.
  bool _writerGone = false;

  bool _taken = false;
  bool _released = false;

  Prefetch._(this._owner, Stream<List<int>> source, this._reservation) {
    _out = StreamController<List<int>>(
      onListen: () {
        _listening = true;
        _handOver();
      },
      onPause: () => _writerPaused = true,
      onResume: () {
        _writerPaused = false;
        _handOver();
      },
      onCancel: () {
        _writerGone = true;
        _finish();
      },
    );
    _source = source.listen(_onChunk, onError: _onError, onDone: _onDone);
  }

  /// The file's bytes, from the buffer first and the live read after —
  /// whatever `Agent.writeFile` is handed in place of `source.readFile(path)`.
  ///
  /// Takeable once: it is one stream over one subscription, and a second
  /// consumer would silently get whichever chunks the first left.
  Stream<List<int>> get bytes {
    assert(!_taken, 'A prefetch feeds one write');
    assert(!_released, 'This prefetch was discarded');
    _taken = true;
    // Stamped here rather than at the first chunk the writer pulls: what the
    // figure is for is whether the read was *already done* when the write
    // wanted it, and handover is that instant.
    if (_sourceDone && _error == null) _owner._completeOnHandover++;
    return _out.stream;
  }

  /// Gives the slot back for a prefetch no writer will ever take — the apply
  /// stopped before this one's turn came. Cancels the source read, which for a
  /// remote source is what returns its window slot.
  void discard() => _finish();

  void _onChunk(List<int> chunk) {
    _chunks.add(chunk);
    _held += chunk.length;
    _owner._buffered(chunk.length);
    if (_held >= _owner.streamBytes && !_sourcePaused) {
      _sourcePaused = true;
      _source.pause();
    }
    _handOver();
  }

  void _onError(Object error, StackTrace stack) {
    // Kept rather than delivered straight away: chunks already buffered are
    // bytes the write is entitled to see first, and the failure then arrives in
    // its place in the stream exactly as an unbuffered read would have
    // delivered it.
    _error = error;
    _stack = stack;
    _sourceDone = true;
    _handOver();
  }

  void _onDone() {
    _sourceDone = true;
    _handOver();
  }

  /// Moves whatever is buffered on to the writer, as far as the writer is
  /// willing to take it, and lets the source continue by as much as that freed.
  ///
  /// Called from every edge that can change either side: a chunk arriving, the
  /// read ending, the writer subscribing, and the writer resuming.
  void _handOver() {
    if (_released || !_listening) return;
    while (!_writerPaused && _chunks.isNotEmpty) {
      final chunk = _chunks.removeFirst();
      _held -= chunk.length;
      _owner._drained(chunk.length);
      _out.add(chunk);
    }
    if (_sourcePaused && !_sourceDone && _held < _owner.streamBytes) {
      _sourcePaused = false;
      _source.resume();
    }
    if (_chunks.isEmpty && _sourceDone) {
      if (_error case final error?) _out.addError(error, _stack);
      _finish();
    }
  }

  void _finish() {
    if (_released) return;
    _released = true;
    unawaited(_source.cancel());
    _owner._drained(_held);
    _held = 0;
    _chunks.clear();
    // Closed rather than left open, so a writer still listening sees the end of
    // the stream: this is reached both by the read finishing normally and by
    // the slot being reclaimed under a writer that already failed.
    if (!_writerGone && !_out.isClosed) unawaited(_out.close());
    _owner._release(_reservation);
  }
}
