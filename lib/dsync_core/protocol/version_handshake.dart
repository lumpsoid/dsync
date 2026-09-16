import 'dart:async';
import 'dart:convert';

import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';

/// The protocol version this build speaks (SPEC §4.2). Bumped whenever the
/// wire format changes in a way older and newer builds can't both handle.
///
/// Still 1, and every wire change so far has left it there — `hello`'s last
/// field addition, `scanEntryToJson`'s `reason`, task 37bf4f renaming `scan`'s
/// `skippedSymlinks` to `skippedPaths`, task 9551c4 respelling a
/// successful `scan` reply as the binary `FrameType.scanResult` (SPEC §15.3),
/// and task 40812e adding `FrameType.heartbeat`.
/// A version exists to protect pairs that cannot be upgraded together, and
/// there are none: no stable release, no users, no deployed agent — the only
/// thing that ever speaks this protocol to itself is the test suite, which is
/// built from this tree. Bumping now would only make this build refuse
/// yesterday's build of itself.
///
/// What a bump is *for*, when there is finally something to protect:
/// **adding** an optional field does not need one, because a peer that omits
/// it decodes to the same absence it would have had anyway. **Renaming or
/// repurposing** a field does, because both directions then decode
/// successfully and silently wrong — the key the peer sent is not the key
/// that is read, so the value is dropped with no error anywhere. 37bf4f's
/// rename is the first change of that second kind; the next one after the
/// first release is the one that has to bump.
///
/// **Respelling a payload** — 9551c4 — is a third kind, and is the *least*
/// in need of a version, not the most: JSON and this protocol's binary cannot
/// be mistaken for each other, so a mismatched pair fails loudly at the first
/// `scan` whatever this constant says. A bump would improve that failure's
/// wording, nothing else, and only for a pair that does not exist yet.
///
/// **Adding a frame type** — 40812e — is a fourth kind, and the one that
/// most looks like it owes a bump: an older peer meeting a
/// `FrameType.heartbeat` type byte does not ignore it, it throws
/// [FrameDecodeException] and takes the session down. It is still not one,
/// for the same reason as the rest — the pair it would protect is the pair
/// that does not exist — and SPEC §4.4 now says so itself rather than being
/// left asserting a rule this deliberately departs from.
const protocolVersion = 1;

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
/// §11.5 exit 3) — if the versions differ. Throws
/// [PeerNotSpeakingProtocolException] if what arrives is not frames at all.
/// Throws [StateError] if the channel closes before the peer's version
/// arrives.
Future<void> performVersionHandshake(
  Channel channel,
  StreamIterator<Frame> frames,
) async {
  await channel.send(FrameCodec().encode(_versionFrame(protocolVersion)));

  final Frame? reply;
  try {
    reply = await nextMeaningfulFrame(frames);
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
  if (reply == null) {
    throw StateError('Channel closed before version handshake completed');
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
