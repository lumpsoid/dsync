import 'dart:async';

import 'package:dsync/dsync_core/protocol/channel.dart';

/// A [Channel] pair backed by in-memory buffers instead of a process or
/// socket (SPEC §14).
///
/// Lets a `LocalAgent` be driven through the same `RemoteAgent`/`AgentServer`
/// code path as SSH, without a network — the testing seam for protocol
/// round-trip tests.
class InMemoryChannel implements Channel {
  final StreamController<List<int>> _outbox;
  @override
  final Stream<List<int>> input;

  InMemoryChannel._(this._outbox, this.input);

  /// Creates two ends of the same in-memory connection: bytes [Channel.send]
  /// on one arrive on the other's [Channel.input], and vice versa.
  static (Channel, Channel) pair() {
    final aToB = StreamController<List<int>>();
    final bToA = StreamController<List<int>>();
    final a = InMemoryChannel._(aToB, bToA.stream);
    final b = InMemoryChannel._(bToA, aToB.stream);
    return (a, b);
  }

  @override
  Future<void> send(List<int> bytes) async {
    _outbox.add(bytes);
  }

  @override
  Future<void> close() async {
    await _outbox.close();
  }
}
