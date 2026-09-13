/// Where a [Location]'s agent runs, per SPEC §4.1.
enum Locality { inProcess, remote }

/// A parsed replica location: a local path, `user@host:path`, or `host:path`
/// (SPEC §2).
///
/// Parsed at construction — [FormatException] is thrown for anything else,
/// so an invalid location can never exist downstream.
class Location {
  final String? user;
  final String? host;
  final String path;

  const Location._({this.user, this.host, required this.path});

  /// Splits [raw] into its parts.
  ///
  /// A colon only separates a host from a path when it comes before the first
  /// `/`, the same rule `ssh` and `rsync` use. That is what lets `./log:old`
  /// be a local path while `phone:/sdcard/notes` is a remote one, and it is
  /// why a bare `notes` is a relative path rather than a host with no path.
  factory Location.parse(String raw) {
    if (raw.isEmpty) throw FormatException('Empty location', raw);

    final colonIndex = raw.indexOf(':');
    final slashIndex = raw.indexOf('/');
    final isRemoteForm =
        colonIndex != -1 && (slashIndex == -1 || colonIndex < slashIndex);
    if (!isRemoteForm) return Location._(path: raw);

    final atIndex = raw.indexOf('@');
    final String? user;
    final String hostAndPath;
    if (atIndex != -1 && atIndex < colonIndex) {
      user = raw.substring(0, atIndex);
      hostAndPath = raw.substring(atIndex + 1);
      if (user.isEmpty) throw FormatException('Invalid location', raw);
    } else {
      user = null;
      hostAndPath = raw;
    }

    final separator = hostAndPath.indexOf(':');
    final host = hostAndPath.substring(0, separator);
    final path = hostAndPath.substring(separator + 1);
    if (host.isEmpty || path.isEmpty) {
      throw FormatException('Invalid location', raw);
    }
    return Location._(user: user, host: host, path: path);
  }

  /// [path] with a leading `~` replaced by `HOME` from [environment].
  ///
  /// Shell tilde expansion never happens for a path that reaches the process
  /// quoted or out of a profile file (SPEC §12), so a literal `~` would
  /// otherwise be taken as a directory of that name. Kept out of [parse] and
  /// off the process environment so parsing stays pure and this stays
  /// testable with plain values.
  String expandedPath(Map<String, String> environment) {
    if (path != '~' && !path.startsWith('~/')) return path;
    final home = environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('Cannot expand "$path": HOME is not set');
    }
    return path == '~' ? home : '$home${path.substring(1)}';
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
