import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/scan_result_codec.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';

/// The remote end of the framed protocol (SPEC §4.2): performs the version
/// handshake, then the required `hello` prologue, then reads control-frame
/// requests off a [Channel] and dispatches each to the [Agent] `hello` built
/// — in practice always a `LocalAgent`, so what a `RemoteAgent` on the other
/// end drives really is this replica's filesystem.
class AgentServer {
  /// Serves a replica over [channel] until the channel's input closes.
  ///
  /// After the version handshake, the very next frame must be a `hello`
  /// request carrying a [ReplicaSpec] (SPEC §4.2); [buildAgent] turns that
  /// into the [Agent] the rest of the session dispatches to. `hello` is a
  /// callback rather than an interface — nothing here has a second
  /// implementation, the same reason `RunController`'s `Presenter` typedef is
  /// a callback rather than an interface — and requiring it as a prologue
  /// means the dispatch loop never holds a nullable or `late` [Agent]: by
  /// the time it starts, one already exists.
  ///
  /// A first frame that is not `hello` ends the session with an
  /// [AgentFailure] reply rather than dispatching against no agent at all.
  Future<void> serve(
    Channel channel,
    Agent Function(ReplicaSpec spec) buildAgent,
  ) async {
    final frames = StreamIterator(FrameCodec().decode(channel.input));
    // Cancelled on every way out of the `try` below — the ordinary end of
    // the dispatch loop, the early return for a non-`hello` first frame, and
    // a `performVersionHandshake` throw alike — because a `StreamIterator`
    // that is never cancelled leaves its subscription on `channel.input`
    // alive after `serve` returns. That is silent for an in-memory or SSH
    // channel, but on a channel over a process's own stdio it is the
    // subscription that keeps that process's event loop non-empty: the
    // caller may need the process to actually exit once `serve` is done with
    // it, and it can't while something is still listening for more input.

    // Holds the session's agent once `hello` has built one, so the `finally`
    // can release this replica's lock (SPEC §4.3) whatever ends the session.
    // Nothing else would: only an `unlock` op releases it, and under
    // `--listen` or `--serve` the process outlives the session, so a client
    // that dies between `lock` and `unlock` would leave the replica locked
    // for the life of the agent.
    Agent? sessionAgent;
    try {
      await performVersionHandshake(channel, frames);

      final helloFrame = await nextMeaningfulFrame(frames);
      if (helloFrame == null) {
        throw StateError('Channel closed before hello arrived');
      }
      final request = AgentRequest.fromFrame(helloFrame);
      if (request.op != 'hello') {
        await _reply(
          channel,
          AgentFailure(
            'Expected "hello" as the first operation, got '
            '"${request.op}"',
          ),
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
        await _reply(channel, AgentFailure('$error'));
        return;
      }
      sessionAgent = agent;
      final info = await agent.hello();
      await _reply(channel, AgentSuccess(replicaInfoToJson(info)));

      // Through [nextMeaningfulFrame] rather than `frames.moveNext()`
      // directly: a heartbeat tick is not an operation — it carries no `op`
      // to decode, and answering one with `AgentFailure('unknown op')` would
      // put a reply the peer never asked for where its next real answer
      // belongs (SPEC §4.2).
      for (
        var frame = await nextMeaningfulFrame(frames);
        frame != null;
        frame = await nextMeaningfulFrame(frames)
      ) {
        await _dispatch(channel, frames, agent, frame);
      }
    } finally {
      await frames.cancel();
      // Tolerant by construction: `unlock` on a lock this session never took,
      // or already released, is the ordinary case — `--stdio` and every
      // well-behaved client release explicitly — and `ReplicaLock.release` is
      // a no-op for both.
      await sessionAgent?.unlock();
    }
  }

  /// Handles one request frame, reporting any failure back to the peer.
  ///
  /// Decoding happens inside the `try` deliberately: a frame that is not a
  /// valid request is a failed operation, not a reason to drop the
  /// connection. Parsing it in the serve loop instead would let one
  /// unexpected frame throw past this handler and tear down the session.
  Future<void> _dispatch(
    Channel channel,
    StreamIterator<Frame> frames,
    Agent agent,
    Frame frame,
  ) async {
    try {
      final request = AgentRequest.fromFrame(frame);
      switch (request.op) {
        case 'lock':
          await agent.lock();
          await _reply(channel, const AgentSuccess());
        case 'unlock':
          await agent.unlock();
          await _reply(channel, const AgentSuccess());
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
                payload: encodeScanResult(result),
              ),
            ),
          );
        case 'readFile':
          await sendByteStream(
            channel,
            agent.readFile(request.params['path'] as String),
          );
        case 'writeFile':
          await _writeFile(channel, frames, agent, request);
        case 'delete':
          await agent.delete(request.params['path'] as String);
          await _reply(channel, const AgentSuccess());
        case 'removeEmptyDirs':
          await agent.removeEmptyDirs(request.params['path'] as String);
          await _reply(channel, const AgentSuccess());
        case 'archiveCommitUpsert':
          await agent.archiveCommitUpsert(
            archiveEntryFromJson(
              request.params['entry'] as Map<String, dynamic>,
            ),
          );
          await _reply(channel, const AgentSuccess());
        case 'archiveCommitDelete':
          await agent.archiveCommitDelete(request.params['path'] as String);
          await _reply(channel, const AgentSuccess());
        case 'compact':
          await agent.compact();
          await _reply(channel, const AgentSuccess());
        default:
          throw FormatException('Unknown agent operation: ${request.op}');
      }
    } catch (error) {
      await _reply(channel, AgentFailure('$error'));
    }
  }

  /// Writes the incoming byte stream, consuming every frame the peer sent
  /// even when the write fails.
  ///
  /// The peer has already committed to sending the whole file plus its
  /// terminator by the time the write is attempted, so a write that fails
  /// early — a permission error creating the parent directory, say — would
  /// otherwise leave those frames queued. The serve loop would then read file
  /// bytes where it expects the next request. That path is reachable in
  /// ordinary operation: SPEC §7.6 keeps the run going after a failed action.
  Future<void> _writeFile(
    Channel channel,
    StreamIterator<Frame> frames,
    Agent agent,
    AgentRequest request,
  ) async {
    final bytes = StreamIterator(readByteStream(frames));
    try {
      final metadata = await agent.writeFile(
        request.params['path'] as String,
        _remaining(bytes),
        mtime: request.params['mtime'] as int,
        mode: request.params['mode'] as int,
      );
      await _drain(bytes);
      await _reply(
        channel,
        AgentSuccess({'metadata': fileMetadataToJson(metadata)}),
      );
    } catch (_) {
      await _drain(bytes);
      rethrow;
    }
  }

  Stream<List<int>> _remaining(StreamIterator<List<int>> bytes) async* {
    while (await bytes.moveNext()) {
      yield bytes.current;
    }
  }

  /// Consumes what is left of a transfer the write did not finish reading.
  /// An error here means the peer ended it some other way, which leaves the
  /// frame stream equally well positioned for the next request.
  Future<void> _drain(StreamIterator<List<int>> bytes) async {
    try {
      while (await bytes.moveNext()) {}
    } catch (_) {}
  }

  Future<void> _reply(Channel channel, AgentResult result) =>
      channel.send(FrameCodec().encode(result.toFrame()));
}
