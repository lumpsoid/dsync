import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
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
  /// means this method never holds a nullable or `late` [Agent]: by the time
  /// the dispatch loop starts, one already exists.
  ///
  /// A first frame that is not `hello` ends the session with an
  /// [AgentFailure] reply rather than dispatching against no agent at all.
  Future<void> serve(
    Channel channel,
    Agent Function(ReplicaSpec spec) buildAgent,
  ) async {
    final frames = StreamIterator(FrameCodec().decode(channel.input));
    await performVersionHandshake(channel, frames);

    if (!await frames.moveNext()) {
      throw StateError('Channel closed before hello arrived');
    }
    final request = AgentRequest.fromFrame(frames.current);
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
    final agent = buildAgent(spec);
    final info = await agent.hello();
    await _reply(channel, AgentSuccess(replicaInfoToJson(info)));

    while (await frames.moveNext()) {
      await _dispatch(channel, frames, agent, frames.current);
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
          await _reply(channel, AgentSuccess(scanResultToJson(result)));
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
