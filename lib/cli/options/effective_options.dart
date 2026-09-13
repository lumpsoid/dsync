import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dsync/cli/profile/profile.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';

import 'cli_options.dart';
import 'cli_options_error.dart';
import 'sync_target.dart';

/// What one `sync`/`status` run needs, after command-line flags and (for a
/// profile run) a loaded [Profile] have been folded into a single set of
/// facts (SPEC §12: "Command-line flags override profile options. `ignore`
/// is additive.").
///
/// Built by [EffectiveOptions.forProfile] or [EffectiveOptions.forAdHoc] —
/// whichever matches [CliOptions.target] — never by the plain constructor,
/// which only assembles already-decided fields. Both factories are pure
/// functions over plain values: no filesystem access, so both are testable
/// with hand-built [Profile]/[CliOptions]/[AdHocTarget] values, a plain
/// `Map<String, String>` standing in for the process environment, and a
/// plain `String?` standing in for the process's current working
/// directory — neither factory ever calls `Directory.current` or touches
/// the filesystem itself; a caller that wants relative local paths resolved
/// passes that value in.
///
/// [warnSizeBytes] and [jobs] stay nullable after the merge: SPEC §10's
/// size warning is optional, and the scanner's own default job count
/// applies when neither a flag nor a profile sets one (see `Scanner.jobs`)
/// — this object folds two optional sources together but does not invent a
/// third default of its own. [a], [b], [rules], and [profileId] are always
/// present.
class EffectiveOptions {
  /// Replica `a`. For [forProfile] this is exactly `profile.a` — a
  /// profile's replica order is never touched. For [forAdHoc] this is
  /// whichever of the typed pair sorts first under the ad-hoc "local first,
  /// then lexicographic" order (see [forAdHoc]).
  final Location a;

  /// Replica `b`. See [a].
  final Location b;

  /// `ignore`/`follow` rules (SPEC §9), with `--ignore` folded in
  /// additively via [RuleSet.mergedWith] rather than replacing whatever a
  /// profile already set (SPEC §12).
  final RuleSet rules;

  /// SPEC §10's warning threshold: `--warn-size` if given, else a
  /// profile's `warn_size_bytes`, else `null` (no warning configured).
  final int? warnSizeBytes;

  /// Hash concurrency: `--jobs` if given, else a profile's `jobs`, else
  /// `null` (the scanner's own default applies).
  final int? jobs;

  /// Keys this run's archive and lock files (SPEC §8.1, §8.3): a profile's
  /// name for [forProfile], or `adhoc-<16 hex>` for [forAdHoc].
  final String profileId;

  const EffectiveOptions({
    required this.a,
    required this.b,
    required this.rules,
    required this.warnSizeBytes,
    required this.jobs,
    required this.profileId,
  });

  /// Merges a loaded [profile] with [options] (SPEC §12).
  ///
  /// [profile]'s `a`/`b` are carried through untouched and in the order the
  /// TOML file names them — a profile is not an ad-hoc pair (task 603ea7's
  /// DECIDED "Profiles are not ad-hoc pairs"): the order its replicas
  /// appear in `[replicas]` has no bearing on which is which, and a
  /// profile's `a` may be the remote replica. [profileId] is the profile's
  /// name, which already keys its archive and lock files (SPEC §8.3).
  ///
  /// Throws [CliOptionsError] when [profile]'s two replicas canonicalize to
  /// the same location (expanding `~` and `$VAR`/`${VAR}` references via
  /// [environment], resolving a relative local path against
  /// [workingDirectory], and ignoring a trailing `/`) — a profile with one
  /// replica synced against itself is a bad-arguments case (SPEC §11.5,
  /// exit 3), not a run to attempt. "Profiles are not ad-hoc pairs" only
  /// exempts reordering and remote-first rejection, not this check: a
  /// profile whose `a` and `b` are the same tree is a user error either
  /// way it was written.
  ///
  /// See [forAdHoc] for what [workingDirectory] does and why it defaults to
  /// `null`.
  factory EffectiveOptions.forProfile(
    Profile profile,
    CliOptions options, {
    Map<String, String> environment = const {},
    String? workingDirectory,
  }) {
    final (canonicalA, canonicalB) = _canonicalize(
      profile.a,
      profile.b,
      environment,
      workingDirectory,
    );
    if (canonicalA == canonicalB) {
      throw CliOptionsError(
        'profile "${profile.name}" has the same location for both '
        'replicas once "~" and environment variables are expanded: '
        '$canonicalA',
      );
    }

    return EffectiveOptions(
      a: profile.a,
      b: profile.b,
      rules: profile.rules.mergedWith(RuleSet(ignore: options.ignore)),
      warnSizeBytes: options.warnSizeBytes ?? profile.warnSizeBytes,
      jobs: options.jobs ?? profile.jobs,
      profileId: profile.name,
    );
  }

  /// Merges an ad-hoc [target] (`sync <locA> <locB>`, no profile) with
  /// [options] (SPEC §12, applied with no profile to override).
  ///
  /// There is no profile, so there is nothing to merge `rules`,
  /// `warnSizeBytes`, or `jobs` with — they come from [options] alone.
  ///
  /// [profileId] is derived rather than named, per task 603ea7's DECIDED
  /// "the ad-hoc profile id": both locations are canonicalized (expand `~`
  /// and `$VAR`/`${VAR}` references via [environment], resolve a relative
  /// *local* path against [workingDirectory], make sure a trailing `/`
  /// never matters), ordered canonically (see below), then SHA-256'd
  /// together and truncated to 16 hex characters, prefixed `adhoc-` so the
  /// state directory stays legible next to a named profile's
  /// `<name>-a.jsonl`. This must be identical every time the same pair is
  /// synced — the archive keyed by it *is* change detection (SPEC §5.2), so
  /// a run that gets a fresh id gets a fresh, empty archive and silently
  /// undoes any deletion made since the last run.
  ///
  /// [workingDirectory] matters because a bare relative local path (e.g.
  /// `notes`, with no `~` and no host) means something different in every
  /// directory it is typed from: `cd ~/proj1 && dsync sync notes
  /// me@phone:/n` and, later, `cd ~/proj2 && dsync sync notes
  /// me@phone:/n` are two unrelated trees, and without resolving against
  /// the directory each was run from they would canonicalize to the same
  /// literal string `notes` and silently share one archive — the exact
  /// failure mode this task exists to prevent, and `JsonlArchiveStore`'s
  /// rootPath check cannot catch it, because both runs would store that
  /// same literal string as their rootPath too. [workingDirectory] defaults
  /// to `null`, in which case a relative local path is left unresolved
  /// (literal text, canonical only relative to itself) rather than
  /// rejected — plenty of callers, including this file's own tests, have
  /// no directory to offer and should not be forced to invent one. The
  /// real wiring (`lib/cli/dsync_cli.dart`, not owned by this task) is
  /// expected to always pass `Directory.current.path`.
  ///
  /// Canonical order, two clauses, total and deterministic — side `a` is
  /// whichever of the pair comes first:
  /// - localities differ (one side classifies [Locality.inProcess] and the
  ///   other [Locality.remote], per [Location.classify] and
  ///   [localAddresses]) -> the local side comes first;
  /// - localities are equal (both local, or both remote — SPEC §4.1 does
  ///   not forbid two remotes) -> lexicographic by canonical string.
  ///
  /// This is recomputed here from [localAddresses] rather than trusted from
  /// argument order: `AdHocTarget.parse`'s "local first" check runs at
  /// parse time with no real address set, so it is only ever a
  /// syntax-level guard against a mixed pair typed backwards, not the
  /// authority on which side is actually local. [localAddresses] defaults
  /// to empty — matching that parse-time guard — so this task's own tests
  /// see no reordering surprises; a later task fills it from
  /// `NetworkInterface.list()`.
  ///
  /// Accepted wart, to be documented in `--help` (not this file): a
  /// *remote* path's `~` or bare relative text (e.g. `notes` in
  /// `me@phone:notes`) resolves on the remote host, in the remote user's
  /// home or working directory — neither of which can be known here, so it
  /// is left exactly as typed regardless of [environment] or
  /// [workingDirectory]. So `me@phone:notes` and `me@phone:/sdcard/notes`
  /// derive different ids, as do `phone:/x` and `me@phone:/x`. This is
  /// remote-only: a *local* relative path is resolved against
  /// [workingDirectory], not left as this same kind of wart. The run
  /// header (a later task) mitigates the remaining remote-side case by
  /// showing "first sync of this pair" so a pair typed a second way is
  /// caught before anything moves.
  ///
  /// Throws [CliOptionsError] when the two locations canonicalize to the
  /// same location — the real, post-canonicalization check;
  /// `AdHocTarget.parse`'s own same-location check is syntactic only (SPEC
  /// §11.5, exit 3 either way).
  factory EffectiveOptions.forAdHoc(
    AdHocTarget target,
    CliOptions options, {
    Map<String, String> environment = const {},
    Set<String> localAddresses = const {},
    String? workingDirectory,
  }) {
    final (canonicalA, canonicalB) = _canonicalize(
      target.locationA,
      target.locationB,
      environment,
      workingDirectory,
    );
    if (canonicalA == canonicalB) {
      throw CliOptionsError(
        'the two locations are the same once "~" and environment '
        'variables are expanded: $canonicalA',
      );
    }

    final localityA = target.locationA.classify(localAddresses: localAddresses);
    final localityB = target.locationB.classify(localAddresses: localAddresses);
    final aIsSideA = localityA != localityB
        ? localityA == Locality.inProcess
        : canonicalA.compareTo(canonicalB) <= 0;

    final sideA = aIsSideA ? target.locationA : target.locationB;
    final sideB = aIsSideA ? target.locationB : target.locationA;
    final canonicalSideA = aIsSideA ? canonicalA : canonicalB;
    final canonicalSideB = aIsSideA ? canonicalB : canonicalA;

    return EffectiveOptions(
      a: sideA,
      b: sideB,
      rules: RuleSet(ignore: options.ignore),
      warnSizeBytes: options.warnSizeBytes,
      jobs: options.jobs,
      profileId: _adHocProfileId(canonicalSideA, canonicalSideB),
    );
  }
}

/// `adhoc-<16 hex>` (task 603ea7's DECIDED "the ad-hoc profile id"):
/// SHA-256 of [canonicalSideA] and [canonicalSideB] — already in canonical
/// order — joined by a NUL byte, truncated to the first 16 hex characters.
/// A NUL cannot occur in a POSIX path, so no two distinct pairs can collide
/// by the separator landing in a different place than intended.
String _adHocProfileId(String canonicalSideA, String canonicalSideB) {
  final joined = '$canonicalSideA $canonicalSideB';
  final digest = sha256.convert(utf8.encode(joined));
  return 'adhoc-${digest.toString().substring(0, 16)}';
}

/// The canonical identity of [a] and [b] — see [_canonicalIdentity] — as a
/// pair, computed once so both the same-location check and (for an ad-hoc
/// pair) the ordering and id derivation agree on the same two strings.
(String, String) _canonicalize(
  Location a,
  Location b,
  Map<String, String> environment,
  String? workingDirectory,
) {
  return (
    _canonicalIdentity(a, environment, workingDirectory),
    _canonicalIdentity(b, environment, workingDirectory),
  );
}

/// [location]'s user, host, and canonical path together, so two locations
/// that share a path on different hosts (or vice versa) are never
/// conflated by comparing paths alone.
String _canonicalIdentity(
  Location location,
  Map<String, String> environment,
  String? workingDirectory,
) {
  final path = _canonicalPath(location, environment, workingDirectory);
  final host = location.host;
  if (host == null) return path;
  final user = location.user;
  return '${user == null ? '' : '$user@'}$host:$path';
}

/// Expands a leading `~` (via [Location.expandedPath]) and any `$VAR` /
/// `${VAR}` reference in [environment]; resolves the result against
/// [workingDirectory] if it is still relative and [location] is local (see
/// [_resolveRelativeLocalPath]); then strips one trailing `/`.
String _canonicalPath(
  Location location,
  Map<String, String> environment,
  String? workingDirectory,
) {
  final expandedHome = location.expandedPath(environment);
  final expandedVars = _expandEnvVars(expandedHome, environment);
  final resolved = _resolveRelativeLocalPath(
    location: location,
    path: expandedVars,
    workingDirectory: workingDirectory,
  );
  return _withoutTrailingSlash(resolved);
}

/// Resolves [path] against [workingDirectory] when [location] has no host
/// component (a bare local path, e.g. `notes` or `~/notes` — the latter
/// already absolute by the time this runs) and [path] is still relative.
///
/// This is what keeps two unrelated trees from sharing one ad-hoc archive:
/// `notes` typed from `~/proj1` and `notes` typed from `~/proj2` must not
/// canonicalize to the same string merely because neither had a `~` or an
/// env var to expand (see [EffectiveOptions.forAdHoc]'s doc comment for the
/// full scenario).
///
/// A location with a host — even `localhost:relative/path` — is left
/// untouched: only a location with *no* host at all is treated as "resolve
/// against this process's own directory", since a host, even a local one,
/// names a machine whose own notion of "current directory" is not
/// necessarily this process's. A relative *remote* path is always left
/// alone regardless — the accepted wart [EffectiveOptions.forAdHoc]
/// documents — because it resolves on the far side, which cannot be known
/// here.
///
/// When [workingDirectory] is `null` or empty, [path] is returned
/// unresolved rather than rejected: canonicalization only needs a stable
/// identity, and a caller with no notion of "current directory" (most unit
/// tests, including this file's own) should not be forced to invent one.
String _resolveRelativeLocalPath({
  required Location location,
  required String path,
  required String? workingDirectory,
}) {
  if (location.host != null) return path;
  if (path.startsWith('/')) return path;
  if (workingDirectory == null || workingDirectory.isEmpty) return path;
  return '${_withoutTrailingSlash(workingDirectory)}/$path';
}

final _envVarPattern = RegExp(r'\$\{(\w+)\}|\$(\w+)');

/// Replaces every `$VAR` or `${VAR}` reference in [path] with its value
/// from [environment]. A reference to a name [environment] does not have is
/// left as-is rather than rejected — canonicalization is about producing a
/// stable identity for hashing and comparison, not validating the path.
String _expandEnvVars(String path, Map<String, String> environment) {
  return path.replaceAllMapped(_envVarPattern, (match) {
    final name = match.group(1) ?? match.group(2)!;
    return environment[name] ?? match[0]!;
  });
}

String _withoutTrailingSlash(String path) {
  if (path.length > 1 && path.endsWith('/')) {
    return path.substring(0, path.length - 1);
  }
  return path;
}
