import 'package:dsync/dsync_core/models/location.dart';

import 'cli_options_error.dart';

/// What a `sync`/`status` invocation runs against (SPEC §11.1): either a
/// named profile, or — `sync` only — an ad-hoc pair of locations typed
/// directly on the command line.
///
/// A sum type rather than a nullable profile name paired with a nullable
/// location pair, per this project's code principles: with two nullable
/// fields, "both set" and "both null" are representable and meaningless.
/// Here, exactly one of [ProfileTarget] or [AdHocTarget] exists at a time.
sealed class SyncTarget {
  const SyncTarget();

  /// Resolves `sync`'s positional arguments to a target (SPEC §11.1): one
  /// positional names a profile, two parse as an ad-hoc pair, anything else
  /// is a bad argument list. `status <profile>` does not use this — it only
  /// ever takes a single profile name, see [ProfileTarget.fromStatusPositionals].
  factory SyncTarget.fromPositionals(List<String> positionals) {
    switch (positionals.length) {
      case 1:
        return ProfileTarget(positionals.single);
      case 2:
        return AdHocTarget.parse(positionals[0], positionals[1]);
      default:
        throw CliOptionsError(
          'sync takes a profile name, or two locations — got '
          '${positionals.length} argument(s)',
        );
    }
  }
}

/// `sync <profile>` / `status <profile>` (SPEC §11.1): run against a named
/// profile loaded from `$XDG_CONFIG_HOME/dsync/profiles/<name>.toml` (SPEC
/// §12). Loading that file is a separate task (50867a); this only carries
/// the name.
class ProfileTarget extends SyncTarget {
  final String name;

  const ProfileTarget(this.name);

  /// Resolves `status`'s positional arguments (SPEC §11.1): exactly one
  /// profile name. Unlike [SyncTarget.fromPositionals], `status` has no
  /// ad-hoc two-location form.
  factory ProfileTarget.fromStatusPositionals(List<String> positionals) {
    if (positionals.length != 1) {
      throw CliOptionsError(
        'status takes exactly one profile name — got '
        '${positionals.length} argument(s)',
      );
    }
    return ProfileTarget(positionals.single);
  }
}

/// `sync <locA> <locB>` (SPEC §11.1): run against two locations typed
/// directly, with no profile.
class AdHocTarget extends SyncTarget {
  final Location locationA;
  final Location locationB;

  const AdHocTarget._(this.locationA, this.locationB);

  /// Parses and validates an ad-hoc pair.
  ///
  /// Three rules live here because they are entirely about these two
  /// locations and nothing else (SPEC §11.5, and task 867af9's DECIDED
  /// "local first"):
  /// - either location can fail to parse as a [Location] at all;
  /// - in a mixed pair (one local, one remote), the remote one cannot come
  ///   first — there is exactly one legal spelling, so argument order is
  ///   already canonical and nothing gets silently reordered;
  /// - the two locations cannot be the same one twice (a no-op sync of a
  ///   replica against itself).
  ///
  /// Locality is decided with [Location.classify]'s default (empty)
  /// `localAddresses`: at parse time, before any network resolution has run,
  /// a host that is present and is not `localhost` is remote enough (SPEC
  /// §4.1's fuller resolution — against this machine's actual addresses —
  /// is a later task's job, not a parse-time one).
  factory AdHocTarget.parse(String rawA, String rawB) {
    final Location locationA;
    final Location locationB;
    try {
      locationA = Location.parse(rawA);
      locationB = Location.parse(rawB);
    } on FormatException catch (error) {
      throw CliOptionsError(error.message);
    }

    if (locationA.classify() == Locality.remote &&
        locationB.classify() == Locality.inProcess) {
      throw CliOptionsError(
        'put the local path first: "$rawA" is remote and "$rawB" is local',
      );
    }

    if (_sameLocation(locationA, locationB)) {
      throw CliOptionsError(
        'the two locations are the same: "$rawA" and "$rawB"',
      );
    }

    return AdHocTarget._(locationA, locationB);
  }
}

/// Whether [a] and [b] denote the same location, for rejecting a
/// self-sync pair (SPEC §11.5).
///
/// Syntactic only — this task has no filesystem access, so it cannot expand
/// `~`, resolve a relative path against the working directory, or follow a
/// symlink. It catches the literal case (the same argument typed twice, with
/// or without a trailing slash). Canonicalizing against the filesystem for
/// same-locality pairs that merely *look* different is task 603ea7's job,
/// once a profile's real roots are in hand.
bool _sameLocation(Location a, Location b) {
  return a.user == b.user &&
      a.host == b.host &&
      _withoutTrailingSlash(a.path) == _withoutTrailingSlash(b.path);
}

String _withoutTrailingSlash(String path) {
  if (path.length > 1 && path.endsWith('/')) {
    return path.substring(0, path.length - 1);
  }
  return path;
}
