import 'dart:async';
import 'dart:convert';

import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';

/// The protocol version this build speaks (SPEC §4.2). Bumped whenever the
/// wire format changes in a way older and newer builds can't both handle.
///
/// The rule this codebase has settled on, after several changes that did not
/// bump it (`hello`'s last field addition, `scanEntryToJson`'s `reason`):
/// **adding** an optional field does not bump, because a peer that omits it
/// decodes to the same absence it would have had anyway — the older build
/// simply cannot serve the newer operation. **Renaming or repurposing** a
/// field does, because both directions then decode successfully and silently
/// wrong: the key the peer sent is not the key that is read, so the value is
/// dropped with no error anywhere.
///
/// Bumped to 2 by task 37bf4f, the first change of the second kind: `scan`'s
/// reply renamed `skippedSymlinks` (a list of paths) to `skippedPaths` (a
/// list of objects carrying a reason, SPEC §5.1). A version-1 agent paired
/// with this build would report no skipped symlinks at all rather than fail,
/// which is precisely the surprise §5.1 exists to prevent — better to refuse
/// the pairing outright (SPEC §11.5 exit 3).
const protocolVersion = 2;

/// Performs the first exchange on a connection (SPEC §4.2): sends this
/// build's [protocolVersion] as a control frame, then reads the peer's.
///
/// Reads through [frames] rather than a fresh listen on [channel]'s input so
/// the same decoded-frame stream can keep being consumed for the rest of the
/// connection afterward — [frames] must be a `StreamIterator` over
/// `FrameCodec().decode(channel.input)`, and the caller keeps using that same
/// iterator once this returns.
///
/// Throws [ProtocolVersionMismatchException] — fatal for the caller (SPEC
/// §11.5 exit 3) — if the versions differ. Throws [StateError] if the channel
/// closes before the peer's version arrives.
Future<void> performVersionHandshake(
  Channel channel,
  StreamIterator<Frame> frames,
) async {
  await channel.send(FrameCodec().encode(_versionFrame(protocolVersion)));

  if (!await frames.moveNext()) {
    throw StateError('Channel closed before version handshake completed');
  }
  final remoteVersion = _versionFromFrame(frames.current);
  if (remoteVersion != protocolVersion) {
    throw ProtocolVersionMismatchException(
      local: protocolVersion,
      remote: remoteVersion,
    );
  }
}

Frame _versionFrame(int version) => Frame(
  type: FrameType.control,
  payload: utf8.encode(jsonEncode({'version': version})),
);

int _versionFromFrame(Frame frame) {
  final message =
      jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
  return message['version'] as int;
}

/// Thrown by [performVersionHandshake] when the peer speaks a different
/// protocol version (SPEC §4.2) — fatal for the caller (SPEC §11.5 exit 3).
class ProtocolVersionMismatchException implements Exception {
  final int local;
  final int remote;

  const ProtocolVersionMismatchException({
    required this.local,
    required this.remote,
  });

  @override
  String toString() =>
      'Protocol version mismatch: local=$local, remote=$remote';
}
