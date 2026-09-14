import 'dart:async';
import 'dart:convert';

import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';

/// The wire schema `RemoteAgent` and the agent server handler share for
/// every `Agent` operation other than the version handshake (SPEC §4.2):
/// requests and results as control frames, plus the byte-stream framing used
/// by `readFile`/`writeFile`. Defined once here so both ends decode exactly
/// what the other encodes.
/// One `Agent` operation's request, sent as a control frame.
class AgentRequest {
  final String op;
  final Map<String, dynamic> params;

  const AgentRequest(this.op, [this.params = const {}]);

  Frame toFrame() => Frame(
    type: FrameType.control,
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

  Frame toFrame();

  static AgentResult fromFrame(Frame frame) {
    final json = _decodeControlJson(frame);
    return json['ok'] == true
        ? AgentSuccess(json..remove('ok'))
        : AgentFailure(json['error'] as String);
  }
}

/// The operation succeeded; [data] carries whatever result it returns, empty
/// for operations with nothing to report beyond having happened.
class AgentSuccess extends AgentResult {
  final Map<String, dynamic> data;

  const AgentSuccess([this.data = const {}]);

  @override
  Frame toFrame() => Frame(
    type: FrameType.control,
    payload: utf8.encode(jsonEncode({'ok': true, ...data})),
  );
}

/// The operation failed; [error] is the failure's `toString()` on the side
/// that raised it.
class AgentFailure extends AgentResult {
  final String error;

  const AgentFailure(this.error);

  @override
  Frame toFrame() => Frame(
    type: FrameType.control,
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
/// chunk, terminated by an empty `fileBytes` frame so the receiver learns the
/// stream ended without needing its length up front. Never buffers more than
/// one chunk at a time.
///
/// If [data] itself fails, the failure is sent as a control frame in place of
/// the terminator so [readByteStream] aborts instead of treating a partial
/// transfer as complete. This function never throws: the shared frame stream
/// stays aligned for whatever operation comes next, and the caller is
/// expected to still await that operation's own response.
Future<void> sendByteStream(Channel channel, Stream<List<int>> data) async {
  final codec = FrameCodec();
  try {
    await for (final chunk in data) {
      if (chunk.isEmpty) continue;
      await channel.send(
        codec.encode(Frame(type: FrameType.fileBytes, payload: chunk)),
      );
    }
    await channel.send(
      codec.encode(Frame(type: FrameType.fileBytes, payload: const [])),
    );
  } catch (error) {
    await channel.send(codec.encode(AgentFailure('$error').toFrame()));
  }
}

/// Reads the `fileBytes` frames [sendByteStream] wrote back out of [frames],
/// yielding each non-empty chunk and stopping at the empty terminator frame.
///
/// Throws [AgentOperationException] if the sender aborted with a failure
/// control frame instead of a normal terminator, or [StateError] if the
/// channel closes mid-stream.
Stream<List<int>> readByteStream(StreamIterator<Frame> frames) async* {
  while (true) {
    if (!await frames.moveNext()) {
      throw StateError('Channel closed mid-stream');
    }
    final frame = frames.current;
    if (frame.type == FrameType.control) {
      throw switch (AgentResult.fromFrame(frame)) {
        AgentFailure(:final error) => AgentOperationException(error),
        AgentSuccess() => StateError('Unexpected success frame mid-stream'),
      };
    }
    if (frame.payload.isEmpty) return;
    yield frame.payload;
  }
}

Map<String, dynamic> scanResultToJson(ScanResult result) => {
  'entries': result.entries.map(scanEntryToJson).toList(),
  'skippedPaths': result.skippedPaths.map(skippedPathToJson).toList(),
};

ScanResult scanResultFromJson(Map<String, dynamic> json) => ScanResult(
  entries: (json['entries'] as List)
      .map((e) => scanEntryFromJson(e as Map<String, dynamic>))
      .toList(),
  skippedPaths: (json['skippedPaths'] as List? ?? const [])
      .map((e) => skippedPathFromJson(e as Map<String, dynamic>))
      .toList(),
);

/// One [SkippedPath] (SPEC §5, §5.1), as it appears in a `scan` reply's
/// `skippedPaths` list. [SkippedPath.detail] is omitted when null, matching
/// this file's null-omission convention — it is meaningful for
/// [SkippedReason.unreadable] and has nothing to say for
/// [SkippedReason.symlink].
Map<String, dynamic> skippedPathToJson(SkippedPath skipped) => {
  'path': skipped.path,
  'reason': skipped.reason.name,
  if (skipped.detail != null) 'detail': skipped.detail,
};

SkippedPath skippedPathFromJson(Map<String, dynamic> json) => SkippedPath(
  path: json['path'] as String,
  reason: SkippedReason.values.byName(json['reason'] as String),
  detail: json['detail'] as String?,
);

/// Encodes [entry] with [ScanEntry.reason], not the coarser [ScanEntry.status]
/// it derives — [ScanReason] is the sum type that actually decides the
/// entry's state (see its doc comment), so it is the one fact this wire
/// format needs; re-deriving [ScanStatus] after decode via [ScanEntry.status]
/// can never disagree with it, the way sending both independently could.
/// [protocolVersion] was not bumped for this (SPEC §4.2): an added field is
/// absent either way to a peer that does not know it, so an agent built
/// before this field existed cannot serve a `scan` request but nothing
/// decodes silently wrong. See [protocolVersion]'s own doc comment for where
/// that stops being true — task 37bf4f's rename of this same reply's
/// `skippedSymlinks` is the change that did bump it.
Map<String, dynamic> scanEntryToJson(ScanEntry entry) => {
  'path': entry.path,
  'reason': entry.reason.name,
  if (entry.size != null) 'size': entry.size,
  if (entry.mtime != null) 'mtime': entry.mtime,
  if (entry.mode != null) 'mode': entry.mode,
  if (entry.hash != null) 'hash': entry.hash,
};

ScanEntry scanEntryFromJson(Map<String, dynamic> json) => ScanEntry(
  path: json['path'] as String,
  reason: ScanReason.values.byName(json['reason'] as String),
  size: json['size'] as int?,
  mtime: json['mtime'] as int?,
  mode: json['mode'] as int?,
  hash: json['hash'] as String?,
);

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
