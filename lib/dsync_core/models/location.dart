/// Where a [Location]'s agent runs, per SPEC §4.1.
enum Locality { inProcess, remote }

/// A parsed replica location: `/abs/path`, `user@host:path`, or `host:path`.
///
/// Parsed at construction — [FormatException] is thrown for anything else,
/// so an invalid location can never exist downstream.
class Location {
  final String? user;
  final String? host;
  final String path;

  const Location._({this.user, this.host, required this.path});

  factory Location.parse(String raw) {
    if (raw.startsWith('/')) {
      return Location._(path: raw);
    }

    final atIndex = raw.indexOf('@');
    if (atIndex != -1) {
      final user = raw.substring(0, atIndex);
      final hostAndPath = raw.substring(atIndex + 1);
      final colonIndex = hostAndPath.indexOf(':');
      if (user.isEmpty || colonIndex == -1) {
        throw FormatException('Invalid location', raw);
      }
      final host = hostAndPath.substring(0, colonIndex);
      final path = hostAndPath.substring(colonIndex + 1);
      if (host.isEmpty || path.isEmpty) {
        throw FormatException('Invalid location', raw);
      }
      return Location._(user: user, host: host, path: path);
    }

    final colonIndex = raw.indexOf(':');
    if (colonIndex != -1) {
      final host = raw.substring(0, colonIndex);
      final path = raw.substring(colonIndex + 1);
      if (host.isEmpty || path.isEmpty) {
        throw FormatException('Invalid location', raw);
      }
      return Location._(host: host, path: path);
    }

    throw FormatException('Invalid location', raw);
  }

  /// Classifies where the agent for this location runs, per SPEC §4.1.
  ///
  /// [localAddresses] is the set of addresses that resolve to this machine.
  /// Fetching that set is I/O and is the caller's job; this method only
  /// decides from facts already in hand.
  Locality classify({Set<String> localAddresses = const {}}) {
    final host = this.host;
    if (host == null || host == 'localhost' || localAddresses.contains(host)) {
      return Locality.inProcess;
    }
    return Locality.remote;
  }
}
