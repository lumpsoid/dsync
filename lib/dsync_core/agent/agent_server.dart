import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';

/// The remote end of the framed protocol (SPEC §4.2): performs the version
/// handshake, then reads control-frame requests off a [Channel] and
/// dispatches each to the [Agent] it was started with — in practice always a
/// `LocalAgent`, so what a `RemoteAgent` on the other end drives really is
/// this replica's filesystem.
class AgentServer {
  /// Serves [agent] over [channel] until the channel's input closes.
  Future<void> serve(Channel channel, Agent agent) async {
    final frames = StreamIterator(FrameCodec().decode(channel.input));
    await performVersionHandshake(channel, frames);

    while (await frames.moveNext()) {
      await _dispatch(
        channel,
        frames,
        agent,
        AgentRequest.fromFrame(frames.current),
      );
    }
  }

  Future<void> _dispatch(
    Channel channel,
    StreamIterator<Frame> frames,
    Agent agent,
    AgentRequest request,
  ) async {
    try {
      switch (request.op) {
        case 'lock':
          await agent.lock();
          await _reply(channel, const AgentSuccess());
        case 'unlock':
          await agent.unlock();
          await _reply(channel, const AgentSuccess());
        case 'scan':
          final entries = await agent.scan();
          await _reply(
            channel,
            AgentSuccess({'entries': entries.map(scanEntryToJson).toList()}),
          );
        case 'readFile':
          await sendByteStream(
            channel,
            agent.readFile(request.params['path'] as String),
          );
        case 'writeFile':
          final metadata = await agent.writeFile(
            request.params['path'] as String,
            readByteStream(frames),
            mtime: request.params['mtime'] as int,
            mode: request.params['mode'] as int,
          );
          await _reply(
            channel,
            AgentSuccess({'metadata': fileMetadataToJson(metadata)}),
          );
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

  Future<void> _reply(Channel channel, AgentResult result) =>
      channel.send(FrameCodec().encode(result.toFrame()));
}
