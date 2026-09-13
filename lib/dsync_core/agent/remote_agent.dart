import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';

/// [Agent] implementation that drives a replica over a [Channel] by
/// exchanging framed control messages and file bytes with the agent server
/// handler on the other end (SPEC §4.2).
///
/// Requests are not pipelined: responses are matched to requests positionally
/// over one shared frame stream, so exactly one operation may be in flight —
/// matching the single in-flight request the agent server handler expects.
/// That is enforced here rather than left to callers, because the window is
/// not always visible from the outside: an abandoned `readFile` keeps reading
/// frames after its consumer has stopped listening (see [readFile]), while
/// SPEC §7.6 has the run starting its next action immediately.
class RemoteAgent implements Agent {
  final Channel _channel;
  final StreamIterator<Frame> _frames;

  /// Completes when the operation currently holding the wire is finished with
  /// it. Each operation chains onto the last, so they queue instead of
  /// interleaving.
  Future<void> _wire = Future<void>.value();

  RemoteAgent(Channel channel)
    : _channel = channel,
      _frames = StreamIterator(FrameCodec().decode(channel.input));

  /// Waits for the wire, then hands back the callback that releases it.
  /// Callers must release in a `finally`, or every later operation hangs.
  Future<void Function()> _acquireWire() async {
    final previous = _wire;
    final done = Completer<void>();
    _wire = done.future;
    await previous;
    return done.complete;
  }

  @override
  Future<void> hello() async {
    final release = await _acquireWire();
    try {
      await performVersionHandshake(_channel, _frames);
    } finally {
      release();
    }
  }

  @override
  Future<void> lock() => _call('lock');

  @override
  Future<void> unlock() => _call('unlock');

  @override
  Future<ScanResult> scan(RuleSet rules) async {
    return scanResultFromJson(
      await _call('scan', {'rules': ruleSetToJson(rules)}),
    );
  }

  /// Streams the file, and guarantees the shared frame stream is left
  /// positioned at the next operation's response even if the consumer stops
  /// early.
  ///
  /// Stopping early is the normal case, not an exotic one: `Applier` pipes
  /// this straight into the destination's `writeFile`, and SPEC §7.6 requires
  /// the run to carry on to the next action after that write fails. Without
  /// the drain, the peer's remaining `fileBytes` frames stay queued and the
  /// next operation decodes raw file bytes as its own control reply — one
  /// failed path silently breaks every later action against this replica.
  ///
  /// Draining does pull the rest of the file over the wire for nothing. The
  /// alternative is tagging requests so a reply can be matched instead of
  /// positionally, which is a protocol change; this keeps a failed copy
  /// costing bandwidth rather than correctness.
  @override
  Stream<List<int>> readFile(String path) async* {
    final release = await _acquireWire();
    try {
      await _send(AgentRequest('readFile', {'path': path}));
      // Held as an iterator rather than consumed with `await for` so the drain
      // below can continue this same transfer. A second readByteStream over
      // `_frames` would have two `moveNext` calls in flight at once.
      final bytes = StreamIterator(readByteStream(_frames));
      var midStream = true;
      try {
        while (await bytes.moveNext()) {
          yield bytes.current;
        }
        midStream = false;
      } catch (_) {
        // The peer replaced the terminator with a failure frame, which
        // readByteStream has already consumed — the wire is past the transfer.
        midStream = false;
        rethrow;
      } finally {
        if (midStream) {
          try {
            while (await bytes.moveNext()) {}
          } catch (_) {
            // However the transfer ended, the frame stream is now past it.
          }
        }
      }
    } finally {
      release();
    }
  }

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) async {
    final release = await _acquireWire();
    try {
      await _send(
        AgentRequest('writeFile', {'path': path, 'mtime': mtime, 'mode': mode}),
      );
      await sendByteStream(_channel, data);
      final result = await _awaitResult();
      return fileMetadataFromJson(result['metadata'] as Map<String, dynamic>);
    } finally {
      release();
    }
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
    final release = await _acquireWire();
    try {
      await _send(AgentRequest(op, params));
      return await _awaitResult();
    } finally {
      release();
    }
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
