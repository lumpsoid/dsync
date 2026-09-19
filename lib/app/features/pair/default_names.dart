/// What the Pair page's two name fields arrive filled with (SPEC §4.4: each
/// side names the other for itself, so neither name has to be agreed — which
/// is exactly why neither has to be *invented* either).
///
/// Both defaults are read off something that already exists: this device's
/// own host name for the name the desktop will show, and the far end's own
/// certificate for the name this device will show it as. Nothing here is
/// authoritative — every value is a starting point in an editable field —
/// so a fact that cannot be read is an empty offer, never a thrown error or
/// a guess dressed up as one.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/certificate_fields.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';

/// The name to offer for *this* device — what the desktop will list it as.
///
/// `Platform.localHostname` first, which is what `dsync pair accept`
/// defaults its `--as` to (`lib/cli/commands/pair_accept_command.dart`), so
/// a phone and a laptop pairing with the same desktop name themselves the
/// same way. The one edge is Android, where the host name is `localhost` for
/// every device and therefore names nothing; there the OS is the most this
/// build can say without a new dependency, and the user renames it if they
/// have two.
///
/// Reads the platform at this one edge and hands a plain value down, the way
/// `hostPlatform()` does for the CLI: [defaultThisDeviceName] is the rule,
/// testable with plain strings.
String defaultThisDeviceName() {
  String hostname;
  try {
    hostname = Platform.localHostname;
  } on Object {
    // A host with no name to give. There is still an OS to fall back to.
    hostname = '';
  }
  return thisDeviceNameFor(
    hostname: hostname,
    operatingSystem: Platform.operatingSystem,
  );
}

/// [defaultThisDeviceName]'s rule over plain values.
String thisDeviceNameFor({
  required String hostname,
  required String operatingSystem,
}) {
  final host = _withoutLocalSuffix(hostname.trim());
  // `localhost` is the answer every Android device gives, and a name that
  // every device shares is not a name.
  if (host.isNotEmpty && host.toLowerCase() != 'localhost') return host;
  return switch (operatingSystem) {
    'android' => 'Android device',
    'ios' => 'iOS device',
    _ => operatingSystem,
  };
}

/// The name to offer for the *desktop* — what this device will list it as —
/// read out of [payloadText] itself, or `null` while there is no payload to
/// read it out of.
///
/// The subject common name of the certificate the payload carries is the
/// desktop's own host name: `dsync pair show` generates its identity with
/// `commonName: Platform.localHostname`. So the far end has already said
/// what it calls itself, and the field it names is the one the user would
/// otherwise have had to invent a name for.
///
/// Falls back to the payload's address hint — an IP, usually — when the
/// certificate carries no readable name: an address is a poor name but a
/// true one, and both are editable. Nothing here validates the payload;
/// `PairController.submitPayload` is the one place that decides whether a
/// payload is usable, and this stays silent (`null`) about every text it
/// cannot read rather than rendering a verdict of its own.
String? desktopNameFromPayload(String payloadText) {
  final PairingPayload payload;
  try {
    payload = PairingPayload.decode(payloadText);
  } on FormatException {
    return null;
  }
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
