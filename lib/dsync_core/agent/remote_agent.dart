import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';

/// [Agent] implementation that drives a replica over a [Channel] by
/// exchanging framed control messages and file bytes with the agent server
/// handler on the other end (SPEC §4.2).
///
/// Requests are not pipelined: each method sends its request, then reads
/// from the same decoded-frame stream until that operation's result arrives,
/// before the next call may start — matching the single in-flight request
/// the agent server handler expects.
class RemoteAgent implements Agent {
  final Channel _channel;
  final StreamIterator<Frame> _frames;

  RemoteAgent(Channel channel)
    : _channel = channel,
      _frames = StreamIterator(FrameCodec().decode(channel.input));

  @override
  Future<void> hello() => performVersionHandshake(_channel, _frames);

  @override
  Future<void> lock() => _call('lock');

  @override
  Future<void> unlock() => _call('unlock');

  @override
  Future<List<ScanEntry>> scan() async {
    final result = await _call('scan');
    return (result['entries'] as List)
        .map((e) => scanEntryFromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Stream<List<int>> readFile(String path) async* {
    await _send(AgentRequest('readFile', {'path': path}));
    yield* readByteStream(_frames);
  }

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) async {
    await _send(
      AgentRequest('writeFile', {'path': path, 'mtime': mtime, 'mode': mode}),
    );
    await sendByteStream(_channel, data);
    final result = await _awaitResult();
    return fileMetadataFromJson(result['metadata'] as Map<String, dynamic>);
  }

  @override
  Future<void> delete(String path) => _call('delete', {'path': path});

  @override
  Future<void> removeEmptyDirs(String path) =>
      _call('removeEmptyDirs', {'path': path});

  @override
  Future<void> archiveCommitUpsert(ArchiveEntry entry) =>
      _call('archiveCommitUpsert', {'entry': archiveEntryToJson(entry)});

  @override
  Future<void> archiveCommitDelete(String path) =>
      _call('archiveCommitDelete', {'path': path});

  @override
  Future<void> compact() => _call('compact');

  Future<Map<String, dynamic>> _call(
    String op, [
    Map<String, dynamic> params = const {},
  ]) async {
    await _send(AgentRequest(op, params));
    return _awaitResult();
  }

  Future<void> _send(AgentRequest request) =>
      _channel.send(FrameCodec().encode(request.toFrame()));

  Future<Map<String, dynamic>> _awaitResult() async {
    if (!await _frames.moveNext()) {
      throw StateError('Channel closed before a response arrived');
    }
    return switch (AgentResult.fromFrame(_frames.current)) {
      AgentSuccess(:final data) => data,
      AgentFailure(:final error) => throw AgentOperationException(error),
    };
  }
}
