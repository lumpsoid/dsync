import 'dart:async';

/// The write half of a byte stream: hand bytes over, wait for them to be out
/// (SPEC §4.2).
///
/// What [FlushedSink] actually needs of the thing it writes to, and nothing
/// else. `IOSink` would do for a `Socket` or a process's stdin, but a
/// `RawSecureSocket` is not one and cannot be made into one — see
/// [ByteSocket] — so the sink it writes through is named here rather than
/// borrowed from `dart:io`. Two real implementations ship against it
/// (`IoByteSocket`, `RawSecureByteSocket`), which is what earns it its place.
abstract interface class ByteSink {
  /// Queues [bytes] for the other end. Does not block and does not report
  /// failure; [flush] is where a write error surfaces.
  void add(List<int> bytes);

  /// Completes once everything handed to [add] has left this process.
  Future<void> flush();
}
