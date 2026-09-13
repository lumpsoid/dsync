/// A bidirectional byte stream to one replica's agent, transport-agnostic
/// (SPEC §4.2).
///
/// `RemoteAgent` and the agent server handler exchange framed protocol bytes
/// over this interface without knowing whether the other end is reached via
/// the system `ssh` binary, an in-memory pair (for tests), or — later — a
/// Dart SSH client or a socket (SPEC §16). Interface only — see the SSH and
/// in-memory `Channel` tasks for implementations.
abstract class Channel {
  /// Bytes arriving from the other end, in the order sent.
  ///
  /// A chunk boundary carries no meaning — it need not align with a frame
  /// boundary. Single-subscription: exactly one listener for the lifetime of
  /// the channel, matching a process's stdout.
  Stream<List<int>> get input;

  /// Sends [bytes] to the other end.
  Future<void> send(List<int> bytes);

  /// Closes both directions of the stream.
  Future<void> close();
}
