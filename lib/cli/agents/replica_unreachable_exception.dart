/// Thrown when a replica's location cannot be turned into a connected agent
/// (SPEC §4.1, §4.2) — most commonly a failed ssh connection — fatal for the
/// caller (SPEC §11.5 exit 3: "cannot reach a replica").
///
/// Names [side] (`'a'` or `'b'`) and carries whatever explains the failure:
/// the underlying [cause] — a process that never started, a version
/// handshake that never got a reply — and, when the ssh session got far
/// enough to say something, its own [stderr] output. The stderr is the
/// actual reason ("Permission denied (publickey)", "Host key verification
/// failed") that an opaque "channel closed" error would otherwise swallow —
/// the single most common way a sync tool wastes someone's afternoon.
///
/// Both are printed, rather than the stderr standing in for the cause. Not
/// every cause is opaque: `PeerNotSpeakingProtocolException` quotes the bytes
/// the remote shell sent, and that is the whole diagnosis. Dropping it
/// whenever stderr happened to hold a line — "Warning: Permanently added
/// '...' to the list of known hosts" arrives on a first connection and
/// explains nothing — would throw away the better of the two.
class ReplicaUnreachableException implements Exception {
  final String side;
  final Object cause;
  final List<String> stderr;

  const ReplicaUnreachableException({
    required this.side,
    required this.cause,
    this.stderr = const [],
  });

  @override
  String toString() {
    final buffer = StringBuffer('Cannot reach replica $side: $cause');
    if (stderr.isNotEmpty) buffer.write('\nssh said: ${stderr.join(' | ')}');
    return buffer.toString();
  }
}
