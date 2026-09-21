/// The one place `host:port` is turned into text and read back out of it,
/// and the one place a host literal is normalized (task 2b26ac).
///
/// **Why a shared file rather than a fix per site.** An IPv6 literal already
/// contains colons, so `'$host:$port'` produces `fe80::1:28771` — which is
/// not a bracketed authority, and which anything splitting on the last colon
/// reads back as the host `fe80::1` on port `28771` only by accident, and as
/// garbage the moment the literal ends in a group that is not a port. Every
/// site that formats or parses one had its own copy of that bug; this file
/// is what they call instead.
///
/// **Pure.** No socket, no clock, no interfaces — [InternetAddress] here is
/// a parsed literal, not a resolution. That is what lets the bind-address
/// rule and the advertised-address rule be tested with plain strings.
library;

import 'dart:io';

/// `host:port` as text, bracketing [host] when it is an IPv6 literal
/// (RFC 3986 §3.2.2) so the result can be read back by [parseHostPort] and
/// pasted into anything that takes an authority.
String formatHostPort(String host, int port) =>
    host.contains(':') ? '[$host]:$port' : '$host:$port';

/// `host`, `host:port`, `[v6]` or `[v6]:port` split into its parts, with
/// `port` `null` when the text carried none.
///
/// A bare, unbracketed IPv6 literal (`fe80::1`) is read as a host with no
/// port rather than as `fe80:` on port `:1`: more than one colon and no
/// brackets cannot be an authority with a port, so the whole string is the
/// host. That is the case the old "split on the last colon" rule got wrong.
///
/// Throws [FormatException] for a bracketed host with no closing bracket, a
/// bracketed host followed by anything other than `:port`, or a port that is
/// not a number. Whether an empty host or an out-of-range port is acceptable
/// is the caller's rule — [PeerAddress] has its own and enforces it at
/// construction — so it is not re-decided here.
({String host, int? port}) parseHostPort(String text) {
  final trimmed = text.trim();
  if (trimmed.startsWith('[')) {
    final close = trimmed.indexOf(']');
    if (close < 0) {
      throw FormatException('Unclosed "[" in address: "$text"');
    }
    final host = trimmed.substring(1, close);
    final rest = trimmed.substring(close + 1);
    if (rest.isEmpty) return (host: host, port: null);
    if (!rest.startsWith(':')) {
      throw FormatException('Expected ":port" after "]" in address: "$text"');
    }
    return (host: host, port: _parsePort(rest.substring(1)));
  }
  final colon = trimmed.indexOf(':');
  if (colon < 0) return (host: trimmed, port: null);
  // Two or more colons and no brackets: an IPv6 literal, whole.
  if (trimmed.indexOf(':', colon + 1) >= 0) {
    return (host: trimmed, port: null);
  }
  return (
    host: trimmed.substring(0, colon),
    port: _parsePort(trimmed.substring(colon + 1)),
  );
}

int _parsePort(String text) {
  final port = int.tryParse(text);
  if (port == null) throw FormatException('Port must be a number: "$text"');
  return port;
}

/// [host] with an IPv4-mapped IPv6 literal (`::ffff:a.b.c.d`) reduced to the
/// plain IPv4 form it names, and anything else returned unchanged.
///
/// **Why this exists.** A listener bound to `::` is dual-stack
/// (`ServerSocket.bind` defaults `v6Only` to false), so an IPv4 peer arrives
/// with `socket.remoteAddress` reading `::ffff:192.168.1.5`. Recorded as a
/// peer's `lastKnownAddress` that is the same host said in a shape the user
/// does not recognize in `dsync pair list`, that compares unequal to the
/// address they would type themselves, and that a v6-less host cannot dial
/// back at all. Normalizing where the value is *constructed* — see
/// [PeerAddress] — means nothing downstream has to know the shape exists.
String normalizedHost(String host) {
  const prefix = '::ffff:';
  if (host.length <= prefix.length) return host;
  if (host.substring(0, prefix.length).toLowerCase() != prefix) return host;
  final mapped = host.substring(prefix.length);
  // Only the dotted-quad spelling. `::ffff:c0a8:105` is the same address in
  // hex groups, but it is already a legitimate IPv6 literal that no library
  // prints for a v4-mapped peer, and rewriting it would be guessing.
  final address = InternetAddress.tryParse(mapped);
  if (address == null) return host;
  return address.type == InternetAddressType.IPv4 ? mapped : host;
}

/// [text] as an address a listener can bind, for `--bind` (task 2b26ac).
///
/// A literal only, bracketed or bare — never a hostname. A name would have
/// to be resolved to be bound, may resolve to several addresses or to a
/// different one later, and "which of those did it actually bind" is
/// exactly the question an operator reaching for `--bind` is trying to stop
/// asking.
///
/// Throws [FormatException] naming the value, so the caller can fail loudly
/// with something actionable rather than binding somewhere else.
InternetAddress parseBindAddress(String text) {
  final trimmed = text.trim();
  final bare = trimmed.startsWith('[') && trimmed.endsWith(']')
      ? trimmed.substring(1, trimmed.length - 1)
      : trimmed;
  final address = InternetAddress.tryParse(bare);
  if (address == null) {
    throw FormatException(
      '"$text" is not an IP address. Give an address literal this machine '
      'has — 0.0.0.0 for every IPv4 interface, :: for every interface of '
      'either family, or one interface\'s own address — not a hostname.',
    );
  }
  return address;
}

/// Whether [address] is a wildcard — `0.0.0.0` or `::`, "every interface".
///
/// The one thing that cannot be advertised to a peer: it says where this
/// host listens, not where the peer should dial.
bool isWildcardAddress(InternetAddress address) =>
    address.address == InternetAddress.anyIPv4.address ||
    address.address == InternetAddress.anyIPv6.address;
