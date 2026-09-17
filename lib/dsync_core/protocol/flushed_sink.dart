import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Writes whole frames to an [IOSink], one `add`-and-`flush` at a time
/// (SPEC §4.2).
///
/// Every `Channel` over a real `dart:io` sink — a socket, an ssh process's
/// stdin, this process's own stdout — writes a frame as `add` then an awaited
/// `flush`, so that each frame leaves on its own rather than sitting in a
/// buffer behind the next one. Two of those overlapping is not slow, it is a
/// [StateError]: `IOSink.flush` binds the sink for the duration, and a second
/// `flush` while the first is outstanding fails with "StreamSink is bound to
/// a stream".
///
/// That became reachable with task 0f7dfc, which has several operations
/// outstanding on one connection and so several senders on one sink. The
/// chain here is what makes `Channel.send` safe to call again before the
/// previous call has returned — which the interface now requires of every
/// implementation — and it costs nothing: the writes it serializes are the
/// ones that were serial anyway when only one operation could be in flight.
///
/// Frames keep the order they were handed over in, which the protocol does
/// not itself require — a reply is matched by its id, not its position — but
/// which makes a capture of the wire readable and a test's expectations
/// deterministic.
class FlushedSink {
  final IOSink _sink;

  /// Completes when the write in progress is finished with the sink.
  Future<void> _writing = Future<void>.value();

  FlushedSink(this._sink);

  /// Writes [bytes] and returns once they have been flushed.
  Future<void> send(Uint8List bytes) {
    final written = _writing.then((_) async {
      _sink.add(bytes);
      await _sink.flush();
    });
    // Chained on a future that ignores the outcome, so one failed write does
    // not fail every write after it — the caller of *this* send still gets
    // the error, and a transport that is really gone reports itself through
    // the reader as well.
    _writing = written.then((_) {}, onError: (_) {});
    return written;
  }
}
