import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/frame_router.dart';
import 'package:dsync/dsync_core/protocol/scan_result_codec.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';

/// The remote end of the framed protocol (SPEC §4.2): performs the version
/// handshake, then the required `hello` prologue, then routes control-frame
/// requests off a [Channel] and dispatches each to the [Agent] `hello` built
/// — in practice always a `LocalAgent`, so what a `RemoteAgent` on the other
/// end drives really is this replica's filesystem.
///
/// **Requests may interleave** (task 0f7dfc). Each carries an id, and this
/// end answers each under the id it came in on, so a reply is not owed in
/// arrival order and a `writeFile`'s `fileBytes` frames can have another
/// operation's request sitting between them. Dispatch is therefore a router
/// plus one handler per request rather than a serial read-dispatch-reply
/// loop.
///
/// **No window here.** The initiator bounds how many operations are
/// outstanding and decides which may overlap (`RequestWindow`), and it
/// cannot send an operation it has declared a barrier until every earlier
/// reply is in hand. A second bound on this end would be a second answer to
/// a question already answered, and a smaller one would deadlock a peer
/// waiting on replies this side is refusing to start.
class AgentServer {
  /// Serves a replica over [channel] until the channel's input closes.
  ///
  /// After the version handshake, the very next frame must be a `hello`
  /// request carrying a [ReplicaSpec] (SPEC §4.2); [buildAgent] turns that
  /// into the [Agent] the rest of the session dispatches to. `hello` is a
  /// callback rather than an interface — nothing here has a second
  /// implementation, the same reason `RunController`'s `Presenter` typedef is
  /// a callback rather than an interface — and requiring it as a prologue
  /// means dispatch never holds a nullable or `late` [Agent]: by the time it
  /// starts, one already exists.
  ///
  /// A first frame that is not `hello` ends the session with an
  /// [AgentFailure] reply rather than dispatching against no agent at all.
  Future<void> serve(
    Channel channel,
    Agent Function(ReplicaSpec spec) buildAgent,
  ) async {
    final router = FrameRouter(channel.input);

    final firstRequest = Completer<Frame>();

    // What an arriving request is answered with, swapped once `hello` has
    // built the session's agent. A mutable hook rather than two routers,
    // because the prologue and the session read the same frames off the same
    // connection and only differ in what they are allowed to be.
    //
    // A second request during the prologue fails the session rather than
    // being queued or dropped: SPEC §4.2 makes `hello` a prologue, and a
    // peer that sends past it without waiting for the reply is one whose
    // later frames this end cannot safely guess the meaning of.
    void Function(Frame request, Stream<Frame> body) onRequest = (frame, _) {
      if (firstRequest.isCompleted) {
        throw StateError(
          'A request arrived before the "hello" prologue was answered',
        );
      }
      firstRequest.complete(frame);
    };

    // Every dispatch still running, so the session does not tear its agent
    // down underneath one. Entries remove themselves, so this holds what is
    // in flight rather than everything the session ever did.
    final inFlight = <Future<void>>{};

    // Cancelled on every way out of the `try` below, because a router that
    // is never cancelled leaves its subscription on `channel.input` alive
    // after `serve` returns. That is silent for an in-memory or SSH channel,
    // but on a channel over a process's own stdio it is the subscription
    // that keeps that process's event loop non-empty: the caller may need
    // the process to actually exit once `serve` is done with it, and it
    // can't while something is still listening for more input.
    // Opened before the router starts reading: the peer sends its version
    // frame as soon as it dials, so a route opened after would be opened
    // after the frame it is for had already arrived as unrouted.
    final handshake = router.open(Frame.noRequest);

    final reading = router.run(
      onUnrouted: (frame, body) {
        onRequest(frame, body);
      },
    );
    // The failure this can carry — undecodable bytes — also reaches every
    // open route, which is where a handler sees it. Suppressed here so it is
    // not an unhandled error while the prologue below is still waiting, and
    // rethrown by the `await reading` that ends the session.
    unawaited(reading.catchError((_) {}));

    // The same read loop, read as "the channel closed" rather than as a
    // frame, so the prologue below can wait for whichever comes first.
    final closed = reading.then<Frame?>((_) => null);
    unawaited(closed.catchError((_) => null));

    // Holds the session's agent once `hello` has built one, so the `finally`
    // can release this replica's lock (SPEC §4.3) whatever ends the session.
    // Nothing else would: only an `unlock` op releases it, and under
    // `--listen` or `--serve` the process outlives the session, so a client
    // that dies between `lock` and `unlock` would leave the replica locked
    // for the life of the agent.
    Agent? sessionAgent;
    try {
      // Both version frames carry [Frame.noRequest] — the handshake precedes
      // every request, so there is no request for them to belong to.
      try {
        await performVersionHandshake(channel, handshake);
      } finally {
        router.close(Frame.noRequest);
      }

      final helloFrame = await Future.any([firstRequest.future, closed]);
      if (helloFrame == null) {
        throw StateError('Channel closed before hello arrived');
      }
      // The prologue is an exchange like any other and its span is reported
      // the same way (SPEC §17): on this end it covers building the agent
      // and the replica's own `hello`, which on a phone reads the archive.
      final helloSpan = Stopwatch()..start();
      final request = AgentRequest.fromFrame(helloFrame);
      if (request.op != 'hello') {
        await _reply(
          channel,
          AgentFailure(
            'Expected "hello" as the first operation, got '
            '"${request.op}"',
          ),
          helloFrame.requestId,
        );
        return;
      }

      final spec = replicaSpecFromJson(
        request.params['replica'] as Map<String, dynamic>,
      );
      // Unguarded until SPEC §4.4: `buildAgent` could not fail before a
      // paired network transport gave it something to reject. Now it can —
      // `AgentListener.bindSecure` hands this a connection-scoped `buildAgent`
      // that checks the caller's agreed replica roots before delegating to
      // the head's own — so a rejection is caught here and answered the same
      // way `_dispatch` answers every other failed operation, rather than
      // propagating past this method with no reply ever sent. This is the
      // one change task `d0e960` is allowed to make above `Channel`, and it
      // is deliberately only around `buildAgent`: a failing `hello` keeps
      // propagating exactly as it always has, because nothing asked for that
      // to change and widening the guard would quietly convert every
      // agent-construction failure into a reply instead of a failed session.
      final Agent agent;
      try {
        agent = buildAgent(spec);
      } catch (error) {
        await _reply(channel, AgentFailure('$error'), helloFrame.requestId);
        return;
      }
      sessionAgent = agent;
      final info = await agent.hello();
      await _reply(
        channel,
        AgentSuccess(replicaInfoToJson(info)),
        helloFrame.requestId,
        helloSpan,
      );

      onRequest = (frame, body) {
        final handled = _dispatch(channel, router, agent, frame, body);
        inFlight.add(handled);
        unawaited(handled.whenComplete(() => inFlight.remove(handled)));
      };

      await reading;
    } finally {
      await router.cancel();
      // Handlers first, then the lock: a dispatch still finishing is still
      // touching this replica, and releasing the lock out from under it
      // would let a second session in while it writes.
      if (inFlight.isNotEmpty) await Future.wait(inFlight.toList());
      // Tolerant by construction: `unlock` on a lock this session never took,
      // or already released, is the ordinary case — `--stdio` and every
      // well-behaved client release explicitly — and `ReplicaLock.release` is
      // a no-op for both.
      await sessionAgent?.unlock();
    }
  }

  /// Handles one request, reporting any failure back to the peer under the
  /// request's own id.
  ///
  /// Decoding happens inside the `try` deliberately: a frame that is not a
  /// valid request is a failed operation, not a reason to drop the
  /// connection. Parsing it in the routing callback instead would let one
  /// unexpected frame throw past this handler and tear down the session.
  ///
  /// A failure here is this operation's alone. Other requests are in flight
  /// under their own ids and are neither cancelled nor failed by it — which
  /// is what lets SPEC §7.6's "record it and carry on" mean the same thing
  /// with a window open as it did one request at a time.
  Future<void> _dispatch(
    Channel channel,
    FrameRouter router,
    Agent agent,
    Frame frame,
    Stream<Frame> body,
  ) async {
    final id = frame.requestId;
    // Started before the request is even decoded, because what this measures
    // is everything the initiator's exchange is waiting on at this end (SPEC
    // §17). Handed to [_reply], which stamps it onto the success frame.
    //
    // Wall time on this side, so on a busy agent it includes whatever else
    // this isolate's event loop was doing — the same sense in which the
    // initiator's own per-operation mean is wall time.
    final farSide = Stopwatch()..start();
    var bodyComplete = true;
    try {
      try {
        final request = AgentRequest.fromFrame(frame);
        switch (request.op) {
          case 'lock':
            await agent.lock();
            await _reply(channel, const AgentSuccess(), id, farSide);
          case 'unlock':
            await agent.unlock();
            await _reply(channel, const AgentSuccess(), id, farSide);
          case 'scan':
            final result = await agent.scan(
              ruleSetFromJson(request.params['rules'] as Map<String, dynamic>),
            );
            // The one reply that is not a control frame (SPEC §15.3). A failure
            // still is: the `catch` below answers with an `AgentFailure`, which
            // is what lets `RemoteAgent.scan` tell the two apart by frame type
            // without the encoding having to carry an ok/error flag of its own.
            await channel.send(
              FrameCodec().encode(
                Frame(
                  type: FrameType.scanResult,
                  requestId: id,
                  payload: encodeScanResult(result),
                ),
              ),
            );
          case 'readFile':
            await sendByteStream(
              channel,
              agent.readFile(request.params['path'] as String),
              requestId: id,
            );
          case 'writeFile':
            bodyComplete = false;
            final bytes = readByteStream(body);
            final metadata = await agent.writeFile(
              request.params['path'] as String,
              bytes,
              mtime: request.params['mtime'] as int,
              mode: request.params['mode'] as int,
            );
            bodyComplete = true;
            await _reply(
              channel,
              AgentSuccess({'metadata': fileMetadataToJson(metadata)}),
              id,
              farSide,
            );
          case 'delete':
            await agent.delete(request.params['path'] as String);
            await _reply(channel, const AgentSuccess(), id, farSide);
          case 'removeEmptyDirs':
            await agent.removeEmptyDirs(request.params['path'] as String);
            await _reply(channel, const AgentSuccess(), id, farSide);
          case 'archiveCommit':
            await agent.archiveCommit([
              for (final commit in request.params['commits'] as List)
                archiveCommitFromJson(commit as Map<String, dynamic>),
            ]);
            await _reply(channel, const AgentSuccess(), id, farSide);
          case 'compact':
            await agent.compact();
            await _reply(channel, const AgentSuccess(), id, farSide);
          default:
            throw FormatException('Unknown agent operation: ${request.op}');
        }
      } catch (error) {
        await _reply(channel, AgentFailure('$error'), id);
      }
    } catch (_) {
      // Sending the reply failed, so the channel is gone. There is nothing
      // left to report it to, and the router is about to end the session for
      // the same reason — while the other handlers in flight still have to
      // be allowed to unwind.
    } finally {
      // A write that failed before reading the whole transfer — a permission
      // error creating the parent directory, say, which SPEC §7.6 makes an
      // ordinary outcome — leaves the peer still sending. Those frames route
      // nowhere rather than having to be drained: without the id they would
      // have been read as the next request.
      router.close(id, discardRemaining: !bodyComplete);
    }
  }

  /// Sends [result] as the reply to [requestId], stamped — when [farSide] is
  /// given and the operation succeeded — with how long this side took (SPEC
  /// §17).
  ///
  /// **Success only, and only where the reply is a control frame.** A failure
  /// carries an error the initiator turns into an exception, so there is no
  /// figure to record it against; a `scan` reply is binary (SPEC §15.3) and a
  /// `readFile` reply is the byte stream itself, so neither has a field to
  /// put this in. All three read as absent on the other end, which is the
  /// honest answer and is not the same as zero.
  Future<void> _reply(
    Channel channel,
    AgentResult result,
    int requestId, [
    Stopwatch? farSide,
  ]) {
    final stamped = farSide != null && result is AgentSuccess
        ? result.withFarSide(farSide.elapsed)
        : result;
    return channel.send(FrameCodec().encode(stamped.toFrame(requestId)));
  }
}
