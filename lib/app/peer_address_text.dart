import 'package:dsync/dsync_core/models/paired_device.dart';

/// `host` or `host:port` as a [PeerAddress] — the one rule the head has for
/// reading an address a user typed (SPEC §4.4's manual re-entry hatch, which
/// exists because there is no mDNS in v1).
///
/// Returns `null` for blank text rather than refusing it: every field that
/// asks for an address has a meaning for "nothing typed" — Run setup's is
/// "dial the cached address", the Device page's is "there is nothing to
/// write" — and which of those it is belongs to the caller, not to the
/// syntax. What is *not* the caller's is what counts as an address, which is
/// why this exists at all.
///
/// The host and port rules are [PeerAddress]'s own, enforced at its
/// construction and never re-checked here: an empty host and a port outside
/// 1–65535 come back as its [FormatException] with its wording. The only
/// rule decided here is "the port is not a number", because the constructor
/// takes an `int` and there is nothing to hand it otherwise.
///
/// The last `:` separates, not the first, so a bare IPv6 host would be
/// misread as `host:port` — the same limit `Location.parse`'s colon rule
/// carries, and the same one this head has shipped with since Run setup's
/// field. Correcting it is a change to make in one place once, which is the
/// point of this function being that place.
PeerAddress? parsePeerAddress(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final colon = trimmed.lastIndexOf(':');
  if (colon < 0) return PeerAddress(host: trimmed);
  final port = int.tryParse(trimmed.substring(colon + 1));
  if (port == null) {
    throw FormatException('Port must be a number: ${trimmed.substring(colon)}');
  }
  return PeerAddress(host: trimmed.substring(0, colon), port: port);
}
