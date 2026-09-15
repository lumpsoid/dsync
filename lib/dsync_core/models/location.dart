/// Where a [Location]'s agent runs, per SPEC §4.1.
enum Locality { inProcess, remote }

/// How a [Location] names the transport that reaches its replica (SPEC §2,
/// §4.2).
///
/// A scheme is an explicit "hands off, this one is for that transport": it
/// takes the destination out of the colon-before-slash rule that can only
/// describe hostname-shaped strings, and it takes locality out of inference
/// (see [Location.classify]). Which is why only the schemeless form ever
/// consults this machine's addresses.
enum LocationScheme {
  /// No scheme: a bare local path, or `user@host:path`. The only form whose
  /// locality is inferred (SPEC §4.1), and the only one whose remote case is
  /// reached over `ssh` without having said so.
  inferred(''),

  /// `ssh://[user@]destination:path` — everything between the scheme and the
  /// first `:` is handed to `ssh` as its destination, verbatim (SPEC §2).
  ssh('ssh://'),

  /// `unix://<socket-path>:<replica-path>` — everything between the scheme
  /// and the first `:` is the path of a unix socket a `dsync agent --listen`
  /// is already bound to (SPEC §2, §4.2).
  unix('unix://');

  const LocationScheme(this.prefix);

  /// The literal prefix a location of this scheme is written with — empty
  /// for [inferred], which has none.
  final String prefix;
}

/// A parsed replica location: a local path, `user@host:path`,
/// `ssh://[user@]destination:path`, or `unix://<socket-path>:<replica-path>`
/// (SPEC §2).
///
/// Parsed at construction — [FormatException] is thrown for anything else,
/// so an invalid location can never exist downstream.
class Location {
  final String? user;

  /// Where the agent for this location is, in whatever terms [scheme] means
  /// it:
  /// - [LocationScheme.inferred] — the host, compared against this machine's
  ///   own addresses by [classify];
  /// - [LocationScheme.ssh] — whatever `ssh` is to be given as its
  ///   destination: a `~/.ssh/config` alias, `unix/run/ssh-unix-local/socket`,
  ///   `.host`, a name that means something only to ssh;
  /// - [LocationScheme.unix] — the filesystem path of the socket to connect
  ///   to, also reachable as [socketPath].
  ///
  /// One field rather than one per scheme: every non-local location has
  /// exactly one "where", and [scheme] already says how to read it. A second
  /// nullable field per transport would make "both set" and "neither set"
  /// representable and meaningless.
  ///
  /// `null` only for a bare local path, which is what [classify] reads as
  /// in-process.
  final String? host;

  final String path;

  /// Which of SPEC §2's forms this location was written in.
  final LocationScheme scheme;

  const Location._({
    this.user,
    this.host,
    required this.path,
    this.scheme = LocationScheme.inferred,
  });

  /// Splits [raw] into its parts.
  ///
  /// A colon only separates a host from a path when it comes before the first
  /// `/`, the same rule `ssh` and `rsync` use. That is what lets `./log:old`
  /// be a local path while `phone:/sdcard/notes` is a remote one, and it is
  /// why a bare `notes` is a relative path rather than a host with no path.
  ///
  /// That rule can only describe destinations shaped like a hostname, and a
  /// transport reaches plenty that are not — `ssh` a config alias or a
  /// socket-activated sshd, a listening agent a filesystem path. A
  /// [LocationScheme] prefix is the way out, and nothing about what follows
  /// one is inferred here. See [_parseSshDestination] and [_parseUnixSocket].
  factory Location.parse(String raw) {
    if (raw.isEmpty) throw FormatException('Empty location', raw);
    if (raw.startsWith(LocationScheme.ssh.prefix)) {
      return _parseSshDestination(raw);
    }
    if (raw.startsWith(LocationScheme.unix.prefix)) {
      return _parseUnixSocket(raw);
    }

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
    final rest = raw.substring(LocationScheme.ssh.prefix.length);
    final separator = rest.indexOf(':');
    if (separator == -1) {
      throw FormatException(
        '"${LocationScheme.ssh.prefix}" needs a ":" between the ssh '
        'destination and the path, as in '
        '"${LocationScheme.ssh.prefix}alias:/srv/notes"',
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
    return Location._(
      user: user,
      host: host,
      path: path,
      scheme: LocationScheme.ssh,
    );
  }

  /// Splits `unix://<socket-path>:<replica-path>`.
  ///
  /// The same first-colon rule [_parseSshDestination] uses, for the same
  /// reason and then some: both halves here are filesystem paths full of
  /// slashes, so a `/` could not possibly separate them. A socket path that
  /// itself contains a `:` is therefore not addressable — the same limit the
  /// `ssh://` destination has had since SPEC §2, and the price of one rule
  /// instead of two.
  ///
  /// No `user@` is split off, unlike [_parseSshDestination]: there is no user
  /// to name. Connecting is gated by whether this process can open the socket
  /// at all, which is the filesystem's answer and not a credential anyone
  /// types (SPEC §4.2) — so an `@` anywhere in the socket path is just a
  /// character in a path.
  ///
  /// The socket path is used exactly as written, with no `~` or `$VAR`
  /// expansion: a shell already expands an unquoted `~`, and the paths this
  /// form is for (`$XDG_RUNTIME_DIR/...`) are absolute. A profile (SPEC §12)
  /// has to spell it out.
  static Location _parseUnixSocket(String raw) {
    final rest = raw.substring(LocationScheme.unix.prefix.length);
    final separator = rest.indexOf(':');
    if (separator == -1) {
      throw FormatException(
        '"${LocationScheme.unix.prefix}" needs a ":" between the socket path '
        'and the replica path, as in '
        '"${LocationScheme.unix.prefix}/run/user/1000/dsync.sock:/srv/notes"',
        raw,
      );
    }

    final socketPath = rest.substring(0, separator);
    final path = rest.substring(separator + 1);
    if (socketPath.isEmpty || path.isEmpty) {
      throw FormatException('Invalid location', raw);
    }
    return Location._(
      host: socketPath,
      path: path,
      scheme: LocationScheme.unix,
    );
  }

  /// The unix socket a `dsync agent --listen` is serving this replica on, or
  /// `null` when this location is not a `unix://` one (SPEC §2, §4.2).
  String? get socketPath => scheme == LocationScheme.unix ? host : null;

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
  /// A location with a [scheme] is remote by declaration, and no address is
  /// consulted for it. Inference is exactly what a scheme opts out of: an ssh
  /// config alias can point anywhere — including back at this machine — and
  /// neither an ssh unix destination, a `.host` name, nor a socket path has
  /// an address to compare at all, so there is nothing here honest enough to
  /// guess with. It also makes "reach this machine through its own ssh"
  /// — or through a listening agent of its own — a thing a user can ask for,
  /// rather than something quietly turned back into an in-process run.
  Locality classify({Set<String> localAddresses = const {}}) {
    if (scheme != LocationScheme.inferred) return Locality.remote;
    final host = this.host;
    if (host == null || host == 'localhost' || localAddresses.contains(host)) {
      return Locality.inProcess;
    }
    return Locality.remote;
  }

  /// Whether [classify] has anything to ask [localAddresses] about.
  ///
  /// False for a bare local path (no host to compare) and for any location
  /// with a [scheme] (remote whatever the answer). Callers check this before
  /// paying for the one piece of real I/O the decision would otherwise cost —
  /// `systemLocalAddresses`, and so `NetworkInterface.list()`.
  bool get consultsLocalAddresses =>
      host != null && scheme == LocationScheme.inferred;

  /// This location as SPEC §2 spells it, in the form it was parsed from and
  /// with nothing expanded or canonicalized — so a run header showing it
  /// back shows what was typed, and a mistyped location reads as the mistake
  /// it is (SPEC §11.4).
  @override
  String toString() {
    final host = this.host;
    if (host == null) return path;
    return '${scheme.prefix}${user == null ? '' : '$user@'}$host:$path';
  }
}
