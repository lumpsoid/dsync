import 'dart:async';
import 'dart:convert';

import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/far_side_report.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';

/// The wire schema `RemoteAgent` and the agent server handler share (SPEC
/// §4.2): requests and results as control frames, plus the byte-stream framing
/// used by `readFile`/`writeFile`. Defined once here so both ends decode
/// exactly what the other encodes.
///
/// Two payloads live elsewhere, both because they are not JSON: the version
/// handshake (`version_handshake.dart`) and a successful `scan` reply, which
/// is the binary encoding in `scan_result_codec.dart` (SPEC §15.3). A *failed*
/// `scan` is still an [AgentFailure] from this file.
/// One `Agent` operation's request, sent as a control frame.
///
/// The request id is not part of this payload: it is a header field on every
/// frame of the exchange (SPEC §4.2), so it is passed to [toFrame] by
/// whoever allocated it rather than carried here, and read back off
/// [Frame.requestId] rather than out of the JSON.
class AgentRequest {
  final String op;
  final Map<String, dynamic> params;

  const AgentRequest(this.op, [this.params = const {}]);

  Frame toFrame(int requestId) => Frame(
    type: FrameType.control,
    requestId: requestId,
    payload: utf8.encode(jsonEncode({'op': op, ...params})),
  );

  static AgentRequest fromFrame(Frame frame) {
    final json = _decodeControlJson(frame);
    final op = json.remove('op') as String;
    return AgentRequest(op, json);
  }
}

/// The outcome of one `Agent` operation, sent back as a control frame.
sealed class AgentResult {
  const AgentResult();

  /// This result as the frame that answers request [requestId] — echoed
  /// unchanged from the request, which is how the peer matches it back
  /// (SPEC §4.2).
  Frame toFrame(int requestId);

  static AgentResult fromFrame(Frame frame) {
    final json = _decodeControlJson(frame);
    return json['ok'] == true
        ? AgentSuccess(json..remove('ok'))
        : AgentFailure(json['error'] as String);
  }
}

/// The keys under which a peer reports what an exchange cost *it* (SPEC §17)
/// — see [FarSideReport] for what each one means.
///
/// **Optional, and absent is not zero.** A build that does not measure them
/// omits the keys, and [farSideFromJson] answers null rather than a report of
/// `Duration.zero`: zero would read as "the destination cost nothing", which
/// is exactly the conclusion these figures exist to check rather than assume.
/// Added optional fields need no `protocolVersion` bump — a peer that omits
/// them decodes to the absence it would have had anyway, one key at a time.
const farSideKey = 'farSideMicros';
const farInFlightKey = 'farInFlight';
const farSendWaitKey = 'farSendWaitMicros';
const farInboundWaitKey = 'farInboundWaitMicros';

/// What the peer said this exchange cost it, or null if it said nothing.
///
/// [FarSideReport.span] is what makes a report a report: a peer that reports
/// its concurrency but not its span has told us nothing to attribute, so that
/// decodes as no report at all rather than as a report with a hole in it.
FarSideReport? farSideFromJson(Map<String, dynamic> data) {
  final micros = data[farSideKey];
  if (micros is! int) return null;
  final inFlight = data[farInFlightKey];
  final sendWait = data[farSendWaitKey];
  final inboundWait = data[farInboundWaitKey];
  return FarSideReport(
    span: Duration(microseconds: micros),
    inFlight: inFlight is int ? inFlight : null,
    sendWait: sendWait is int ? Duration(microseconds: sendWait) : null,
    inboundWait: inboundWait is int
        ? Duration(microseconds: inboundWait)
        : null,
  );
}

/// The operation succeeded; [data] carries whatever result it returns, empty
/// for operations with nothing to report beyond having happened.
class AgentSuccess extends AgentResult {
  final Map<String, dynamic> data;

  const AgentSuccess([this.data = const {}]);

  /// This result with what the exchange cost this side added (SPEC §17),
  /// which is how those keys get onto the wire without every `case` in the
  /// dispatch having to remember them.
  ///
  /// A figure this side could not measure is left out rather than sent as
  /// zero, so the absence the decoder preserves starts here.
  AgentSuccess withFarSide(FarSideReport report) => AgentSuccess({
    ...data,
    farSideKey: report.span.inMicroseconds,
    if (report.inFlight != null) farInFlightKey: report.inFlight!,
    if (report.sendWait case final wait?) farSendWaitKey: wait.inMicroseconds,
    if (report.inboundWait case final wait?)
      farInboundWaitKey: wait.inMicroseconds,
  });

  @override
  Frame toFrame(int requestId) => Frame(
    type: FrameType.control,
    requestId: requestId,
    payload: utf8.encode(jsonEncode({'ok': true, ...data})),
  );
}

/// The operation failed; [error] is the failure's `toString()` on the side
/// that raised it.
class AgentFailure extends AgentResult {
  final String error;

  const AgentFailure(this.error);

  @override
  Frame toFrame(int requestId) => Frame(
    type: FrameType.control,
    requestId: requestId,
    payload: utf8.encode(jsonEncode({'ok': false, 'error': error})),
  );
}

Map<String, dynamic> _decodeControlJson(Frame frame) =>
    Map<String, dynamic>.from(jsonDecode(utf8.decode(frame.payload)) as Map);

/// The replica identification sent as `hello`'s `replica` parameter (SPEC
/// §4.2), so the peer can construct the `LocalAgent` it is about to be asked
/// to drive.
Map<String, dynamic> replicaSpecToJson(ReplicaSpec spec) => {
  'rootPath': spec.rootPath,
  'profileId': spec.profileId,
  'side': spec.side,
  'jobs': spec.jobs,
};

ReplicaSpec replicaSpecFromJson(Map<String, dynamic> json) => ReplicaSpec(
  rootPath: json['rootPath'] as String,
  profileId: json['profileId'] as String,
  side: json['side'] as String,
  jobs: json['jobs'] as int,
);

/// What `hello` replies with (SPEC §4.2): the replying replica's own
/// [ReplicaInfo].
Map<String, dynamic> replicaInfoToJson(ReplicaInfo info) => {
  if (info.lastCommitTime != null)
    'lastCommitTime': info.lastCommitTime!.microsecondsSinceEpoch,
  if (info.archivePath != null) 'archivePath': info.archivePath,
};

ReplicaInfo replicaInfoFromJson(Map<String, dynamic> json) => ReplicaInfo(
  lastCommitTime: json['lastCommitTime'] == null
      ? null
      : DateTime.fromMicrosecondsSinceEpoch(json['lastCommitTime'] as int),
  archivePath: json['archivePath'] as String?,
);

/// Thrown by `RemoteAgent` when the peer reports an [AgentFailure] for an
/// operation (SPEC §4.2) — fatal for the caller (SPEC §11.5 exit 3), the same
/// as the equivalent local failure would be.
class AgentOperationException implements Exception {
  final String message;

  const AgentOperationException(this.message);

  @override
  String toString() => 'Remote agent operation failed: $message';
}

/// Sends [data] over [channel] as `fileBytes` frames (SPEC §4.2), one per
/// chunk, all tagged [requestId], terminated by an empty `fileBytes` frame so
/// the receiver learns the stream ended without needing its length up front.
/// Never buffers more than one chunk at a time.
///
/// Every frame carries [requestId] because that is what lets this transfer
/// interleave with other operations on the same connection (task 0f7dfc) —
/// a `fileBytes` frame with no identity can only be read by arrival order,
/// which is what used to cap the connection at one operation.
///
/// If [data] itself fails, the failure is sent as a control frame in place of
/// the terminator so [readByteStream] aborts instead of treating a partial
/// transfer as complete. This function never throws: the exchange is left
/// properly terminated either way, and the caller is expected to still await
/// that operation's own response.
Future<void> sendByteStream(
  Channel channel,
  Stream<List<int>> data, {
  required int requestId,
}) async {
  final codec = FrameCodec();
  try {
    await for (final chunk in data) {
      if (chunk.isEmpty) continue;
      await channel.send(
        codec.encode(
          Frame(
            type: FrameType.fileBytes,
            requestId: requestId,
            payload: chunk,
          ),
        ),
      );
    }
    await channel.send(
      codec.encode(
        Frame(
          type: FrameType.fileBytes,
          requestId: requestId,
          payload: const [],
        ),
      ),
    );
  } catch (error) {
    await channel.send(codec.encode(AgentFailure('$error').toFrame(requestId)));
  }
}

/// Reads the `fileBytes` frames [sendByteStream] wrote back out of [frames]
/// — one exchange's route off a `FrameRouter`, so every frame here already
/// belongs to this transfer — yielding each non-empty chunk and stopping at
/// the empty terminator frame.
///
/// Throws [AgentOperationException] if the sender aborted with a failure
/// control frame instead of a normal terminator, or [StateError] if the
/// channel closes mid-stream.
///
/// A [FrameType.heartbeat] tick can no longer be mistaken for file bytes or
/// for the terminator, which used to be this reader's sharpest hazard: a
/// tick belongs to no request (SPEC §4.2) and `FrameRouter` drops it before
/// any route sees it.
Stream<List<int>> readByteStream(Stream<Frame> frames) async* {
  var terminated = false;
  await for (final frame in frames) {
    if (frame.type == FrameType.control) {
      throw switch (AgentResult.fromFrame(frame)) {
        AgentFailure(:final error) => AgentOperationException(error),
        AgentSuccess() => StateError('Unexpected success frame mid-stream'),
      };
    }
    if (frame.payload.isEmpty) {
      terminated = true;
      return;
    }
    yield frame.payload;
  }
  if (!terminated) {
    throw StateError('Channel closed mid-stream');
  }
}

/// Sends the rules as the patterns they were written as, not as compiled
/// regexes: the peer compiles them itself, so a malformed pattern is rejected
/// on both sides (SPEC §9).
Map<String, dynamic> ruleSetToJson(RuleSet rules) => {
  'ignore': rules.ignorePatterns,
  'follow': rules.followPatterns,
};

RuleSet ruleSetFromJson(Map<String, dynamic> json) => RuleSet(
  ignore: (json['ignore'] as List? ?? const []).cast<String>(),
  follow: (json['follow'] as List? ?? const []).cast<String>(),
);

Map<String, dynamic> archiveEntryToJson(ArchiveEntry entry) => {
  'path': entry.path,
  'size': entry.size,
  'mtime': entry.mtime,
  'mode': entry.mode,
  'hash': entry.hash,
};

ArchiveEntry archiveEntryFromJson(Map<String, dynamic> json) => ArchiveEntry(
  path: json['path'] as String,
  size: json['size'] as int,
  mtime: json['mtime'] as int,
  mode: json['mode'] as int,
  hash: json['hash'] as String,
);

/// One commit, tagged by which kind it is rather than inferred from which
/// fields are present: the two cases are a sum type in `ArchiveCommit` and
/// there is no reason for the wire to be the one place they are not.
Map<String, dynamic> archiveCommitToJson(ArchiveCommit commit) =>
    switch (commit) {
      ArchiveUpsert(:final entry) => {'upsert': archiveEntryToJson(entry)},
      ArchiveTombstone(:final path) => {'delete': path},
    };

ArchiveCommit archiveCommitFromJson(Map<String, dynamic> json) =>
    switch (json) {
      {'upsert': final Map<String, dynamic> entry} => ArchiveUpsert(
        archiveEntryFromJson(entry),
      ),
      {'delete': final String path} => ArchiveTombstone(path),
      _ => throw FormatException('Not an archive commit: $json'),
    };

Map<String, dynamic> fileMetadataToJson(FileMetadata metadata) => {
  'size': metadata.size,
  'mtime': metadata.mtime,
  'mode': metadata.mode,
};

FileMetadata fileMetadataFromJson(Map<String, dynamic> json) => FileMetadata(
  size: json['size'] as int,
  mtime: json['mtime'] as int,
  mode: json['mode'] as int,
);
