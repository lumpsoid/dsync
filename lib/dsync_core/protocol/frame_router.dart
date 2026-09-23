import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/run/elapsed.dart';

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
/// **Backpressure is the route's.** Each route is a single-subscription
/// stream, and the subscription under this router is paused while a route's
/// consumer is. That head-of-line-blocks the whole connection behind one slow
/// consumer, which is deliberate: the alternative is per-route buffering with
/// no bound, and the memory-constrained end of this protocol is a phone
/// streaming files (SPEC §7.2). A blocked route cannot deadlock the
/// connection, because no route's consumer waits on a later frame of this
/// same connection — a `readFile` is consumed by a `writeFile` on the *other*
/// replica's channel, and a reply is consumed by a completer.
///
/// [FrameType.heartbeat] never reaches a route: it belongs to no request
/// (SPEC §4.2) and is dropped here, which is the one place that now has to
/// know about it instead of every positional reader.
class FrameRouter {
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

  /// Frames decoded but not yet routed, because the consumer the one before
  /// them belongs to is paused.
  final Queue<Frame> _undelivered = Queue<Frame>();

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

  /// Whether [_deliver] is already working through [_undelivered].
  bool _delivering = false;

  /// Whether the input ended while frames were still being delivered.
  bool _inputDone = false;

  /// Whether the input subscription is paused *by this router*. Tracked
  /// rather than read back off the subscription, because `pause` counts: two
  /// pauses need two resumes, and delivery pauses once per pass while it
  /// resumes only on the pass that empties the queue.
  bool _paused = false;

  /// When the input was left paused behind a route not taking frames, on
  /// [_clock], or null while it is not — or while nothing is measuring.
  Duration? _blockedSince;

  /// Summed time the input has stayed paused past a delivery pass because a
  /// route was not taking frames (SPEC §17, task 9a89f7), or zero from a
  /// router with no clock.
  ///
  /// **The one queue no stamp on a frame can see.** While this runs nothing
  /// is read off the transport, so what the peer sent waits undecoded in the
  /// socket and TLS buffers, and its [Frame.arrivedAt] is the moment it was
  /// finally read rather than the moment it arrived. A connection whose
  /// writes are serialised by this head-of-line block reads here as most of
  /// the run.
  Duration get inputBlocked => switch ((_blockedSince, _clock)) {
    (final since?, final clock?) => _blocked + (clock() - since),
    _ => _blocked,
  };
  Duration _blocked = Duration.zero;

  FrameRouter(Stream<Uint8List> input, {Elapsed? elapsed})
    : _input = input,
      _clock = elapsed;

  /// Opens a route for [requestId]. Every frame arriving under that id is
  /// delivered on the returned stream until [close] is called for it.
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
    final route = _Route(_deliver);
    _routes[requestId] = route;
    return route.controller.stream;
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
  void close(int requestId, {bool discardRemaining = false}) {
    // Recorded before the route is abandoned, not after: abandoning wakes
    // delivery, and a frame for this id already waiting on the paused
    // consumer would otherwise be routed in that pass — with no route left
    // to take it, so it would be offered as a brand new request.
    if (discardRemaining && !_closed) _discarded.add(requestId);
    _routes.remove(requestId)?.abandon();
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
      onDone: () {
        _inputDone = true;
        if (!_delivering && _undelivered.isEmpty) _finish(null);
      },
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
      // subscription is *paused* while a route's consumer is behind, so a
      // chunk that waited for the head of the line to clear is stamped when
      // it was finally read, and that wait lands in the span rather than
      // disappearing out of it.
      frames = _decoder.add(chunk, arrivedAt: _clock?.call());
    } catch (error, stackTrace) {
      _finish(error, stackTrace);
      return;
    }
    _undelivered.addAll(frames);
    _deliver();
  }

  /// Routes what has been decoded, with the input paused while it does.
  ///
  /// Called again by a route whose consumer resumed, which is how delivery
  /// picks up from the frame it stopped at.
  void _deliver() {
    if (_delivering) return;
    _delivering = true;
    // Paused for the whole drain rather than per frame: the point is that
    // nothing more is read off the transport while a consumer is behind.
    _pauseInput();
    try {
      while (_undelivered.isNotEmpty && !_closed) {
        final frame = _undelivered.first;
        if (frame.type == FrameType.heartbeat) {
          _undelivered.removeFirst();
          continue;
        }

        if (_discarded.contains(frame.requestId)) {
          // The terminator of an abandoned transfer, or the failure frame
          // that replaced it (`sendByteStream`), is the last frame under
          // this id — after it, nothing more is owed and the id is forgotten.
          if (frame.type == FrameType.control || frame.payload.isEmpty) {
            _discarded.remove(frame.requestId);
          }
          _undelivered.removeFirst();
          continue;
        }

        final route = _routes[frame.requestId];
        if (route == null) {
          _undelivered.removeFirst();
          _onUnrouted(frame, open(frame.requestId));
          continue;
        }
        // Left at the front of the queue, not dropped: this route's consumer
        // is behind, and delivery resumes here when it catches up.
        if (!route.canAcceptNow) break;
        _undelivered.removeFirst();
        route.add(frame);
      }
    } catch (error, stackTrace) {
      _delivering = false;
      _finish(error, stackTrace);
      return;
    }
    _delivering = false;

    if (_closed) return;
    if (_inputDone && _undelivered.isEmpty) {
      _finish(null);
      return;
    }
    if (_undelivered.isEmpty) {
      _resumeInput();
    } else {
      // Read only when a pass ends blocked, so the ordinary pass that
      // pauses and resumes in one go costs no clock read at all.
      _blockedSince ??= _clock?.call();
    }
  }

  void _pauseInput() {
    if (_paused) return;
    _paused = true;
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

/// One outstanding exchange's frames, and the pause state the router reads
/// backpressure from.
class _Route {
  final StreamController<Frame> controller = StreamController<Frame>();

  /// Told when this route can take a frame again, so the router can carry on
  /// from the one it stopped at.
  final void Function() _wake;

  /// Set by [abandon] and [finish]: frames still arriving are dropped rather
  /// than offered to a stream nobody is listening to.
  bool _abandoned = false;

  _Route(this._wake) {
    // `isPaused` is also true before anything has listened at all, which is
    // the state a server-side route starts in — the router opens it, then
    // the handler listens a few microtasks later. So `onListen` is a wake-up
    // as much as `onResume` is.
    controller.onListen = _wake;
    controller.onResume = _wake;
    controller.onCancel = _wake;
  }

  /// Whether a frame can be handed over now, rather than buffered past what
  /// the consumer is asking for.
  bool get canAcceptNow => _abandoned || !controller.isPaused;

  void add(Frame frame) {
    if (_abandoned) return;
    controller.add(frame);
  }

  void abandon() {
    if (_abandoned) return;
    _abandoned = true;
    controller.close();
    _wake();
  }

  void finish(Object? error, StackTrace? stackTrace) {
    if (_abandoned) return;
    _abandoned = true;
    // Added whether or not anything is listening yet, and the controller
    // buffers it until something is: the handshake route is opened before
    // the connection is read at all, so the failure that ends a connection
    // *during* the handshake — a rejected TLS certificate, say — has no
    // listener at the moment it arrives, and dropping it would leave the
    // caller with "the channel closed" in place of the reason.
    if (error != null) controller.addError(error, stackTrace);
    controller.close();
  }
}
