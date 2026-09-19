import 'dart:async';
import 'dart:typed_data';

import 'package:dsync/dsync_core/protocol/channel.dart';

/// A [Channel] pair backed by in-memory buffers instead of a process or
/// socket (SPEC §14).
///
/// Lets a `LocalAgent` be driven through the same `RemoteAgent`/`AgentServer`
/// code path as SSH, without a network — the testing seam for protocol
/// round-trip tests.
class InMemoryChannel implements Channel {
  final StreamController<Uint8List> _outbox;
  @override
  final Stream<Uint8List> input;

  InMemoryChannel._(this._outbox, this.input);

  /// Creates two ends of the same in-memory connection: bytes [Channel.send]
  /// on one arrive on the other's [Channel.input], and vice versa.
  static (Channel, Channel) pair() {
    final aToB = StreamController<Uint8List>();
    final bToA = StreamController<Uint8List>();
    final a = InMemoryChannel._(aToB, bToA.stream);
    final b = InMemoryChannel._(bToA, aToB.stream);
    return (a, b);
  }

  @override
  Future<void> send(Uint8List bytes) async {
    _outbox.add(bytes);
  }

  /// Null: there is no sink and no flush, so a write is not a thing this pair
  /// has — and reporting 0 would read as "it coalesced nothing" (`Channel`).
  @override
  int? get writes => null;

  @override
  Future<void> close() async {
    await _outbox.close();
  }
}
