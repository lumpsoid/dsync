import 'dart:io';

import 'package:dsync/dsync_core/config_dir.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/ssh_access.dart';
import 'package:toml/toml.dart';

import 'profile.dart';

/// The tables a profile file may have (SPEC §12). Anything else at the top
/// level is rejected by [loadProfile] — see [ProfileUnknownKeyException].
const _knownTables = {'replicas', 'rules', 'options', 'ssh'};

/// The keys `[replicas]` may have — and, since `[ssh]` is keyed by the same
/// two replica sides (SPEC §8.1), the keys it may have too.
const _knownReplicaKeys = {'a', 'b'};

/// The keys `[rules]` may have.
const _knownRuleKeys = {'ignore', 'follow'};

/// The keys `[options]` may have.
const _knownOptionKeys = {'warn_size_bytes', 'jobs'};

/// The keys an `[ssh.a]` / `[ssh.b]` table may have (SPEC §4.2).
const _knownSshKeys = {'options', 'command'};

/// Loads and validates the profile named [name] (SPEC §12).
///
/// Reads `<config dir>/profiles/<name>.toml`, where the config dir is
/// [resolveConfigDir]'s answer for [platform] — see [resolveProfilePath].
/// [environment] and [platform] are taken as parameters rather than read
/// from `Platform.environment` / `Platform.operatingSystem`, the same
/// convention `resolveStateDir` and `JsonlArchiveStore.forProfile` use, so
/// this stays testable on plain values.
///
/// A missing file, unparseable TOML, a missing `a` or `b` replica, or an
/// unknown table or key anywhere in the file is fatal (SPEC §11.5, exit 3):
/// silently ignoring a misspelled key is how a profile quietly stops
/// ignoring `**/.git`. Throws, respectively, [ProfileNotFoundException],
/// [ProfileFormatException], [ProfileMissingReplicaException], or
/// [ProfileUnknownKeyException].
///
/// Returns a plain [Profile]. Does not merge command-line flags and does not
/// build agents — that is task 603ea7 and task ae03fe.
Future<Profile> loadProfile(
  String name, {
  Map<String, String> environment = const {},
  required ConfigDirPlatform platform,
}) async {
  final file = resolveProfilePath(
    name,
    environment: environment,
    platform: platform,
  );
  if (!await file.exists()) {
    throw ProfileNotFoundException(file.path);
  }

  final contents = await file.readAsString();
  final Map<String, dynamic> table;
  try {
    table = TomlDocument.parse(contents).toMap();
  } on TomlException catch (error) {
    throw ProfileFormatException(file.path, error.message);
  }
  _checkKnownKeys(file.path, table, _knownTables);

  final replicas = _tableOf(table, 'replicas');
  _checkKnownKeys(file.path, replicas, _knownReplicaKeys, prefix: 'replicas');
  final a = _requireReplica(file.path, replicas, 'a');
  final b = _requireReplica(file.path, replicas, 'b');

  final rulesTable = _tableOf(table, 'rules');
  _checkKnownKeys(file.path, rulesTable, _knownRuleKeys, prefix: 'rules');
  final rules = RuleSet(
    ignore: _stringList(rulesTable, 'ignore'),
    follow: _stringList(rulesTable, 'follow'),
  );

  final options = _tableOf(table, 'options');
  _checkKnownKeys(file.path, options, _knownOptionKeys, prefix: 'options');

  final ssh = _tableOf(table, 'ssh');
  _checkKnownKeys(file.path, ssh, _knownReplicaKeys, prefix: 'ssh');

  return Profile(
    name: name,
    a: a,
    b: b,
    rules: rules,
    warnSizeBytes: options['warn_size_bytes'] as int?,
    jobs: options['jobs'] as int?,
    sshA: _sshAccess(file.path, ssh, 'a'),
    sshB: _sshAccess(file.path, ssh, 'b'),
  );
}

/// The standard profile file location (SPEC §12): `profiles/<name>.toml`
/// under the per-platform config dir [resolveConfigDir] resolves for
/// [platform] — `$XDG_CONFIG_HOME/dsync` on Linux, `~/Library/Application
/// Support/dsync` on macOS, `%APPDATA%\dsync` on Windows. The platform
/// branching, and the loud failure on a missing variable, both live there;
/// this only appends the profile's own relative path.
File resolveProfilePath(
  String name, {
  Map<String, String> environment = const {},
  required ConfigDirPlatform platform,
}) {
  final configDir = resolveConfigDir(environment, platform);
  return File('$configDir/profiles/$name.toml');
}

/// The sub-table at [key], or an empty table when [table] has no such key —
/// every one of `[replicas]`, `[rules]`, and `[options]` is optional except
/// that `[replicas]` must in the end supply `a` and `b` (checked by
/// [_requireReplica]).
Map<String, dynamic> _tableOf(Map<String, dynamic> table, String key) =>
    (table[key] as Map<String, dynamic>?) ?? const {};

/// Throws [ProfileUnknownKeyException] for the first key in [table] that is
/// not in [known]. [prefix] dots the reported key so `warn_size_bytesx`
/// under `[options]` is reported as `options.warn_size_bytesx` rather than
/// bare `warn_size_bytesx`, distinguishing it from an unknown top-level
/// table of the same name.
void _checkKnownKeys(
  String path,
  Map<String, dynamic> table,
  Set<String> known, {
  String? prefix,
}) {
  for (final key in table.keys) {
    if (!known.contains(key)) {
      throw ProfileUnknownKeyException(
        path,
        prefix == null ? key : '$prefix.$key',
      );
    }
  }
}

/// Reads `replicas[key]` as a [Location], per the SPEC §12 model. A value
/// that is missing, empty, or not a string cannot become a [Location], so
/// all three are reported the same way: the replica is missing.
Location _requireReplica(
  String path,
  Map<String, dynamic> replicas,
  String key,
) {
  final value = replicas[key];
  if (value is! String || value.isEmpty) {
    throw ProfileMissingReplicaException(path, key);
  }
  return Location.parse(value);
}

/// Reads `[ssh.<side>]` as an [SshAccess] (SPEC §4.2, §12), or the default
/// access when the profile has no such table.
///
/// An empty string in either key is rejected rather than carried: an empty
/// option becomes an argv word ssh reads as a destination, and an empty
/// command becomes a remote shell line that starts with `agent`. Both fail
/// far from the profile that caused them, which is the whole argument for
/// catching them here, where the key can be named.
SshAccess _sshAccess(String path, Map<String, dynamic> ssh, String side) {
  final table = _tableOf(ssh, side);
  _checkKnownKeys(path, table, _knownSshKeys, prefix: 'ssh.$side');

  final options = _stringList(table, 'options');
  if (options.any((option) => option.isEmpty)) {
    throw ProfileInvalidValueException(
      path,
      'ssh.$side.options',
      'an option is the empty string',
    );
  }

  final command = table['command'] as String?;
  if (command != null && command.isEmpty) {
    throw ProfileInvalidValueException(
      path,
      'ssh.$side.command',
      'it is empty',
    );
  }

  return SshAccess(
    options: options,
    command: command ?? SshAccess.defaultCommand,
  );
}

/// Reads `table[key]` as a `List<String>`, or an empty list when absent —
/// `ignore` and `follow` are both optional (SPEC §9).
List<String> _stringList(Map<String, dynamic> table, String key) {
  final value = table[key];
  if (value == null) return const [];
  return [for (final item in value as List) item as String];
}

/// Thrown by [loadProfile] when the profile file does not exist — fatal
/// (SPEC §11.5, exit 3).
class ProfileNotFoundException implements Exception {
  final String path;

  const ProfileNotFoundException(this.path);

  @override
  String toString() => 'Profile not found: $path';
}

/// Thrown by [loadProfile] when the profile file is not valid TOML — fatal
/// (SPEC §11.5, exit 3).
class ProfileFormatException implements Exception {
  final String path;
  final String reason;

  const ProfileFormatException(this.path, this.reason);

  @override
  String toString() => 'Profile at $path is not valid TOML: $reason';
}

/// Thrown by [loadProfile] when `[replicas]` does not supply both `a` and
/// `b` as non-empty strings — fatal (SPEC §11.5, exit 3). Both replicas are
/// required; a profile with only one side has nothing to sync.
class ProfileMissingReplicaException implements Exception {
  final String path;
  final String replica;

  const ProfileMissingReplicaException(this.path, this.replica);

  @override
  String toString() =>
      'Profile at $path is missing replica "$replica" in [replicas]';
}

/// Thrown by [loadProfile] when a key SPEC §12 does define carries a value
/// it cannot use — fatal (SPEC §11.5, exit 3). Distinct from
/// [ProfileFormatException], which is TOML the parser rejected: this is
/// valid TOML saying something the tool has no reading for.
class ProfileInvalidValueException implements Exception {
  final String path;
  final String key;
  final String reason;

  const ProfileInvalidValueException(this.path, this.key, this.reason);

  @override
  String toString() => 'Profile at $path has an invalid $key: $reason';
}

/// Thrown by [loadProfile] when the profile has a table or key that SPEC §12
/// does not define — fatal (SPEC §11.5, exit 3). Silently ignoring a
/// misspelled key is how a profile quietly stops ignoring `**/.git`, so an
/// unrecognized one aborts the run instead of being dropped.
class ProfileUnknownKeyException implements Exception {
  final String path;
  final String key;

  const ProfileUnknownKeyException(this.path, this.key);

  @override
  String toString() => 'Profile at $path has an unknown key: $key';
}
