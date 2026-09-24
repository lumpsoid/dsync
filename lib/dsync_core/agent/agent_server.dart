import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/write_stage_tally.dart';
import 'package:dsync/dsync_core/models/far_side_report.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/loop_lag_stats.dart';
import 'package:dsync/dsync_core/models/read_cadence_stats.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/write_path_stats.dart';
import 'package:dsync/dsync_core/models/write_stage.dart';
import 'package:dsync/dsync_core/models/write_stage_stats.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/frame_router.dart';
import 'package:dsync/dsync_core/protocol/scan_result_codec.dart';
import 'package:dsync/dsync_core/scan/scan_session.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:dsync/dsync_core/run/elapsed.dart';
import 'package:dsync/dsync_core/run/loop_lag_sampler.dart';
import 'package:dsync/dsync_core/run/loop_lag_tally.dart';
import 'package:dsync/dsync_core/run/read_cadence_tally.dart';

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
  /// [writePath] is where this session's per-step `writeFile` totals are
  /// read from when the run ends (SPEC §17), supplied by whoever built the
  /// agent because that is the only thing here that knows the agent is a
  /// `LocalAgent` with steps to report — it is handed the session's agent so
  /// it stays a pure function of it rather than captured state a listener
  /// serving two sessions would mix up. Null for a caller that is not
  /// measuring, and read once — on the `unlock` reply — rather than on every
  /// reply, which would put seven integers on 14,000 frames to say a thing
  /// that is only true at the end.
  Future<void> serve(
    Channel channel,
    Agent Function(ReplicaSpec spec) buildAgent, {
    WritePathStats? Function(Agent agent)? writePath,
  }) async {
    // One clock for the session, stamped on every frame as it is decoded, so
    // a write's stages (SPEC §17) can say how long its frames sat in the
    // router's queue as well as how long its handler held them.
    final clock = stopwatchElapsed();
    final router = FrameRouter(channel.input, elapsed: clock);
    final stages = WriteStageTally();

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
    // This isolate's event-loop lag and this connection's read cadence, when
    // the initiator's `hello` asked for them (SPEC §17, task 7080d6). Stopped
    // in the `finally` as well as on `unlock`, so a session that ends any
    // other way leaves no timer behind.
    _ServedTimings? timings;
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
      if (request.params[helloLoopLagParam] == true) {
        timings = _ServedTimings(clock, router);
      }
      final info = await agent.hello();
      await _reply(
        channel,
        AgentSuccess(replicaInfoToJson(info)),
        helloFrame.requestId,
        helloSpan,
        // The prologue runs alone by construction (SPEC §4.2), so this is not
        // a sample of anything — it is the one in-flight figure this end can
        // state rather than measure.
        () => 1,
      );

      // The scan this session is holding, once one has happened (SPEC §6.1).
      // Connection-scoped, like the agent itself: phases 2 and 3 ask about
      // the unchanged entries phase 1 deliberately did not send, so they are
      // only answerable by the session that scanned. A second `scan` replaces
      // it — a run scans once, and a client that scans twice means the first
      // one is over.
      final scan = _HeldScan();

      onRequest = (frame, body) {
        final handled = _dispatch(
          channel,
          router,
          agent,
          scan,
          frame,
          body,
          // Read at reply time rather than captured now: what makes a peer's
          // span residency rather than service time is what was running
          // *alongside* it, and that is only known once it is over. By then
          // this dispatch is itself in the set, so the count includes it.
          () => inFlight.length,
          writePath,
          stages,
          clock,
          timings,
        );
        inFlight.add(handled);
        unawaited(handled.whenComplete(() => inFlight.remove(handled)));
      };

      await reading;
    } finally {
      timings?.stop();
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
    _HeldScan scan,
    Frame frame,
    Stream<Frame> body,
    int Function() inFlight,
    WritePathStats? Function(Agent agent)? writePath,
    WriteStageTally stages,
    Elapsed clock,
    _ServedTimings? timings,
  ) async {
    final id = frame.requestId;
    // Started before the request is even decoded, because what this measures
    // is everything the initiator's exchange is waiting on at this end (SPEC
    // §17). Handed to [_reply], which stamps it onto the success frame.
    //
    // Wall time on this side, so on a busy agent it includes whatever else
    // this isolate's event loop was doing — the same sense in which the
    // initiator's own per-operation mean is wall time. That makes it
    // *residency*, not service time, which is why the reply carries the
    // in-flight count beside it (SPEC §17): without that, a span that rose
    // because this end got busier and one that rose because its disk got
    // slower are the same number, and they have opposite fixes.
    final farSide = Stopwatch()..start();
    var bodyComplete = true;
    try {
      try {
        final request = AgentRequest.fromFrame(frame);
        switch (request.op) {
          case 'lock':
            await agent.lock();
            await _reply(channel, const AgentSuccess(), id, farSide, inFlight);
          case 'createRoot':
            await agent.createRoot();
            await _reply(channel, const AgentSuccess(), id, farSide, inFlight);
          case 'unlock':
            await agent.unlock();
            final served = timings?.stop();
            // The one reply that carries this side's write-path totals: the
            // last exchange of a run (SPEC §4.3), so the totals are complete
            // and nothing before it has paid for seven integers it could not
            // have filled in yet.
            await _reply(
              channel,
              const AgentSuccess(),
              id,
              farSide,
              inFlight,
              null,
              writePath?.call(agent),
              // Absent rather than empty for a session that wrote nothing —
              // a push, where this end only reads.
              switch (stages.stats(inputBlocked: router.inputBlocked)) {
                final stats when stats.files > 0 => stats,
                _ => null,
              },
              served?.loopLag,
              served?.reads,
            );
          case 'scan':
            final session = await agent.scan(
              ruleSetFromJson(request.params['rules'] as Map<String, dynamic>),
            );
            scan.session = session;
            // The replies that are not control frames (SPEC §15.3). A failure
            // still is: the `catch` below answers with an `AgentFailure`, which
            // is what lets `RemoteAgent.scan` tell the two apart by frame type
            // without the encoding having to carry an ok/error flag of its own.
            await _sendScanPayload(
              channel,
              id,
              encodeChangedScan(session.changed),
            );
          case scanDigestsOp:
            final digests = await scan.held.digests(
              bucketCount: request.params['bucketCount'] as int,
              peerChangedPaths: [
                for (final path in request.params['peerChangedPaths'] as List)
                  path as String,
              ],
            );
            await _sendScanPayload(channel, id, encodeBucketDigests(digests));
          case scanBucketsOp:
            final entries = await scan.held.entriesIn([
              for (final bucket in request.params['buckets'] as List)
                bucket as int,
            ]);
            await _sendScanPayload(channel, id, encodeScanEntries(entries));
          case 'readFile':
            await sendByteStream(
              channel,
              agent.readFile(request.params['path'] as String),
              requestId: id,
            );
          case 'writeFile':
            bodyComplete = false;
            // The lag and reads this session reports are the apply's:
            // sampling starts with the first write rather than at `hello`, so
            // a scan's quieter loop does not dilute them.
            timings?.start();
            // Ended in the `finally` rather than after the reply, so a write
            // that fails still leaves its stage and the live counts stay
            // true for the writes after it.
            final track = stages.begin(arrived: frame.arrivedAt, at: clock());
            try {
              // The only operation with an inbound stream, and the only one
              // whose span means two opposite things until it is split (SPEC
              // §17): the bytes arrive at the link's pace, so a handler
              // starved by the radio and one busy with its disk are the same
              // number. Measured where the frames are consumed rather than
              // subtracted from anything afterwards.
              final intake = _InboundWait(farSide, track, clock);
              final bytes = readByteStream(intake.watch(body));
              final metadata = await agent.writeFile(
                request.params['path'] as String,
                bytes,
                mtime: request.params['mtime'] as int,
                mode: request.params['mode'] as int,
              );
              bodyComplete = true;
              track.enter(WriteStage.replying, clock());
              await _reply(
                channel,
                AgentSuccess({'metadata': fileMetadataToJson(metadata)}),
                id,
                farSide,
                inFlight,
                intake.total,
              );
            } finally {
              track.end(clock());
            }
          case 'delete':
            await agent.delete(request.params['path'] as String);
            await _reply(channel, const AgentSuccess(), id, farSide, inFlight);
          case 'removeEmptyDirs':
            await agent.removeEmptyDirs(request.params['path'] as String);
            await _reply(channel, const AgentSuccess(), id, farSide, inFlight);
          case 'archiveCommit':
            await agent.archiveCommit([
              for (final commit in request.params['commits'] as List)
                archiveCommitFromJson(commit as Map<String, dynamic>),
            ]);
            await _reply(channel, const AgentSuccess(), id, farSide, inFlight);
          case 'compact':
            await agent.compact();
            await _reply(channel, const AgentSuccess(), id, farSide, inFlight);
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
  /// given and the operation succeeded — with what this side says the
  /// exchange cost it (SPEC §17).
  ///
  /// **Success only, and only where the reply is a control frame.** A failure
  /// carries an error the initiator turns into an exception, so there is no
  /// figure to record it against; a `scan` reply is binary (SPEC §15.3) and a
  /// `readFile` reply is the byte stream itself, so neither has a field to
  /// put this in. All three read as absent on the other end, which is the
  /// honest answer and is not the same as zero.
  ///
  /// **What the span cannot contain, stated because someone will subtract
  /// it.** It stops here, one line before the reply is handed to the channel,
  /// so the wait that reply serves behind this side's other senders falls
  /// outside it — and lands in whatever the initiator calls "the link". A
  /// frame cannot carry the cost of its own flush. What it can carry is this
  /// side's *cumulative* flush wait up to now ([FarSideReport.sendWait]),
  /// which is the figure that says whether an apparent link latency is
  /// really this end's send queue.
  /// One phase of a scan, as the binary frame SPEC §15.3 gives it.
  ///
  /// All three phases go out under `FrameType.scanResult`; the request id is
  /// what says which one, exactly as it does for every other operation. A
  /// frame type per phase would need `FrameCodec` to learn two more numbers
  /// to distinguish payloads the id already distinguishes.
  Future<void> _sendScanPayload(
    Channel channel,
    int requestId,
    List<int> payload,
  ) => channel.send(
    FrameCodec().encode(
      Frame(type: FrameType.scanResult, requestId: requestId, payload: payload),
    ),
  );

  Future<void> _reply(
    Channel channel,
    AgentResult result,
    int requestId, [
    Stopwatch? farSide,
    int Function()? inFlight,
    Duration? inboundWait,
    WritePathStats? writePath,
    WriteStageStats? writeStages,
    LoopLagStats? loopLag,
    ReadCadenceStats? reads,
  ]) {
    final stamped = farSide != null && result is AgentSuccess
        ? result.withFarSide(
            FarSideReport(
              span: farSide.elapsed,
              inFlight: inFlight?.call(),
              sendWait: channel.writeStats?.sendPath,
              inboundWait: inboundWait,
              writePath: writePath,
              writeStages: writeStages,
              loopLag: loopLag,
              reads: reads,
            ),
          )
        : result;
    return channel.send(FrameCodec().encode(stamped.toFrame(requestId)));
  }
}

/// How long a handler spent waiting for the frames of its own request, on
/// the clock its span is measured with (SPEC §17).
///
/// **On the frames rather than on the bytes they spell**, so the empty frame
/// that ends the transfer is waited for like any other — it is the last gap
/// of the stream and `readByteStream` consumes it without yielding anything
/// a byte-level wrapper could see.
///
/// The accounting is the generator's own suspension: the clock is read when
/// this yields a frame onward and again when the next one arrives, so
/// everything the handler does with a frame in hand — the write, the fsync —
/// falls outside, and only time with nothing to work on is counted.
class _InboundWait {
  final Stopwatch _clock;

  /// Where this write's stages are moved as its frames are taken, on the
  /// session's [_session] clock — the one its frames' arrivals are stamped
  /// with.
  final WriteStageTrack _track;
  final Elapsed _session;

  /// Summed gaps so far. Read when the reply is built, which is after the
  /// last of them.
  Duration total = Duration.zero;

  _InboundWait(this._clock, this._track, this._session);

  Stream<Frame> watch(Stream<Frame> source) async* {
    // Stamped when the handler subscribes, not when the request landed:
    // whatever this side did before asking for the first frame — opening the
    // temporary file (SPEC §7.2) — is its own work, not a wait.
    var since = _clock.elapsed;
    await for (final frame in source) {
      total += _clock.elapsed - since;
      final taken = _session();
      _track
        ..took(arrived: frame.arrivedAt, at: taken)
        ..enter(WriteStage.receiving, taken);
      // The terminator is the last frame of the transfer: from here every
      // byte is in hand and what is left is storage's own.
      if (frame.payload.isEmpty) _track.enter(WriteStage.storing, taken);
      yield frame;
      since = _clock.elapsed;
    }
  }
}

/// The one [ScanSession] a connection is holding, and the failure for a peer
/// that asks about a scan that never happened.
///
/// A holder rather than a nullable local, because the session is set by one
/// dispatch and read by later ones: `_dispatch` is called once per request
/// and cannot own a value the next call has to see. Named so the error
/// message can be, too — an out-of-order phase is a protocol bug and reads
/// as one, not as a null dereference in a stack trace.
class _HeldScan {
  ScanSession? session;

  ScanSession get held {
    final session = this.session;
    if (session == null) {
      throw StateError(
        'A later scan phase arrived before the scan itself (SPEC §6.1)',
      );
    }
    return session;
  }
}

/// The serving isolate's event-loop lag and the connection's read cadence
/// for one session (SPEC §17, task 7080d6): both taken from the first served
/// write until `unlock`, on the session's clock so their window reads
/// against the write stages'.
///
/// The isolate sampled is the one running [AgentServer.serve] — the one
/// reading the connection, and, because `LocalAgent.writeFile` runs its
/// `dart:io` calls from the same isolate, the one their completions queue
/// on. On the phone that is the app's main isolate.
///
/// The reads are counted at the router's listener, which is also where each
/// frame's arrival is stamped: a request's far clock starts in the same
/// synchronous callback that decoded it, so the only wait before it that
/// Dart can see is the `queued` write stage. What these add is how the bytes
/// got to that listener — steadily or in bursts.
class _ServedTimings {
  final Elapsed _clock;
  final FrameRouter _router;
  final LoopLagTally _tally = LoopLagTally();
  final ReadCadenceTally _reads = ReadCadenceTally();
  late final LoopLagSampler _sampler = LoopLagSampler(
    period: LoopLagSampler.defaultPeriod,
    onLag: _tally.add,
  );
  Duration? _startedAt;
  Duration? _stoppedAt;

  _ServedTimings(this._clock, this._router);

  /// Starts sampling at the first call; later calls, and calls after
  /// [stop], change nothing.
  void start() {
    if (_startedAt != null || _stoppedAt != null) return;
    _startedAt = _clock();
    _sampler.start();
    _router.readCadence = _reads;
  }

  /// Stops sampling and says what was seen, or null if no write ever
  /// started it — a push, where this end only reads.
  ({LoopLagStats loopLag, ReadCadenceStats reads})? stop() {
    _sampler.stop();
    _router.readCadence = null;
    final started = _startedAt;
    final stopped = _stoppedAt ??= _clock();
    if (started == null) return null;
    final window = stopped - started;
    return (
      loopLag: _tally.stats(window: window),
      reads: _reads.stats(window: window),
    );
  }
}
