/// Where a [Location]'s agent runs, per SPEC §4.1.
enum Locality { inProcess, remote }

/// A parsed replica location: a local path, `user@host:path`, or
/// `ssh://[user@]destination:path` (SPEC §2).
///
/// Parsed at construction — [FormatException] is thrown for anything else,
/// so an invalid location can never exist downstream.
class Location {
  /// The prefix that hands the destination to `ssh` unexamined (SPEC §2).
  static const sshScheme = 'ssh://';

  final String? user;

  /// The host, or — under [explicitSsh] — whatever `ssh` is to be given as
  /// its destination: a `~/.ssh/config` alias, `unix/run/ssh-unix-local/socket`,
  /// `.host`, a name that means something only to ssh.
  final String? host;

  final String path;

  /// Whether this location was written in the [sshScheme] form, which says
  /// "this one is for ssh, hands off": [host] is then ssh's own destination
  /// rather than a hostname inferred from the shape of the string, and
  /// [classify] stops inferring locality from it (SPEC §4.1).
  final bool explicitSsh;

  const Location._({
    this.user,
    this.host,
    required this.path,
    this.explicitSsh = false,
  });

  /// Splits [raw] into its parts.
  ///
  /// A colon only separates a host from a path when it comes before the first
  /// `/`, the same rule `ssh` and `rsync` use. That is what lets `./log:old`
  /// be a local path while `phone:/sdcard/notes` is a remote one, and it is
  /// why a bare `notes` is a relative path rather than a host with no path.
  ///
  /// That rule can only describe destinations shaped like a hostname, and
  /// `ssh` reaches plenty that are not. [sshScheme] is the way out: everything
  /// ssh would accept is addressable through it, and nothing about it is
  /// inferred here. See [_parseSshDestination].
  factory Location.parse(String raw) {
    if (raw.isEmpty) throw FormatException('Empty location', raw);
    if (raw.startsWith(sshScheme)) return _parseSshDestination(raw);

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

  /// Splits `ssh://[user@]destination:path`.
  ///
  /// Everything between the scheme and the first `:` is ssh's destination,
  /// verbatim — slashes included, which is the whole point: `unix/...` for a
  /// socket-activated sshd, a `~/.ssh/config` alias, anything ssh's own
  /// argument would accept. A `/` cannot separate the destination from the
  /// path the way a URL would, precisely because the destination may contain
  /// one; the colon can, and is the separator ssh and rsync already use.
  ///
  /// A leading `user@` is still split off, so [user] means the same thing in
  /// both forms — and since [toString] and `sshArgsFor` put it straight back,
  /// the destination ssh is handed is the one that was typed.
  static Location _parseSshDestination(String raw) {
    final rest = raw.substring(sshScheme.length);
    final separator = rest.indexOf(':');
    if (separator == -1) {
      throw FormatException(
        '"$sshScheme" needs a ":" between the ssh destination and the path, '
        'as in "${sshScheme}alias:/srv/notes"',
        raw,
      );
    }

    final destination = rest.substring(0, separator);
    final path = rest.substring(separator + 1);
    final atIndex = destination.indexOf('@');
    final user = atIndex == -1 ? null : destination.substring(0, atIndex);
    final host = destination.substring(atIndex + 1);
    if (host.isEmpty || path.isEmpty || (user != null && user.isEmpty)) {
      throw FormatException('Invalid location', raw);
    }
    return Location._(user: user, host: host, path: path, explicitSsh: true);
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
  ///
  /// An [explicitSsh] location is remote by declaration, and no address is
  /// consulted for it. Inference is exactly what the form opts out of: a
  /// config alias can point anywhere — including back at this machine — and
  /// a unix socket or a `.host` name has no address to compare at all, so
  /// there is nothing here honest enough to guess with. It also makes
  /// "reach this machine through its own ssh" a thing a user can ask for,
  /// rather than something quietly turned back into an in-process run.
  Locality classify({Set<String> localAddresses = const {}}) {
    if (explicitSsh) return Locality.remote;
    final host = this.host;
    if (host == null || host == 'localhost' || localAddresses.contains(host)) {
      return Locality.inProcess;
    }
    return Locality.remote;
  }

  /// Whether [classify] has anything to ask [localAddresses] about.
  ///
  /// False for a bare local path (no host to compare) and for an
  /// [explicitSsh] destination (remote whatever the answer). Callers check
  /// this before paying for the one piece of real I/O the decision would
  /// otherwise cost — `systemLocalAddresses`, and so `NetworkInterface.list()`.
  bool get consultsLocalAddresses => host != null && !explicitSsh;

  /// This location as SPEC §2 spells it, in the form it was parsed from and
  /// with nothing expanded or canonicalized — so a run header showing it
  /// back shows what was typed, and a mistyped location reads as the mistake
  /// it is (SPEC §11.4).
  @override
  String toString() {
    final host = this.host;
    if (host == null) return path;
    final scheme = explicitSsh ? sshScheme : '';
    return '$scheme${user == null ? '' : '$user@'}$host:$path';
  }
}
