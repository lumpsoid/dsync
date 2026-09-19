import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/request_window.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/exchange_record.dart';
import 'package:dsync/dsync_core/models/far_side_report.dart';
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
import 'package:dsync/dsync_core/run/elapsed.dart';

/// Told what one exchange cost, split where it happened (SPEC §17) — the
/// seam `RemoteAgent`'s owner uses to feed `RunMetricsRecorder`.
///
/// A callback rather than the recorder itself: this class hands over a record
/// it has just finished measuring and knows nothing about reporting. Called
/// once per completed exchange, including a failed one — a run that spent
/// thirty seconds on requests that all threw is a run whose report should say
/// thirty seconds.
typedef ExchangeSink = void Function(ExchangeRecord record);

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
  final RequestWindow _window;

  /// Reads this connection and stamps every frame it decodes with [_elapsed],
  /// so a reply's arrival and this call's completion are two readings of one
  /// clock (SPEC §17). Built in the body rather than the initialiser list for
  /// that reason: it has to be handed the clock this object settled on.
  late final FrameRouter _router;

  /// Where each finished exchange's split is reported, if anyone asked (SPEC
  /// §17). Public because it is a seam the owner supplies, not internal state.
  final ExchangeSink? onExchange;

  /// Where the instants every [ExchangeRecord] is made of come from.
  /// Injected for the reason `RequestWindow`'s is: a test asserts a queue
  /// wait with plain values instead of sleeping.
  final Elapsed _elapsed;

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
  ///
  /// [onExchange] is where each exchange's measured split goes. Null for a
  /// caller that is not measuring.
  RemoteAgent(
    Channel channel,
    ReplicaSpec spec, {
    RequestWindow? window,
    this.onExchange,
    Elapsed? elapsed,
  }) : _channel = channel,
       _spec = spec,
       _elapsed = elapsed ?? stopwatchElapsed(),
       _window = window ?? RequestWindow() {
    _router = FrameRouter(channel.input, elapsed: _elapsed);
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
  Future<ReplicaInfo> hello() => _exclusive(AgentOp.hello, (record) async {
    // Both version frames carry [Frame.noRequest]: the handshake precedes
    // every request, so there is no request for them to belong to.
    try {
      await performVersionHandshake(_channel, _handshakeReplies);
    } finally {
      _router.close(Frame.noRequest);
    }
    return _exchange(
      AgentRequest(AgentOp.hello.name, {'replica': replicaSpecToJson(_spec)}),
      (id, replies) async =>
          replicaInfoFromJson(await _awaitResult(record, replies)),
    );
  });

  @override
  Future<void> lock() => _exclusive(AgentOp.lock, _call);

  @override
  Future<void> unlock() => _exclusive(AgentOp.unlock, _call);

  /// The one operation whose success does not come back as a control frame
  /// (SPEC §15.3): a `scan` reply is `FrameType.scanResult`, the binary
  /// encoding in `scan_result_codec.dart`. A *failure* is still an
  /// `AgentFailure` control frame, so the frame type is what tells the two
  /// apart — which is why this cannot go through [_call].
  ///
  /// It is also one of the two replies with nowhere to carry what the peer
  /// spent (SPEC §17): the record this reports has a queue wait and a wire
  /// span and no far side at all, which is absent rather than zero.
  @override
  Future<ScanResult> scan(RuleSet rules) => _exclusive(
    AgentOp.scan,
    (record) => _exchange(
      AgentRequest(AgentOp.scan.name, {'rules': ruleSetToJson(rules)}),
      (id, replies) async {
        final frame = await _firstReply(replies);
        record.sawReply(frame);
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
  ///
  /// The record covers the whole stream rather than the call that starts it,
  /// which is also what holds the window slot — so the two agree about what
  /// this operation's span is.
  @override
  Stream<List<int>> readFile(String path) async* {
    final record = _Exchange(AgentOp.readFile, _elapsed);
    try {
      yield* _window.runStream(path, () async* {
        record.admit();
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
    } finally {
      record.report(onExchange);
    }
  }

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) => _windowed(
    [path],
    AgentOp.writeFile,
    (record) => _exchange(
      AgentRequest(AgentOp.writeFile.name, {
        'path': path,
        'mtime': mtime,
        'mode': mode,
      }),
      (id, replies) async {
        await sendByteStream(_channel, data, requestId: id);
        final result = await _awaitResult(record, replies);
        return fileMetadataFromJson(result['metadata'] as Map<String, dynamic>);
      },
    ),
  );

  @override
  Future<void> delete(String path) => _windowed(
    [path],
    AgentOp.delete,
    (record) => _call(record, {'path': path}),
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
  Future<void> removeEmptyDirs(String path) => _exclusive(
    AgentOp.removeEmptyDirs,
    (record) => _call(record, {'path': path}),
  );

  /// Windowed rather than a barrier: every record in the batch appends to
  /// this replica's archive under its own path (SPEC §7.3), so none of them
  /// can affect another path's outcome. It enters the window under every path
  /// it carries, so it still cannot overtake the `writeFile` or `delete` that
  /// earned one of those records.
  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) => _windowed(
    [for (final commit in commits) commit.path],
    AgentOp.archiveCommit,
    (record) => _call(record, {
      'commits': [for (final commit in commits) archiveCommitToJson(commit)],
    }),
  );

  @override
  Future<void> compact() => _exclusive(AgentOp.compact, _call);

  @override
  Future<void> disconnect() => _exclusive(AgentOp.disconnect, (record) async {
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

  /// Measures one barrier operation end to end and reports it (SPEC §17).
  ///
  /// The window's admission is marked from inside its body, so the record's
  /// queue wait is this call's own — not a total the window accumulated for
  /// every call of this operation and that something else would have to
  /// divide back out.
  Future<T> _exclusive<T>(
    AgentOp op,
    Future<T> Function(_Exchange record) body,
  ) async {
    final record = _Exchange(op, _elapsed);
    try {
      return await _window.runExclusive(() {
        record.admit();
        return body(record);
      });
    } finally {
      record.report(onExchange);
    }
  }

  /// [_exclusive] for an operation that goes in the window under [paths].
  Future<T> _windowed<T>(
    List<String> paths,
    AgentOp op,
    Future<T> Function(_Exchange record) body,
  ) async {
    final record = _Exchange(op, _elapsed);
    try {
      return await _window.runAll(paths, () {
        record.admit();
        return body(record);
      });
    } finally {
      record.report(onExchange);
    }
  }

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
  /// the operation once names it for the wire and for the record both, and
  /// the two cannot drift apart.
  Future<Map<String, dynamic>> _call(
    _Exchange record, [
    Map<String, dynamic> params = const {},
  ]) => _exchange(
    AgentRequest(record.op.name, params),
    (id, replies) => _awaitResult(record, replies),
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

  /// The reply's payload, and — on the way past — whatever the peer said
  /// this exchange cost *it* (SPEC §17).
  ///
  /// Stashed on [record] rather than reported straight out, because the
  /// figure belongs to this call and the call is not over: the record leaves
  /// as one measurement with its own queue wait, its own wire span and its
  /// own far side, so nothing downstream ever has to pair them up again.
  ///
  /// Read here rather than in each operation because this is the one place
  /// every control-frame reply passes through. The two replies that do not
  /// come through here, `scan` and `readFile`, have nowhere to carry it and
  /// report nothing, which stays distinguishable from zero.
  Future<Map<String, dynamic>> _awaitResult(
    _Exchange record,
    Stream<Frame> replies,
  ) async {
    final frame = await _firstReply(replies);
    record.sawReply(frame);
    return switch (AgentResult.fromFrame(frame)) {
      AgentSuccess(:final data) => record.sawFarSide(data),
      AgentFailure(:final error) => throw AgentOperationException(error),
    };
  }
}

/// One exchange being measured: the instants `RemoteAgent` owns, held until
/// the call is over and they can leave together as an [ExchangeRecord].
///
/// Mutable and private. [ExchangeRecord] is the immutable shape that leaves
/// this file, for the same reason the recorder's replica record is private.
class _Exchange {
  final AgentOp op;
  final Elapsed _elapsed;

  final Duration _issuedAt;

  /// When the window let this call start, or null while it is still queued —
  /// which is not the same as "it waited no time", and is why this is
  /// nullable rather than initialised to [_issuedAt].
  Duration? _admittedAt;

  FarSideReport? _far;

  /// When the reply's bytes arrived at the channel, or null for an exchange
  /// whose reply was never stamped — see [sawReply].
  Duration? _replyArrivedAt;

  bool _reported = false;

  _Exchange(this.op, this._elapsed) : _issuedAt = _elapsed();

  /// Marks the window's admission — called from inside the window's body, so
  /// it is this call's instant and no one else's.
  void admit() => _admittedAt ??= _elapsed();

  /// Keeps when [frame]'s bytes arrived, so [report] can say what this side
  /// spent between having the reply and finishing the call (SPEC §17).
  ///
  /// Called for the *one* frame that answers a request, never for a
  /// `readFile`'s stream: the span is only a measure of this isolate while
  /// nothing else is inside it, and between a file frame arriving and that
  /// call ending sits the consumer, which is the other replica's `writeFile`.
  ///
  /// A frame with no stamp leaves the span absent rather than zero — this
  /// side did not measure, which is not the same as having taken no time.
  void sawReply(Frame frame) => _replyArrivedAt = frame.arrivedAt;

  /// Keeps what [data] says the peer spent on this call, and answers [data]
  /// so this can sit on the decode path without a statement of its own.
  Map<String, dynamic> sawFarSide(Map<String, dynamic> data) {
    _far = farSideFromJson(data);
    return data;
  }

  /// Hands the finished measurement to [sink], once.
  ///
  /// Idempotent, so a `finally` on an abandoned `readFile` stream cannot
  /// report the same exchange twice. A call that never reached the window —
  /// one whose predecessor threw — reports a wire span of zero and its real
  /// wait, which is the honest reading of an operation that was only ever
  /// queued.
  void report(ExchangeSink? sink) {
    if (_reported || sink == null) return;
    _reported = true;
    final now = _elapsed();
    final admitted = _admittedAt ?? now;
    final arrived = _replyArrivedAt;
    sink(
      ExchangeRecord(
        op: op,
        queueWait: admitted - _issuedAt,
        wire: now - admitted,
        far: _far,
        settle: arrived == null ? null : now - arrived,
      ),
    );
  }
}
