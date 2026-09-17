import 'dart:typed_data';

/// A bidirectional byte stream to one replica's agent, transport-agnostic
/// (SPEC §4.2).
///
/// `RemoteAgent` and the agent server handler exchange framed protocol bytes
/// over this interface without knowing whether the other end is reached via
/// the system `ssh` binary, a socket, or an in-memory pair (for tests).
/// Interface only — see `SshChannel`, `SocketChannel`, `StdioChannel` and
/// `InMemoryChannel` for the implementations.
///
/// Typed `Uint8List` rather than `List<int>` because that is what every real
/// transport already hands back — a `Socket` *is* a `Stream<Uint8List>`, and
/// `Process.stdout` emits them — and because `FrameCodec` copies each arriving
/// chunk into its buffer with `setRange`, which is a `memmove` for a
/// `Uint8List` source and an element-at-a-time loop for a boxed growable
/// `List<int>`. Saying so in the type means no caller can quietly land on the
/// slow one.
abstract class Channel {
  /// Bytes arriving from the other end, in the order sent.
  ///
  /// A chunk boundary carries no meaning — it need not align with a frame
  /// boundary. Single-subscription: exactly one listener for the lifetime of
  /// the channel, matching a process's stdout.
  Stream<Uint8List> get input;

  /// Sends [bytes] to the other end.
  ///
  /// Safe to call again before a previous call has returned. Several
  /// operations are outstanding on one connection (SPEC §4.2, task 0f7dfc),
  /// so several of them are sending; an implementation over a `dart:io` sink
  /// gets this from `FlushedSink`, which is also where the failure that
  /// makes it a requirement rather than a nicety is written down. What an
  /// implementation must *not* do is interleave one call's bytes with
  /// another's: a caller hands over whole frames, and a frame split down the
  /// middle by someone else's is not decodable by anyone.
  Future<void> send(Uint8List bytes);

  /// Closes both directions of the stream.
  Future<void> close();
}
