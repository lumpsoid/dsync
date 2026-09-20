/// What the Pair page's name field arrives filled with (SPEC §4.4: each side
/// names the other for itself, so the name does not have to be agreed —
/// which is exactly why it does not have to be *invented* either).
///
/// The default is read off something that already exists: the far end's own
/// certificate, for the name this device will show it as. Nothing here is
/// authoritative — the value is a starting point in an editable field — so a
/// fact that cannot be read is an empty offer, never a thrown error or a
/// guess dressed up as one.
library;

import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/certificate_fields.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';

/// The name to offer for the *desktop* — what this device will list it as —
/// read out of [payload] itself.
///
/// The subject common name of the certificate the payload carries is the
/// desktop's own host name: `dsync pair show` generates its identity with
/// `commonName: Platform.localHostname`. So the far end has already said
/// what it calls itself, and the field it names is the one the user would
/// otherwise have had to invent a name for.
///
/// Falls back to the payload's address hint — an IP, usually — when the
/// certificate carries no readable name: an address is a poor name but a
/// true one, and both are editable. Takes a decoded payload rather than the
/// line it came from because `PairController.codeEntered` is the one place
/// that decides whether a text is a payload at all, and a second decode
/// here would be a second verdict.
String desktopNameFor(PairingPayload payload) {
  final name = _withoutLocalSuffix(_commonName(payload.certificateDer).trim());
  return name.isEmpty ? payload.address.host : name;
}

/// The certificate's own name, or `''` for bytes that do not parse as one.
/// Broad on purpose: a payload whose base64 decoded but whose certificate is
/// not a certificate fails the handshake with a message that says so, and an
/// unreadable name is not the place to report it.
String _commonName(Uint8List der) {
  try {
    return certificateCommonNameFromDer(der);
  } on Object {
    return '';
  }
}

/// mDNS names arrive as `studio.local`; the suffix is the network's, not the
/// device's.
String _withoutLocalSuffix(String name) =>
    name.length > 6 && name.toLowerCase().endsWith('.local')
    ? name.substring(0, name.length - 6)
    : name;
