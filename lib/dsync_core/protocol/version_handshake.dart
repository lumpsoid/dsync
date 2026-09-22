import 'dart:async';
import 'dart:convert';

import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';

/// The protocol version this build speaks (SPEC §4.2). Bumped whenever the
/// wire format changes in a way older and newer builds can't both handle.
///
/// **4 since task 97171c**, which split `scan` into SPEC §6.1's three
/// exchanges — the changed entries, then a digest per bucket over the
/// unchanged ones, then only the buckets the two sides disagreed on. It adds
/// two agent operations, so a version-3 peer answers `scanDigests` with
/// "Unknown agent operation": loud, but *mid-run*, after both replicas are
/// locked and one has just walked its whole tree, and — worse than 9d2158's
/// case — this build would read a version-3 peer's single full `scan` reply
/// as a phase-1 payload and find garbage where the tally should be. The bump
/// turns both into one refusal at the handshake.
///
/// **5 since task 58d609**, which writes a copy in place behind an
/// `ArchiveIntent` (SPEC §7.6) and reports marked paths as
/// `ScanReason.untrusted`. Both are new spellings a version-4 peer refuses —
/// the commit at its `archiveCommitFromJson`, the reason at its scan decoder.
/// Both refusals are loud, but one arrives mid-scan; the bump turns them into
/// one refusal at the handshake, before either replica is touched.
///
/// **3 since task 9d2158**, which replaced the per-path `archiveCommitUpsert`
/// and `archiveCommitDelete` operations with one `archiveCommit` carrying a
/// batch of records (SPEC §7.3). This is the change the paragraph below
/// predicted: it does not move the header, and a peer of either version
/// refuses the other's commits loudly — a version-2 peer answers
/// `archiveCommit` with "Unknown agent operation", and this build would answer
/// its `archiveCommitUpsert` the same way. Loud is not good enough on its own,
/// though: without the bump, the refusal arrives per path, in the middle of an
/// apply, after the files have already been written, as fourteen thousand
/// failed actions. The bump turns that into one refusal at the handshake,
/// before the run touches either replica, which is exactly what this constant
/// is for.
///
/// **2 since task 0f7dfc**, which widened the frame header from 5 bytes to 9
/// to carry a request id (`FrameCodec`). That is the first wire change here
/// that moves the header itself, and it is the kind a version exists for:
/// every frame a version-1 peer sends is undecodable to this build and
/// vice versa, in both directions, at the very first frame.
///
/// It is also the change that shows what the version field can and cannot
/// do. A peer speaking version 1 does not get a version mismatch — its
/// version frame has a 5-byte header, so this build reads its length field
/// out of the payload and refuses it as [PeerNotSpeakingProtocolException]
/// instead. The constant still earns the bump: it is what makes the *next*
/// change, which will not move the header, a clean refusal rather than a
/// corrupt session, and it stops this build from claiming to speak what a
/// version-1 build spoke. Both ends of a `peer://` pair are this project and
/// there is no third-party implementation to keep, which is why the header
/// could move at all.
///
/// Every earlier wire change left this at 1 — `hello`'s last field addition,
/// `scanEntryToJson`'s `reason`, task 37bf4f renaming `scan`'s
/// `skippedSymlinks` to `skippedPaths`, task 9551c4 respelling a successful
/// `scan` reply as the binary `FrameType.scanResult` (SPEC §15.3), and task
/// 40812e adding `FrameType.heartbeat` — on the argument that a version
/// exists to protect pairs that cannot be upgraded together, and there were
/// none. That argument has not changed; what changed is that this build
/// genuinely cannot read the older one at all, so saying so costs nothing
/// and mis-stating it would cost the next reader.
///
/// What a bump is *for*, restated now that one has happened: **adding** an
/// optional field does not need one, because a peer that omits it decodes to
/// the same absence it would have had anyway. **Renaming or repurposing** a
/// field does, because both directions then decode successfully and silently
/// wrong. **Respelling a payload** — 9551c4 — needs one least of all, since
/// JSON and this protocol's binary cannot be mistaken for each other.
/// **Adding a frame type** — 40812e — fails loudly at the type byte.
/// **Moving the header** — 0f7dfc — fails loudly too, but at a length field
/// read out of someone else's payload, which is the one failure mode worth
/// a constant that can be compared. **Replacing an operation** — 9d2158 —
/// fails loudly at the far end's `default` case, but only once the run is
/// already half done, which is why it took a bump as well.
const protocolVersion = 5;

/// Performs the first exchange on a connection (SPEC §4.2): sends this
/// build's [protocolVersion] as a control frame, then reads the peer's.
///
/// Reads through [replies] rather than a fresh listen on [channel]'s input so
/// the same reader can keep serving the rest of the connection afterward —
/// [replies] must be the `FrameRouter` route for [Frame.noRequest], which is
/// the id both version frames carry: the handshake precedes any request, so
/// there is no request for it to belong to (SPEC §4.2). The caller closes
/// that route once this returns.
///
/// Throws [ProtocolVersionMismatchException] — fatal for the caller (SPEC
/// §11.5 exit 3) — if the versions differ. Throws
/// [PeerNotSpeakingProtocolException] if what arrives is not frames at all.
/// Throws [StateError] if the channel closes before the peer's version
/// arrives.
Future<void> performVersionHandshake(
  Channel channel,
  Stream<Frame> replies,
) async {
  await channel.send(FrameCodec().encode(_versionFrame(protocolVersion)));

  // Read after the send, not before it: [replies] is a route off a
  // `FrameRouter`, opened by the caller before the connection was read at
  // all, so a version frame that has already arrived is waiting there rather
  // than missed. Taking the future up front instead leaves it holding an
  // error nothing is listening for across the `await` above, which Dart
  // reports as an unhandled error even though the `catch` below goes on to
  // convert it.
  final Frame reply;
  try {
    reply = await replies.first;
  } on StateError {
    // `Stream.first` on an empty stream — the route ended without a frame,
    // which is the peer closing before it answered.
    throw StateError('Channel closed before version handshake completed');
  } on FrameDecodeException catch (error) {
    // Rewritten here and nowhere else, deliberately. These are the first
    // bytes of a fresh connection, so undecodable ones mean nobody is
    // speaking the protocol yet — in practice a remote shell talking over
    // it. The identical failure *after* the handshake has succeeded is a
    // real protocol bug, and dressing that one up as "check your dotfiles"
    // would send the next debugger the wrong way, so it propagates as
    // itself.
    throw PeerNotSpeakingProtocolException(
      error.received,
      truncated: error.truncated,
    );
  }
  final remoteVersion = _versionFromFrame(reply);
  if (remoteVersion != protocolVersion) {
    throw ProtocolVersionMismatchException(
      local: protocolVersion,
      remote: remoteVersion,
    );
  }
}

Frame _versionFrame(int version) => Frame(
  type: FrameType.control,
  requestId: Frame.noRequest,
  payload: utf8.encode(jsonEncode({'version': version})),
);

int _versionFromFrame(Frame frame) {
  final message =
      jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
  return message['version'] as int;
}

/// Thrown by [performVersionHandshake] when what arrives in place of the
/// peer's version frame is not this protocol's framing at all (SPEC §4.2) —
/// fatal for the caller (SPEC §11.5 exit 3).
///
/// Quotes [received] back, because the whole point is that the bytes explain
/// themselves: `-T` already keeps a pty from echoing the stream, and `ssh`'s
/// own stderr already explains a connection that never opened, but neither
/// covers a connection that opens and is then talked over. What a user needs
/// to see is their own login banner sitting where a version frame should be.
class PeerNotSpeakingProtocolException implements Exception {
  /// The first bytes of the connection, as `FrameCodec` buffered them before
  /// giving up — capped, so this never holds more than a glance's worth.
  final List<int> received;

  /// Whether more arrived than [received] holds.
  final bool truncated;

  const PeerNotSpeakingProtocolException(
    this.received, {
    this.truncated = false,
  });

  @override
  String toString() =>
      'The peer is not speaking the dsync protocol (SPEC §4.2). In place of '
      'a version frame it sent:\n\n'
      '${_indented(_asText(received))}${truncated ? '\n  …' : ''}\n\n'
      'The connection itself opened, so this is not an ssh failure — '
      'something on the far side is writing to stdout, which is the stream '
      'the protocol runs over. sshd sources ~/.bashrc and friends even for a '
      'non-interactive command, so a login banner, an motd echo or a version '
      'manager greeting all land here. The shell that runs '
      '`dsync agent --stdio` has to say nothing on stdout.';
}

/// [bytes] as the text a human can recognize, with everything unprintable
/// replaced — a remote that sent escape sequences must not get to drive the
/// terminal this is printed to. Tabs and newlines are kept: they are what
/// make a banner look like the banner it is.
String _asText(List<int> bytes) => utf8
    .decode(bytes, allowMalformed: true)
    .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), '.')
    .trimRight();

String _indented(String text) =>
    text.split('\n').map((line) => '  $line').join('\n');

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
