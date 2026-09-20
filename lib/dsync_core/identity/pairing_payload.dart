/// What a QR — or a pasted line of text, for the camera-less
/// desktop-to-server case (SPEC §4.4) — carries to start a pairing: the
/// enrolling host's own identity certificate, where its enrolment listener
/// and its serving listener each answer, and a single-use, time-bounded
/// enrolment token.
///
/// **Pure, and separate from the connection that consumes it.** Encoding and
/// decoding this is parsing, nothing more: no socket, no store, no clock.
/// `EnrolmentListener` builds a value of this type to hand to whatever
/// renders it (a QR image, or the text itself — both the head's job, not
/// this file's); `enrolWithPeer` takes one, decoded from whichever the user
/// scanned or pasted, and does the actual connecting.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/paired_device.dart';

/// Recognizes this payload's text encoding before a single byte of the
/// payload itself is touched — see [PairingPayload.decode].
const _magic = 'dsync-pair';

/// Bumped when the binary layout [PairingPayload.encode] writes changes. A
/// payload whose text names a different version is a build speaking a
/// different shape, not a corrupt one — see [PairingPayload.decode].
const _version = 2;

/// One pairing invitation (SPEC §4.4): the DER of the host's identity
/// certificate, the enrolment endpoint to redeem it against, the address a
/// later sync should dial, and the enrolment token that proves the bearer
/// saw this payload.
///
/// Nothing here is secret. The certificate is a trust anchor, public by
/// nature (SPEC §4.4); the token is short-lived, single-use, and meaningless
/// without a live listener to present it to (`EnrolmentListener`) — what
/// keeps pairing safe is that gate, not keeping this payload's bytes hidden.
class PairingPayload {
  /// The enrolling host's identity certificate, as raw DER — what becomes
  /// the trust anchor a `peer://` dial and `AgentListener.bindSecure`
  /// install, the same derivation [PairedDevice.certificateDer] and
  /// `DeviceIdentity.certificateDer` use. Carried as DER rather than PEM: PEM
  /// is itself base64 text, and this whole payload is base64 again below —
  /// encoding a PEM string here would base64 the certificate twice for no
  /// reader that wants the PEM framing itself, just to spend roughly a third
  /// more of an already-user-facing string. `enrolWithPeer` re-wraps it as
  /// PEM (`pemEncode`) only once it actually needs to store a
  /// [PairedDevice], which is the one place PEM is the required shape.
  final Uint8List certificateDer;

  /// Where the enrolment listener this payload came from is answering —
  /// the one connection `enrolWithPeer` makes, and nothing beyond it. That
  /// listener is one-shot and bound on an ephemeral port (`dsync pair
  /// show`), so this address is *not* what a later sync dials: see
  /// [serviceAddress].
  final PeerAddress address;

  /// Where that same host's paired-replica listener answers (`dsync agent
  /// --serve`) — the seed for the paired-device store's last-known-address
  /// cache once pairing succeeds (SPEC §4.4's address hint).
  ///
  /// **Carried separately from [address] because the two ports are never
  /// the same number.** The enrolment listener exists only for the duration
  /// of one pairing and takes whatever ephemeral port the OS hands it;
  /// seeding the cache from that port guarantees a stored address that
  /// cannot be dialed, so the first sync after every pairing failed until
  /// the user edited the port by hand. The serving side is the only one that
  /// knows which port it serves on — it may not be the default — so it says
  /// so here rather than leaving the far end to assume.
  final PeerAddress serviceAddress;

  /// The single-use, time-bounded enrolment token (SPEC §4.4): proof the
  /// bearer saw this payload, not a credential good for anything past the one
  /// connection that redeems it.
  final Uint8List token;

  PairingPayload({
    required this.certificateDer,
    required this.address,
    required int servicePort,
    required this.token,
  }) : serviceAddress = PeerAddress(host: address.host, port: servicePort) {
    if (certificateDer.isEmpty) {
      throw const FormatException('Empty certificate');
    }
    if (token.isEmpty) {
      throw const FormatException('Empty token');
    }
  }

  /// One line of ASCII text: `dsync-pair:v2:<base64>`.
  ///
  /// **Why one base64 run behind a bare text prefix, and not a QR-specific
  /// shape.** SPEC §4.4 is explicit that pairing a desktop with a headless
  /// server — neither end with a camera — goes through text, not an image,
  /// and that this is the *primary* path for that case, not a fallback,
  /// since `dsync pair` has to accept the same string pasted into a
  /// terminal. Whatever a QR encodes is only ever this string turned into a
  /// scannable image by the head that renders it, which owns that step, not
  /// this file. A single base64 run has no embedded newlines to break when a
  /// terminal wraps it and nothing shell-special to escape when it is pasted
  /// as an argument; the `dsync-pair:v2:` prefix is plain ASCII a human can
  /// recognize on sight and a `grep` can find, and gives [decode] a version
  /// to reject on a bare string compare before it has parsed a single byte
  /// of the payload proper.
  String encode() => '$_magic:v$_version:${base64.encode(_encodeBytes(this))}';

  /// The inverse of [encode]. Throws [FormatException] — never a partially
  /// built [PairingPayload] — for anything that is not exactly this shape:
  /// wrong prefix, wrong version, invalid base64, or a payload truncated
  /// inside the base64.
  static PairingPayload decode(String text) {
    final parts = text.trim().split(':');
    if (parts.length != 3 || parts[0] != _magic) {
      throw FormatException('Not a dsync pairing payload: "$text"');
    }
    if (parts[1] != 'v$_version') {
      throw FormatException(
        'Unsupported pairing payload version "${parts[1]}" — this build '
        'speaks v$_version',
      );
    }

    final Uint8List bytes;
    try {
      bytes = base64.decode(parts[2]);
    } on FormatException catch (e) {
      throw FormatException('Pairing payload is not valid base64: $e');
    }
    return _decodeBytes(bytes);
  }
}

/// ```text
/// [u16 certificateLength][certificate DER]
/// [u8 hostLength][host UTF-8]
/// [u16 port]
/// [u16 servicePort]
/// [u8 tokenLength][token bytes]
/// ```
///
/// Flat and length-prefixed, the same shape `scan_result_codec.dart` uses for
/// the same reason: a reader can see the whole layout at a glance. There is
/// no varint-packing or growable-buffer machinery that file also has,
/// because there is nothing here to amortize — one certificate, one host,
/// one token, never a list of either.
Uint8List _encodeBytes(PairingPayload payload) {
  final host = utf8.encode(payload.address.host);
  final certificate = payload.certificateDer;
  final token = payload.token;

  // Headroom this project's own data never approaches — a P-256 self-signed
  // certificate is a few hundred bytes, a hostname is well under 255
  // characters, and the token below is 16 — so a value that trips this is a
  // caller handing this class something it was never meant to encode, not a
  // limit real pairing traffic could ever reach.
  if (certificate.length > 0xFFFF) {
    throw ArgumentError(
      'Certificate too large to encode: ${certificate.length} bytes',
    );
  }
  if (host.length > 0xFF) {
    throw ArgumentError('Host too long to encode: ${payload.address.host}');
  }
  if (token.length > 0xFF) {
    throw ArgumentError('Token too long to encode: ${token.length} bytes');
  }

  final writer = BytesBuilder();
  writer
    ..add(_uint16(certificate.length))
    ..add(certificate)
    ..addByte(host.length)
    ..add(host)
    ..add(_uint16(payload.address.port))
    ..add(_uint16(payload.serviceAddress.port))
    ..addByte(token.length)
    ..add(token);
  return writer.toBytes();
}

PairingPayload _decodeBytes(Uint8List bytes) {
  final reader = _ByteReader(bytes);
  final certificate = reader.bytes(reader.uint16());
  final host = utf8.decode(reader.bytes(reader.uint8()));
  final port = reader.uint16();
  final servicePort = reader.uint16();
  final token = reader.bytes(reader.uint8());
  return PairingPayload(
    certificateDer: certificate,
    address: PeerAddress(host: host, port: port),
    servicePort: servicePort,
    token: token,
  );
}

Uint8List _uint16(int value) {
  final bytes = Uint8List(2);
  ByteData.sublistView(bytes).setUint16(0, value, Endian.big);
  return bytes;
}

/// A bounds-checked cursor over [_decodeBytes]'s input — every read is
/// checked against what is actually left rather than trusted to
/// [ByteData]'s own `RangeError`, the same property `scan_result_codec.dart`'s
/// own reader has, for the same reason: a truncated payload is a peer's (or a
/// fat-fingered paste's) fault, and [FormatException] is what [decode]
/// promises to throw for it, not whatever `RangeError` happens to say.
class _ByteReader {
  final Uint8List _bytes;
  final ByteData _view;
  int _offset = 0;

  _ByteReader(this._bytes) : _view = ByteData.sublistView(_bytes);

  int uint8() => _bytes[_take(1)];

  int uint16() => _view.getUint16(_take(2), Endian.big);

  Uint8List bytes(int length) {
    final start = _take(length);
    return _bytes.sublist(start, start + length);
  }

  int _take(int count) {
    final start = _offset;
    if (count < 0 || start + count > _bytes.length) {
      throw const FormatException('Pairing payload is truncated');
    }
    _offset = start + count;
    return start;
  }
}
