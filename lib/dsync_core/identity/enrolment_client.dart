/// The client side of the enrolment exchange (SPEC §4.4): redeems a
/// [PairingPayload] — decoded from a scanned QR or a pasted line of text —
/// against the desktop that produced it, and on success records that
/// desktop as a [PairedDevice] in this host's own [PairedDeviceStore].
///
/// See `EnrolmentListener`'s class doc comment for the connection's TLS
/// shape and why it is not [AgentListener.bindSecure]'s. In short: this
/// connects with [SecureSocket.connect] pinning [PairingPayload]'s
/// certificate — the same byte-exact [onBadCertificate] check
/// `SocketChannel.connectSecure` uses for an already-paired peer, and for
/// the same reason: the certificate travelled inside the payload rather than
/// being taken on faith from whoever answers, so there is no first-use trust
/// to extend. No client certificate is presented at the TLS layer — the
/// listener requests none — so this host's own identity travels only inside
/// the encrypted [EnrolmentRequest], as data, alongside the token.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';

/// Connects to the desktop [payload] describes, presents [ownIdentity] and
/// the token as data over the now-encrypted channel, and — once the far end
/// accepts — records that desktop as a [PairedDevice] named [localName] in
/// [pairedDeviceStore].
///
/// [localName] is what this call records the far end as on this side — a
/// caller-supplied label, the same as any other name [PairedDeviceStore.add]
/// takes, subject to that store's own collision rule.
///
/// This call says nothing about what the far end calls *this* device: that
/// name is the far end's own choice, made where its payload was shown
/// (`EnrolmentListener.bind`'s `peerName`), for the reason
/// [EnrolmentRequest]'s doc comment gives. SPEC §4.4's "device names are
/// local to whichever side chose them" is unchanged — each side names its
/// peer, and neither proposes anything to the other.
///
/// Throws [HandshakeException] if the far end's certificate does not match
/// [payload]'s pin. This is *not* the TLS 1.3 trap
/// `SocketChannel.connectSecure`'s own doc comment describes: that trap is
/// about a *server* rejecting a *client* certificate under
/// `requireClientCertificate: true`, where the client can finish its own
/// side of the handshake before the server's rejection has happened.
/// [EnrolmentListener] requests no client certificate at all, so the only
/// TLS-layer decision in this connection is this side's own pin, made
/// synchronously as part of [SecureSocket.connect] completing — there is
/// nothing here for the asymmetry to apply to.
///
/// Throws [EnrolmentRefusedException] if the connection completes but the
/// far end refuses the token, the certificate, or the name it had already
/// chosen for this device — an application-level decision, so it always
/// surfaces here rather than from [SecureSocket.connect]. Throws [PairedDeviceCollisionException] if
/// [localName] (or the far end's device id) collides with an existing entry
/// in [pairedDeviceStore] — after the far end has already recorded its own
/// side, since only [pairedDeviceStore] knows about a local naming
/// collision, and there is no way to ask it before the exchange that would
/// not also block on a network round trip for a purely local check.
Future<void> enrolWithPeer({
  required PairingPayload payload,
  required DeviceIdentity ownIdentity,
  required String localName,
  required PairedDeviceStore pairedDeviceStore,
}) async {
  final socket = await SecureSocket.connect(
    payload.address.host,
    payload.address.port,
    context: SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(ownIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(ownIdentity.privateKeyPem)),
    onBadCertificate: (certificate) =>
        _sameBytes(certificate.der, payload.certificateDer),
  );

  try {
    socket.add(
      EnrolmentRequest(
        token: payload.token,
        certificatePem: ownIdentity.certificatePem,
      ).encode(),
    );
    await socket.flush();

    switch (EnrolmentReply.decode(await readEnrolmentMessage(socket))) {
      case EnrolmentAccepted():
        break;
      case EnrolmentRefused(:final reason):
        throw EnrolmentRefusedException(reason);
    }
  } finally {
    await socket.close();
    socket.destroy();
  }

  await pairedDeviceStore.add(
    PairedDevice(
      certificatePem: pemEncode('CERTIFICATE', payload.certificateDer),
      name: localName,
      // Empty for the same reason the far end's own record of us starts
      // empty (SPEC §4.4): pairing and authorizing a path are two steps, and
      // this call only performs the first, on both sides.
      agreedReplicaRoots: const {},
      pairedAt: DateTime.now(),
      // The far end's *serving* address, never the enrolment endpoint this
      // call just connected to: that listener is one-shot and on an
      // ephemeral port, so caching it would store an address guaranteed not
      // to answer the next sync — see [PairingPayload.serviceAddress].
      lastKnownAddress: payload.serviceAddress,
    ),
  );
}

/// Byte-exact equality — what [enrolWithPeer]'s pin actually checks, the same
/// helper `socket_channel.dart` and `agent_listener.dart` each keep their own
/// private copy of rather than share, since `Uint8List` and
/// `X509Certificate.der` do not override `==`.
bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
