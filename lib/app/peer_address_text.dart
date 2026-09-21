import 'package:dsync/dsync_core/models/host_port.dart';
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
/// 1–65535 come back as its [FormatException] with its wording. What is
/// decided outside it — how the one string splits into the two — is
/// [parseHostPort]'s, shared with everything else that reads an authority
/// (task 2b26ac).
///
/// That shared rule is what makes an IPv6 address typable here: `fe80::1`
/// is a host with no port rather than `fe80:` on port `:1`, and
/// `[fe80::1]:28771` is the same host with one. Splitting on the last colon
/// — what this did before — got both wrong.
PeerAddress? parsePeerAddress(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final parsed = parseHostPort(trimmed);
  final port = parsed.port;
  return port == null
      ? PeerAddress(host: parsed.host)
      : PeerAddress(host: parsed.host, port: port);
}
