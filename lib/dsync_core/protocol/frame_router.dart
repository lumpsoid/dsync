import 'dart:async';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/run/elapsed.dart';
import 'package:dsync/dsync_core/run/read_cadence_tally.dart';

/// Reads one connection's frames and hands each to the exchange its
/// [Frame.requestId] names (SPEC §4.2, task 0f7dfc).
///
/// This is what replaces reading the shared frame stream positionally. With
/// several operations outstanding, "the next frame" is no longer "the answer
/// to the request I just sent", so the one reader that owns the stream routes
/// instead: `RemoteAgent` opens a route before it sends a request, and
/// `AgentServer` gets a route opened for it as each new request arrives.
///
/// **It subscribes to the channel itself** rather than iterating
/// `FrameCodec.decode`'s stream, and holds a [FrameDecoder] instead. A
/// generator cannot be torn down while it is waiting — cancelling a
/// subscription to an `async*` takes effect at its next `yield`, and this
/// reader spends almost all of its life parked waiting for bytes that may
/// never come — so a router built on one could never finish cancelling, and
/// `RemoteAgent.disconnect` exists precisely to let the transport go.
///
/// **Every frame is routed the moment it is decoded; backpressure is a byte
/// budget across the connection** (task cff96b). A route whose consumer is
/// not taking frames — paused, or not listening yet — keeps them, in arrival
/// order, until it does, and the other routes and every new request carry on
/// past it. What that costs is counted: [held] is every frame routed and not
/// yet taken by its consumer, and the input is paused while it exceeds
/// [budgetBytes], so nothing more is read off the transport until the
/// consumers holding it take enough of it back.
///
/// It used to stop at the first frame whose route could not take it and
/// leave the whole input paused behind that one route. On the phone that was
/// most of a pull: a served `writeFile` takes its first byte frame only once
/// its file is open, a create on FUSE costs ~15–20 ms, and every other
/// request on the connection waited unread for it, so sixteen outstanding
/// writes ran ~1.4 at a time (task 9a89f7).
///
/// **The budget cannot be shared out per route**, and one route can hold all
/// of it. A reader's only lever is to stop reading, and it cannot know whose
/// frame is next until it has read it — so a per-route cap would mean pausing
/// the whole input on one route's account, which is the head-of-line block
/// this replaces. What bounds a route that fills the budget is its own
/// consumer: the pause lasts until that consumer takes frames — a served
/// `writeFile` body once its file is open, a reply once its completer's
/// caller runs, a `readFile` once the read-ahead's writer reaches its file
/// (SPEC §4.2 says what that last one can wait on). So the worst case is the
/// old one (the whole input waits for one consumer), and it is now reached
/// only once a megabyte is held rather than at the first frame.
///
/// [FrameType.heartbeat] never reaches a route: it belongs to no request
/// (SPEC §4.2) and is dropped here, which is the one place that now has to
/// know about it instead of every positional reader.
class FrameRouter {
  /// Bytes routed and not yet taken by their consumers above which the input
  /// is paused (SPEC §4.2).
  ///
  /// **A megabyte, the figure already on the books for the apply's buffers**
  /// (SPEC §7.2): one 64 KiB chunk for each of the sixteen writes §7.1 runs
  /// at once, so every write still opening its file can have its first chunk
  /// waiting without the input stopping — and a tree of files the measured
  /// 12.7 KiB mean fits whole, bodies and all, ~80 times over.
  static const budgetBytes = 1024 * 1024;

  final Stream<Uint8List> _input;
  final FrameDecoder _decoder = FrameDecoder();

  /// Where the arrival instant stamped on every decoded frame comes from
  /// (SPEC §17), or null for a reader that is not measuring.
  ///
  /// **It must be the same clock whoever reads [Frame.arrivedAt] measures
  /// against**, which is why it is injected rather than started here: the
  /// figure it exists for is `RemoteAgent`'s, the span from a reply's bytes
  /// arriving to that operation's future completing, and two stopwatches
  /// started a moment apart would turn that span into a difference of two
  /// origins.
  final Elapsed? _clock;

  final Map<int, _Route> _routes = {};

  /// Ids whose remaining frames route nowhere — see [close]. An id leaves
  /// this set at the frame that ends its exchange, so it holds one entry per
  /// *currently* abandoned transfer rather than one per request ever made.
  final Set<int> _discarded = {};

  /// Wire bytes of every frame routed and not yet taken by its consumer —
  /// what [budgetBytes] bounds.
  int _held = 0;

  StreamSubscription<Uint8List>? _subscription;

  /// Completes when the input has ended or failed — what [run] hands back.
  final Completer<void> _finished = Completer<void>();

  /// What an arriving frame with no open route is given to; set by [run].
  late final void Function(Frame, Stream<Frame>) _onUnrouted;

  /// Set once the input has ended or failed, and the reason if it failed.
  /// Every later [open] is answered with it rather than with a route whose
  /// frames can never arrive.
  Object? _closedBy;
  bool _closed = false;

  /// Whether the input subscription is paused *by this router*. Tracked
  /// rather than read back off the subscription, because `pause` counts: two
  /// pauses need two resumes.
  bool _paused = false;

  /// When the input was paused over [budgetBytes], on [_clock], or null
  /// while it is not — or while nothing is measuring.
  Duration? _blockedSince;

  /// Summed time the input has stayed paused because the frames held for
  /// routes not taking them exceeded [budgetBytes] (SPEC §17, tasks 9a89f7
  /// and cff96b), or zero from a router with no clock.
  ///
  /// **The one queue no stamp on a frame can see.** While this runs nothing
  /// is read off the transport, so what the peer sent waits undecoded in the
  /// socket and TLS buffers, and its [Frame.arrivedAt] is the moment it was
  /// finally read rather than the moment it arrived. The time a frame spent
  /// held *after* it was read is on the frame itself: its consumer sees
  /// [Frame.arrivedAt] and knows when it took it.
  Duration get inputBlocked => switch ((_blockedSince, _clock)) {
    (final since?, final clock?) => _blocked + (clock() - since),
    _ => _blocked,
  };
  Duration _blocked = Duration.zero;

  /// Where every read off the input is counted from now on, on [_clock]
  /// (SPEC §17, task 7080d6), or null while nothing asked. Settable because
  /// what asks — a served session's `hello` — is read off this same router,
  /// and the window it measures starts at the first served write. Ignored by
  /// a router with no clock.
  ReadCadenceTally? readCadence;

  FrameRouter(Stream<Uint8List> input, {Elapsed? elapsed})
    : _input = input,
      _clock = elapsed;

  /// Opens a route for [requestId]. Every frame arriving under that id is
  /// delivered on the returned stream until [close] is called for it.
  ///
  /// Frames that arrive before anything listens, or while the listener is
  /// paused, are kept for it in order and count against [budgetBytes].
  ///
  /// Throws [StateError] if a route for [requestId] is already open — that
  /// is an id reused while still in flight, which is a bug in whoever
  /// allocates them, not a wire condition.
  Stream<Frame> open(int requestId) {
    if (_closed) {
      return Stream<Frame>.error(
        _closedBy ?? StateError('Channel closed before a response arrived'),
      );
    }
    if (_routes.containsKey(requestId)) {
      throw StateError('A route for request $requestId is already open');
    }
    final route = _Route(_release);
    _routes[requestId] = route;
    return route.frames;
  }

  /// Closes the route for [requestId].
  ///
  /// [discardRemaining] says the exchange was abandoned part-way — the
  /// consumer of a `readFile` stopped early, which SPEC §7.6 makes the
  /// normal case — so frames are still coming under this id and must route
  /// nowhere until the one that ends the transfer. That is what the id
  /// bought: the abandoned transfer used to have to be *drained*, pulling
  /// the rest of the file over the wire, because the next operation's reply
  /// would otherwise have been decoded as file bytes.
  ///
  /// A route that has already been handed the frame that ends its transfer
  /// — a write that failed after its body had all arrived, but before it
  /// took it — is owed nothing more, so its id is not discarded: nothing
  /// would ever come to clear it.
  void close(int requestId, {bool discardRemaining = false}) {
    final route = _routes.remove(requestId);
    if (discardRemaining && !_closed && !(route?.ended ?? false)) {
      _discarded.add(requestId);
    }
    route?.abandon();
  }

  /// Reads until the input ends, routing every frame.
  ///
  /// [onUnrouted] is called for each frame whose id has no open route, with a
  /// route for that id opened *first* and its stream passed in — that
  /// ordering is what makes the server side safe: a `writeFile` request and
  /// the `fileBytes` frames behind it share an id, and if the route were
  /// opened by the handler after it was called, the frames arriving in
  /// between would each look like another new request.
  ///
  /// The callback must not await anything before it is given control back;
  /// it is expected to start a handler and return. Whatever it throws fails
  /// this future, which ends the session.
  Future<void> run({
    required void Function(Frame first, Stream<Frame> body) onUnrouted,
  }) {
    _onUnrouted = onUnrouted;
    _subscription = _input.listen(
      _onChunk,
      onError: _finish,
      // Every frame is already on its route by now, so the routes end here
      // and each consumer still gets what was kept for it before the end.
      onDone: () => _finish(null),
    );
    return _finished.future;
  }

  /// Stops reading and ends every open route.
  Future<void> cancel() async {
    _finish(null);
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  void _onChunk(Uint8List chunk) {
    if (_closed) return;
    final List<Frame> frames;
    try {
      // Read here, at the top of the listener, because this is as close to
      // "the bytes arrived" as anything on this side gets — and because the
      // subscription is *paused* while the budget is exceeded, so a chunk
      // that waited for it to drain is stamped when it was finally read, and
      // that wait lands in the span rather than disappearing out of it.
      final at = _clock?.call();
      if ((readCadence, at) case (final cadence?, final at?)) {
        cadence.add(at: at, bytes: chunk.length);
      }
      frames = _decoder.add(chunk, arrivedAt: at);
      for (final frame in frames) {
        if (_closed) return;
        _route(frame);
      }
    } catch (error, stackTrace) {
      _finish(error, stackTrace);
      return;
    }
    _settle();
  }

  /// Hands [frame] to its route, or to [_onUnrouted] as a new request.
  void _route(Frame frame) {
    if (frame.type == FrameType.heartbeat) return;

    if (_discarded.contains(frame.requestId)) {
      // The terminator of an abandoned transfer, or the failure frame that
      // replaced it (`sendByteStream`), is the last frame under this id —
      // after it, nothing more is owed and the id is forgotten.
      if (_endsTransfer(frame)) _discarded.remove(frame.requestId);
      return;
    }

    final route = _routes[frame.requestId];
    if (route == null) {
      _onUnrouted(frame, open(frame.requestId));
      return;
    }
    _held += route.add(frame);
  }

  /// [bytes] of held frames were taken by their consumer, or will never be.
  void _release(int bytes) {
    _held -= bytes;
    _settle();
  }

  /// Pauses the input while [_held] exceeds [budgetBytes], and resumes it
  /// once it no longer does.
  void _settle() {
    if (_closed) return;
    if (_held > budgetBytes) {
      _pauseInput();
    } else {
      _resumeInput();
    }
  }

  void _pauseInput() {
    if (_paused) return;
    _paused = true;
    _blockedSince = _clock?.call();
    _subscription?.pause();
  }

  void _resumeInput() {
    if (!_paused) return;
    _paused = false;
    if ((_blockedSince, _clock) case (final since?, final clock?)) {
      _blocked += clock() - since;
    }
    _blockedSince = null;
    _subscription?.resume();
  }

  /// Ends every open route, with [error] if the input failed.
  ///
  /// A route ended without an error is a route whose reply never came, which
  /// each caller reads its own meaning into — `RemoteAgent` turns it into
  /// "channel closed before a response arrived", `AgentServer` into the
  /// ordinary end of a session — so the stream simply closes rather than
  /// carrying a message this layer would have to invent.
  void _finish(Object? error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _closed = true;
    _closedBy = error;
    final routes = _routes.values.toList();
    _routes.clear();
    for (final route in routes) {
      route.finish(error, stackTrace);
    }
    if (error == null) {
      _finished.complete();
    } else {
      _finished.completeError(error, stackTrace ?? StackTrace.current);
    }
  }
}

/// Whether [frame] is the last one a byte transfer sends: its empty
/// terminator, or the failure control frame `sendByteStream` sends instead.
bool _endsTransfer(Frame frame) =>
    frame.type == FrameType.control || frame.payload.isEmpty;

/// One outstanding exchange's frames, kept in arrival order until its
/// consumer takes them, and the count of how many bytes that is.
///
/// **The controller is the queue.** It already keeps what is added before
/// anything listens, and while the listener is paused, in order; what it
/// cannot say is how much, so every frame is counted in as it is added and
/// counted out as the consumer takes it.
class _Route {
  final StreamController<Frame> _controller = StreamController<Frame>();

  /// Told how many held bytes left this route, taken or dropped.
  final void Function(int bytes) _release;

  /// What the consumer is handed: the controller's frames, counted out as
  /// each is delivered.
  late final Stream<Frame> frames = _controller.stream.map(_taken);

  /// Wire bytes added and not yet delivered.
  int _held = 0;

  /// Set by [abandon] and [finish]: frames still arriving are dropped rather
  /// than offered to a stream that has ended.
  bool _closed = false;

  /// Set once what the controller keeps will never be delivered — the
  /// consumer cancelled, or the route was abandoned with nobody listening —
  /// and its bytes have been released.
  bool _dropped = false;

  /// Whether this route has been handed the frame that ends a transfer.
  bool ended = false;

  _Route(this._release) {
    _controller.onCancel = _drop;
  }

  /// Adds [frame], returning the bytes now held for it.
  int add(Frame frame) {
    if (_endsTransfer(frame)) ended = true;
    if (_closed || _dropped) return 0;
    final bytes = FrameCodec.wireLength(frame);
    _held += bytes;
    _controller.add(frame);
    return bytes;
  }

  Frame _taken(Frame frame) {
    if (!_dropped) {
      final bytes = FrameCodec.wireLength(frame);
      _held -= bytes;
      _release(bytes);
    }
    return frame;
  }

  /// Releases everything held: a cancelled subscription's buffered events
  /// are discarded, and an abandoned route nobody listens to will not be.
  void _drop() {
    if (_dropped) return;
    _dropped = true;
    final held = _held;
    _held = 0;
    if (held > 0) _release(held);
  }

  void abandon() {
    if (_closed) return;
    _closed = true;
    _controller.close();
    // A listener still has what it was handed coming to it, and counts it
    // out as it takes it; with none, nothing ever will.
    if (!_controller.hasListener) _drop();
  }

  void finish(Object? error, StackTrace? stackTrace) {
    if (_closed) return;
    _closed = true;
    // Added whether or not anything is listening yet, and the controller
    // buffers it until something is: the handshake route is opened before
    // the connection is read at all, so the failure that ends a connection
    // *during* the handshake — a rejected TLS certificate, say — has no
    // listener at the moment it arrives, and dropping it would leave the
    // caller with "the channel closed" in place of the reason.
    if (error != null) _controller.addError(error, stackTrace);
    _controller.close();
  }
}
