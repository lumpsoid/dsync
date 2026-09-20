/// The one request and one reply `EnrolmentListener` and `enrolWithPeer`
/// exchange once a pairing socket's TLS handshake has completed (SPEC
/// §4.4) — the enrolment protocol's own wire shape, playing the role
/// `control_message.dart` plays for the main agent protocol.
///
/// **Deliberately not `control_message.dart`, and not `FrameCodec`.**
/// [FrameCodec] frames a whole session's worth of `hello`/`scan`/`readFile`
/// traffic behind a `FrameType` that says which of *that* protocol's message
/// kinds a payload is. This protocol is a different, much smaller thing: one
/// request, one reply, one socket, then closed. Reusing `Frame` here would
/// give this protocol's messages the same shape `AgentServer.serve` reads —
/// one accidental `AgentServer().serve(channel, ...)` away from an unpaired
/// peer's enrolment socket actually being reachable through the machinery
/// `d0e960` built to keep it away from. A private four-byte length prefix is
/// a dozen lines and buys a wire shape nothing outside this file can be
/// mistaken for the main protocol's — see `EnrolmentListener`'s class doc
/// comment for the rest of that isolation argument.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// What the client sends once connected (SPEC §4.4): the token as proof it
/// saw the pairing payload, its own identity certificate (PEM — the shape
/// every other model in this project already holds one in), and the name it
/// proposes for this host's paired-device entry.
class EnrolmentRequest {
  final Uint8List token;
  final String certificatePem;
  final String proposedName;

  const EnrolmentRequest({
    required this.token,
    required this.certificatePem,
    required this.proposedName,
  });

  Uint8List encode() => _encodeMessage({
    'token': base64.encode(token),
    'certificatePem': certificatePem,
    'proposedName': proposedName,
  });

  static EnrolmentRequest decode(Uint8List bytes) {
    final json = _decodeMessage(bytes);
    return EnrolmentRequest(
      token: base64.decode(json['token'] as String),
      certificatePem: json['certificatePem'] as String,
      proposedName: json['proposedName'] as String,
    );
  }
}

/// Whether [EnrolmentListener] accepted the [EnrolmentRequest] it just read.
sealed class EnrolmentReply {
  const EnrolmentReply();

  Uint8List encode();

  static EnrolmentReply decode(Uint8List bytes) {
    final json = _decodeMessage(bytes);
    return json['ok'] == true
        ? const EnrolmentAccepted()
        : EnrolmentRefused(json['error'] as String);
  }
}

/// The token, certificate and name were accepted, and a [PairedDevice] was
/// recorded on the listener's side.
class EnrolmentAccepted extends EnrolmentReply {
  const EnrolmentAccepted();

  @override
  Uint8List encode() => _encodeMessage({'ok': true});
}

/// The exchange completed but enrolment did not: a wrong, reused, or expired
/// token, a malformed certificate, or a name that collides with an existing
/// pairing. [reason] is what `EnrolmentListener` actually decided to say —
/// see its class doc comment for why a single generic message covers every
/// way the token gate itself can fail.
class EnrolmentRefused extends EnrolmentReply {
  final String reason;

  const EnrolmentRefused(this.reason);

  @override
  Uint8List encode() => _encodeMessage({'ok': false, 'error': reason});
}

/// Thrown by `enrolWithPeer` when the connection completed but
/// [EnrolmentListener] sent back [EnrolmentRefused] — an application-level
/// decision made over the encrypted channel, never by TLS, so it always
/// surfaces here rather than as a `HandshakeException` from
/// `SecureSocket.connect`.
class EnrolmentRefusedException implements Exception {
  final String reason;

  const EnrolmentRefusedException(this.reason);

  @override
  String toString() => 'Enrolment refused: $reason';
}

Uint8List _encodeMessage(Map<String, dynamic> body) {
  final payload = utf8.encode(jsonEncode(body));
  final out = Uint8List(4 + payload.length);
  ByteData.sublistView(out, 0, 4).setUint32(0, payload.length, Endian.big);
  out.setRange(4, out.length, payload);
  return out;
}

Map<String, dynamic> _decodeMessage(Uint8List bytes) =>
    Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);

/// The largest payload [readEnrolmentMessage] will buffer, in bytes.
///
/// A legitimate enrolment message is a token, a PEM certificate and a name —
/// low tens of kilobytes at the outside — so 1 MiB is orders of magnitude of
/// headroom for anything this protocol will ever legitimately carry. It is a
/// constant rather than a parameter on purpose: the read it guards happens
/// *before* the peer has been authenticated by anything (`EnrolmentListener`
/// leaves `requireClientCertificate` at false, and the token is only checked
/// once a whole message has been read), so there is no caller who has earned
/// the right to raise it and no deployment that needs it raised.
const int maxEnrolmentMessageBytes = 1024 * 1024;

/// Reads exactly one [_encodeMessage]-shaped message off [input], buffering
/// across chunk boundaries — every socket this protocol accepts carries
/// exactly one, so unlike `FrameCodec.decode` this returns a single value
/// rather than a stream, and a plain growable buffer is enough: the largest
/// message either side ever sends is a certificate and a name, not a
/// replica's worth of scan results, so there is nothing here for
/// `FrameCodec`'s in-place-growth optimization to earn back.
///
/// Throws [FormatException] if [input] closes before a complete message has
/// arrived, or if the peer announces or sends more than
/// [maxEnrolmentMessageBytes] — an unauthenticated peer must not be able to
/// make this process buffer arbitrarily much.
Future<Uint8List> readEnrolmentMessage(Stream<Uint8List> input) async {
  final buffered = <int>[];
  await for (final chunk in input) {
    buffered.addAll(chunk);
    if (buffered.length > 4 + maxEnrolmentMessageBytes) {
      throw const FormatException(
        'Enrolment message exceeds $maxEnrolmentMessageBytes bytes',
      );
    }
    if (buffered.length < 4) continue;
    final length = ByteData.sublistView(
      Uint8List.fromList(buffered.sublist(0, 4)),
    ).getUint32(0, Endian.big);
    if (length > maxEnrolmentMessageBytes) {
      throw const FormatException(
        'Enrolment message exceeds $maxEnrolmentMessageBytes bytes',
      );
    }
    if (buffered.length >= 4 + length) {
      return Uint8List.fromList(buffered.sublist(4, 4 + length));
    }
  }
  throw const FormatException(
    'Connection closed before a complete enrolment message arrived',
  );
}
