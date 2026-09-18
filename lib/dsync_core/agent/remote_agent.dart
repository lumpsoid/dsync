import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/request_window.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/frame_router.dart';
import 'package:dsync/dsync_core/protocol/scan_result_codec.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';

/// [Agent] implementation that drives a replica over a [Channel] by
/// exchanging framed control messages and file bytes with the agent server
/// handler on the other end (SPEC §4.2).
///
/// **Requests are pipelined** (task 0f7dfc). Every frame carries the id of
/// the request it belongs to, so a reply is matched by that id rather than
/// by arrival order, and up to [RequestWindow.size] operations are
/// outstanding at once. What the window admits and what it serialises is
/// [RequestWindow]'s to say; this class only names which operation is which.
///
/// **Failure semantics with several operations in flight**, which is the
/// part a reader most needs stated:
/// - An operation that *fails* fails alone. Its reply is an `AgentFailure`
///   under its own id, so it completes that caller's future with an
///   [AgentOperationException] and touches nothing else. The others in the
///   window carry on and report their own outcomes, which is exactly what
///   SPEC §7.6 already asks of a run: record the failed path, keep going.
/// - A failure of the *connection* — the channel closing, or bytes that do
///   not decode — fails every outstanding operation with that error, and
///   every operation issued afterwards, because nothing can be matched to
///   anything any more. That is the one case where one failure is everyone's,
///   and it is fatal for the run (SPEC §11.5 exit 3) however many operations
///   it took down.
class RemoteAgent implements Agent {
  final Channel _channel;
  final ReplicaSpec _spec;
  final FrameRouter _router;
  final RequestWindow _window;

  /// The router's read loop. Held so [disconnect] can wait for it, and its
  /// failure is swallowed here rather than left unhandled: the error has
  /// already been delivered to every open route, which is where a caller
  /// sees it.
  late final Future<void> _reading;

  /// The peer's version frame, on the route for [Frame.noRequest].
  ///
  /// Opened here rather than in [hello], and before the router starts
  /// reading: the peer sends its version as soon as it is serving, so a
  /// route opened when `hello` is finally called would be opened after the
  /// frame it is for had already arrived and been discarded as unrouted.
  late final Stream<Frame> _handshakeReplies;

  /// The last id handed out. Starts at [Frame.noRequest], so the first
  /// request is 1 and no operation ever claims the id the version handshake
  /// and the heartbeats use.
  int _lastRequestId = Frame.noRequest;

  /// [spec] identifies the replica this agent drives on the other end of
  /// [channel] — sent as part of [hello], since nothing else tells the peer
  /// a root path, profile id, side, or job count (SPEC §4.2).
  ///
  /// [window] is injectable so a test can pin the bound it asserts against
  /// rather than restating [RequestWindow.defaultSize].
  RemoteAgent(Channel channel, ReplicaSpec spec, {RequestWindow? window})
    : _channel = channel,
      _spec = spec,
      _window = window ?? RequestWindow(),
      _router = FrameRouter(channel.input) {
    _handshakeReplies = _router.open(Frame.noRequest);
    _reading = _router.run(
      // A frame under an id nothing is waiting for is dropped, not fatal.
      // It is what an abandoned transfer's tail looks like once the route
      // has been closed and the id forgotten (SPEC §7.6 makes abandoning
      // one the normal case), and a reply to nothing is harmless where
      // tearing a run down over it is not.
      onUnrouted: (frame, _) => _router.close(frame.requestId),
    );
    unawaited(_reading.catchError((_) {}));
  }

  @override
  Future<ReplicaInfo> hello() => _window.runExclusive(AgentOp.hello, () async {
    // Both version frames carry [Frame.noRequest]: the handshake precedes
    // every request, so there is no request for them to belong to.
    try {
      await performVersionHandshake(_channel, _handshakeReplies);
    } finally {
      _router.close(Frame.noRequest);
    }
    return _exchange(
      AgentRequest(AgentOp.hello.name, {'replica': replicaSpecToJson(_spec)}),
      (id, replies) async => replicaInfoFromJson(await _awaitResult(replies)),
    );
  });

  @override
  Future<void> lock() =>
      _window.runExclusive(AgentOp.lock, () => _call(AgentOp.lock));

  @override
  Future<void> unlock() =>
      _window.runExclusive(AgentOp.unlock, () => _call(AgentOp.unlock));

  /// The one operation whose success does not come back as a control frame
  /// (SPEC §15.3): a `scan` reply is `FrameType.scanResult`, the binary
  /// encoding in `scan_result_codec.dart`. A *failure* is still an
  /// `AgentFailure` control frame, so the frame type is what tells the two
  /// apart — which is why this cannot go through [_call].
  @override
  Future<ScanResult> scan(RuleSet rules) => _window.runExclusive(
    AgentOp.scan,
    () => _exchange(
      AgentRequest(AgentOp.scan.name, {'rules': ruleSetToJson(rules)}),
      (id, replies) async {
        final frame = await _firstReply(replies);
        if (frame.type == FrameType.scanResult) {
          return decodeScanResult(frame.payload);
        }
        throw switch (AgentResult.fromFrame(frame)) {
          AgentFailure(:final error) => AgentOperationException(error),
          AgentSuccess() => StateError(
            'Peer answered scan with a success control frame, not a scan result',
          ),
        };
      },
    ),
  );

  /// Streams the file. A consumer that stops early — which `Applier` makes
  /// the normal case, since SPEC §7.6 has the run carrying on after a failed
  /// write — costs nothing beyond the bytes already in flight: the id is
  /// marked discarded and the peer's remaining `fileBytes` frames route
  /// nowhere.
  ///
  /// This is what the correlation id bought most visibly. Without one, the
  /// rest of the file had to be *drained* over the wire before the next
  /// operation could be read at all, because a reply could only be matched
  /// positionally and raw file bytes would otherwise have been decoded as
  /// the next operation's control reply.
  @override
  Stream<List<int>> readFile(String path) =>
      _window.runStream(path, AgentOp.readFile, () async* {
        final id = _nextRequestId();
        final replies = _router.open(id);
        var complete = false;
        try {
          await _send(AgentRequest(AgentOp.readFile.name, {'path': path}), id);
          yield* readByteStream(replies);
          complete = true;
        } finally {
          _router.close(id, discardRemaining: !complete);
        }
      });

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) => _window.run(
    path,
    AgentOp.writeFile,
    () => _exchange(
      AgentRequest(AgentOp.writeFile.name, {
        'path': path,
        'mtime': mtime,
        'mode': mode,
      }),
      (id, replies) async {
        await sendByteStream(_channel, data, requestId: id);
        final result = await _awaitResult(replies);
        return fileMetadataFromJson(result['metadata'] as Map<String, dynamic>);
      },
    ),
  );

  @override
  Future<void> delete(String path) => _window.run(
    path,
    AgentOp.delete,
    () => _call(AgentOp.delete, {'path': path}),
  );

  /// A barrier, and the only windowed-out operation that is one on its own
  /// merits rather than by category: it reaches *ancestors* of [path] (SPEC
  /// §7.5), so it can remove a directory a concurrent `writeFile` on an
  /// unrelated path is about to write into.
  ///
  /// It costs nothing in practice, because `Applier` no longer calls it
  /// during the apply loop at all — it sweeps once, after every action is
  /// done, when there is nothing left in the window to drain (SPEC §7.5).
  /// The barrier stays because the hazard is this operation's, not the
  /// caller's, and a future caller that did interleave it must not have to
  /// rediscover why that is unsafe.
  @override
  Future<void> removeEmptyDirs(String path) => _window.runExclusive(
    AgentOp.removeEmptyDirs,
    () => _call(AgentOp.removeEmptyDirs, {'path': path}),
  );

  @override
  Future<void> archiveCommitUpsert(ArchiveEntry entry) => _window.run(
    entry.path,
    AgentOp.archiveCommitUpsert,
    () => _call(AgentOp.archiveCommitUpsert, {
      'entry': archiveEntryToJson(entry),
    }),
  );

  /// Windowed, exactly as [archiveCommitUpsert] is: both append one record
  /// for one path to this replica's archive (SPEC §7.3), and neither can
  /// affect another path's outcome. A barrier here would have made every
  /// delete action drain the connection, which is the whole window's worth
  /// of overlap given up for a tombstone.
  @override
  Future<void> archiveCommitDelete(String path) => _window.run(
    path,
    AgentOp.archiveCommitDelete,
    () => _call(AgentOp.archiveCommitDelete, {'path': path}),
  );

  @override
  Future<void> compact() =>
      _window.runExclusive(AgentOp.compact, () => _call(AgentOp.compact));

  @override
  Future<void> disconnect() =>
      _window.runExclusive(AgentOp.disconnect, () async {
        await _channel.close();
        // The router holds its subscription to [Channel.input] and, between
        // frames, holds it *paused* — and a paused subscription on a pipe keeps
        // the file descriptor registered with the event loop whatever the peer
        // does with its end. Closing the channel is not enough to release it: a
        // CLI run over a real ssh session printed its summary, exited
        // `RunController`, and then sat there forever with nothing left to do.
        // Cancelling is what lets the process exit.
        await _router.cancel();
        await _reading.catchError((_) {});
      });

  /// One request-and-reply exchange under a fresh id, with the route open
  /// for as long as [body] needs it.
  Future<T> _exchange<T>(
    AgentRequest request,
    Future<T> Function(int id, Stream<Frame> replies) body,
  ) async {
    final id = _nextRequestId();
    final replies = _router.open(id);
    try {
      await _send(request, id);
      return await body(id, replies);
    } finally {
      _router.close(id);
    }
  }

  /// [AgentOp.name] *is* the protocol's `op` string (SPEC §15.3), so naming
  /// the operation once names it for the wire and for the window's report
  /// both, and the two cannot drift apart.
  Future<Map<String, dynamic>> _call(
    AgentOp op, [
    Map<String, dynamic> params = const {},
  ]) => _exchange(
    AgentRequest(op.name, params),
    (id, replies) => _awaitResult(replies),
  );

  int _nextRequestId() {
    // Wraps past the id the handshake and the heartbeats own rather than
    // through it. A `uint32` is four billion requests, against the ~28,000 a
    // 14k-file tree costs (SPEC §17), so this is about not writing an
    // overflow rather than about a session that reaches one.
    _lastRequestId = _lastRequestId == 0xFFFFFFFF ? 1 : _lastRequestId + 1;
    return _lastRequestId;
  }

  Future<void> _send(AgentRequest request, int requestId) =>
      _channel.send(FrameCodec().encode(request.toFrame(requestId)));

  /// The one frame answering this request, with the meaning this caller
  /// gives a route that ended without one.
  Future<Frame> _firstReply(Stream<Frame> replies) async {
    try {
      return await replies.first;
    } on StateError {
      throw StateError('Channel closed before a response arrived');
    }
  }

  Future<Map<String, dynamic>> _awaitResult(Stream<Frame> replies) async {
    return switch (AgentResult.fromFrame(await _firstReply(replies))) {
      AgentSuccess(:final data) => data,
      AgentFailure(:final error) => throw AgentOperationException(error),
    };
  }
}
