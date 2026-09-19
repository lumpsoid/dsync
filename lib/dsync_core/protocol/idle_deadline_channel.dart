import 'dart:async';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';

/// A [Channel] decorator that bounds how long a peer may say nothing (SPEC
/// §4.2, §4.4): it sends [FrameType.heartbeat] ticks while it has nothing of
/// its own to send, and fails the connection when nothing — not even a tick
/// — arrives while something here is waiting to read.
///
/// **Why the protocol needs this at all.** `peer://` is the only transport
/// whose read loop this project owns on both ends with nobody else watching.
/// A `unix://` peer is a process on this machine, so a dead one has its
/// socket closed by the kernel and the reader gets EOF; `ssh://` runs through
/// the system `ssh`, a second party that watches the connection itself and is
/// configured out of band (`ServerAliveInterval`) by whoever runs it. Between
/// two dsync processes on a raw TCP socket there is neither: a laptop that
/// sleeps, a wifi association that drops or a NAT box that expires the flow
/// all leave a half-open connection, where `StreamIterator.moveNext()` waits
/// forever and a run produces no exit code, no summary and no output. The OS
/// default TCP keepalive is two hours.
///
/// **A decorator, not a change to `SocketChannel`.** The mechanism is "this
/// stream went quiet", which has nothing to do with sockets, and wrapping is
/// what lets a test drive it from an `InMemoryChannel` with a short deadline
/// instead of a real network partition. `SO_KEEPALIVE`/`TCP_KEEPIDLE` through
/// `Socket.setRawOption` was the alternative and was not taken: it puts
/// platform-specific integer constants inside `dsync_core`, is untestable
/// without partitioning a real network, and only ever detects a peer that is
/// *dead* — not one that is alive and wedged. Everything it would catch, the
/// deadline catches, in portable and testable code.
///
/// **Why a heartbeat, and not just a deadline.** A `scan` of a large cold
/// tree sends nothing at all between the request and its single
/// [FrameType.scanResult] reply, so a bare deadline would have to exceed the
/// worst-case scan — a constant nobody can defend, and one that kills
/// legitimate runs when guessed low. With a tick flowing from whichever side
/// is busy, silence unambiguously means broken and the bound can be seconds.
/// Both ends run this, not just the one serving: during an interactive
/// conflict prompt (SPEC §11.3) the client is legitimately silent for as long
/// as the user takes to answer, and without its ticks a server-side deadline
/// could not tell a thinking user from a dead client.
///
/// **The deadline is armed only while something is actually reading.** The
/// subscription this holds on the wrapped channel is paused by whatever
/// consumes [input] — a `StreamIterator` pauses between `moveNext()` calls,
/// which is exactly the window where the run is doing local work rather than
/// waiting on the peer — and while it is paused the peer's bytes sit in the
/// kernel where this could not see them anyway. Counting silence then would
/// reap a healthy peer for this side's own busyness. Pausing the deadline
/// with the subscription is what makes "arm while a request is outstanding"
/// fall out of the plumbing rather than needing the decorator to be told
/// which requests are in flight.
///
/// Heartbeats, by contrast, are unconditional: the send timer is re-armed by
/// every [send], so a tick goes out whenever this side has sent nothing for
/// [heartbeatInterval], whether or not it owes the peer a reply. That costs
/// one empty frame every few seconds on an idle connection and removes the
/// need for either end to model what the other is waiting for.
class IdleDeadlineChannel implements Channel {
  /// How long the peer may be silent while this side is waiting to read
  /// before the connection is failed.
  ///
  /// Six times [defaultHeartbeatInterval]: five consecutive ticks can be lost
  /// — to a stalled sender, a scheduling hiccup, a moment of packet loss —
  /// before a peer that is in fact alive is reaped, while a peer that is
  /// really gone is still noticed inside half a minute rather than at the
  /// OS's two-hour keepalive.
  static const defaultDeadline = Duration(seconds: 30);

  /// How long this side may go without sending anything before it sends a
  /// tick. Short enough that the deadline above can be a comfortable multiple
  /// of it, long enough that an idle connection costs a handful of 5-byte
  /// frames a minute.
  static const defaultHeartbeatInterval = Duration(seconds: 5);

  static final Uint8List _heartbeatBytes = FrameCodec().encode(
    const Frame(type: FrameType.heartbeat, payload: []),
  );

  final Channel _inner;

  /// How the peer is named to a human — a paired device's local name (SPEC
  /// §4.4), which is what [PeerWentSilentException] has to say back.
  final String peer;

  final Duration deadline;
  final Duration heartbeatInterval;

  late final StreamController<Uint8List> _incoming;
  StreamSubscription<Uint8List>? _upstream;
  Timer? _idle;
  Timer? _heartbeat;
  bool _closed = false;

  IdleDeadlineChannel(
    this._inner, {
    required this.peer,
    this.deadline = defaultDeadline,
    this.heartbeatInterval = defaultHeartbeatInterval,
  }) {
    _incoming = StreamController<Uint8List>(
      onListen: _onListen,
      onPause: _onPause,
      onResume: _onResume,
      onCancel: _onCancel,
    );
    _armHeartbeat();
  }

  /// The wrapped channel's bytes, with the peer's silence turned into a
  /// [PeerWentSilentException] on the stream rather than a wait that never
  /// ends. Single-subscription, like every [Channel.input].
  @override
  Stream<Uint8List> get input => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) {
    _armHeartbeat();
    return _inner.send(bytes);
  }

  /// The wrapped channel's, unchanged: heartbeats go through [send] like any
  /// other frame and coalesce with them, so there is nothing to add here.
  @override
  int? get writes => _inner.writes;

  @override
  Future<void> close() async {
    _closed = true;
    _idle?.cancel();
    _heartbeat?.cancel();
    await _inner.close();
  }

  void _onListen() {
    _upstream = _inner.input.listen(
      (chunk) {
        _armIdle();
        _incoming.add(chunk);
      },
      onError: _incoming.addError,
      onDone: () {
        _idle?.cancel();
        _heartbeat?.cancel();
        _incoming.close();
      },
    );
    _armIdle();
  }

  void _onPause() {
    _idle?.cancel();
    _idle = null;
    _upstream?.pause();
  }

  void _onResume() {
    _upstream?.resume();
    _armIdle();
  }

  Future<void> _onCancel() async {
    _idle?.cancel();
    _heartbeat?.cancel();
    await _upstream?.cancel();
  }

  void _armIdle() {
    if (_closed) return;
    _idle?.cancel();
    _idle = Timer(deadline, _reapSilentPeer);
  }

  void _armHeartbeat() {
    if (_closed) return;
    _heartbeat?.cancel();
    _heartbeat = Timer(heartbeatInterval, _sendHeartbeat);
  }

  void _sendHeartbeat() {
    if (_closed) return;
    // Errors are dropped rather than surfaced: a write that fails here says
    // the connection is already gone, which the deadline below is about to
    // report on the read side with the peer's name attached. Reporting it
    // twice, once as a bare `SocketException` from a timer with no operation
    // to attribute it to, would only obscure that.
    unawaited(send(_heartbeatBytes).catchError((Object _) {}));
  }

  /// Ends the connection the way a caller can act on: the error goes onto
  /// [input], so whoever is blocked in `moveNext()` throws it in place of the
  /// reply it was waiting for, instead of seeing the bare "channel closed"
  /// that closing the socket alone would produce.
  void _reapSilentPeer() {
    _idle = null;
    _heartbeat?.cancel();
    if (_incoming.isClosed) return;
    _incoming.addError(
      PeerWentSilentException(peer, deadline),
      StackTrace.current,
    );
    unawaited(_incoming.close());
    unawaited(close().catchError((Object _) {}));
  }
}

/// Thrown onto [IdleDeadlineChannel.input] when a peer stopped sending — not
/// even a [FrameType.heartbeat] — for [deadline] while this side was waiting
/// to read (SPEC §4.2). Fatal for the run (SPEC §11.5 exit 3).
///
/// Distinct in wording from the two other `peer://` failures (SPEC §4.4),
/// because all three point at different fixes: "no pairing for X" means this
/// host never had a certificate for that name, "could not reach X at its last
/// known address" means the dial itself never connected, and this one means
/// the connection was made, authenticated, and used — and then the far end
/// stopped answering mid-session.
class PeerWentSilentException implements Exception {
  /// The paired device's local name (SPEC §4.4).
  final String peer;

  final Duration deadline;

  const PeerWentSilentException(this.peer, this.deadline);

  @override
  String toString() =>
      '"$peer" stopped answering: nothing arrived from it for '
      '${deadline.inSeconds}s, not even a heartbeat, while dsync was waiting '
      'on it. The pairing and the address are fine — they got this far — so '
      'this is the device or the network to it going away mid-session: a '
      'laptop asleep, a wifi drop, a NAT mapping that expired. Run the sync '
      'again once it is back.';
}
