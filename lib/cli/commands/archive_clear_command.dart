import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/archive/archive_inventory.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/stored_archive.dart';
import 'package:dsync/dsync_core/state_dir.dart';

/// `dsync archive clear <profile>` / `dsync archive clear --all` (SPEC §8.1,
/// §11.1) — delete archive logs, so the next run over those replicas starts
/// with no history at all.
///
/// What that costs is in `ArchiveInventory`'s doc comment and is said again
/// on stdout here, because it is the whole point of the command and not
/// obviously harmless: no file in either replica is touched, and the next run
/// rescans and rehashes the whole tree, treating every path as new.
///
/// Addressed by profile id rather than by file path: the id is what `archive
/// list` prints and what a profile is called everywhere else (SPEC §12), and
/// both of a profile's sides are one decision — an archive kept for side `b`
/// after side `a` is gone records a propagation the other side no longer
/// remembers making.
///
/// `--all` is a separate flag rather than a magic profile name, and refuses
/// to be combined with one: "delete every archive on this host" is a
/// different request from "delete this profile's", and a typo'd id must not
/// be able to become it.
class ArchiveClearCommand extends Command<int> {
  @override
  final name = 'clear';

  @override
  final description =
      'Delete a profile\'s archive logs (or --all of them). The next run '
      'rescans from scratch; no replica file is touched.';

  static const _flagAll = 'all';

  final Map<String, String> environment;
  final StateDirPlatform platform;
  final IOSink out;
  final IOSink err;

  ArchiveClearCommand({
    required this.environment,
    required this.platform,
    IOSink? out,
    IOSink? err,
  }) : out = out ?? stdout,
       err = err ?? stderr {
    argParser.addFlag(
      _flagAll,
      negatable: false,
      help: 'Every archive on this host, rather than one profile\'s.',
    );
  }

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    final all = argResults!.flag(_flagAll);
    if (all && rest.isNotEmpty) {
      usageException(
        'dsync archive clear takes either a profile id or --all, not both.',
      );
    }
    if (!all && rest.length != 1) {
      usageException(
        'dsync archive clear needs exactly one argument: the profile id '
        '(see `dsync archive list`), or --all.',
      );
    }

    final inventory = ArchiveInventory.forStateDir(
      environment: environment,
      platform: platform,
    );
    final archives = await inventory.list();
    final doomed = all
        ? archives
        : [
            for (final a in archives)
              if (a.profileId == rest.single) a,
          ];

    if (doomed.isEmpty) {
      // SPEC §11.5: fatal — the caller named something to delete and there
      // was nothing of that name, the same reasoning `pair revoke` gives for
      // a device that was never paired. `--all` over an empty state
      // directory is not that: nothing was named, and "there are no
      // archives" is the answer, not a failure.
      if (all) {
        out.writeln('No archives.');
        return 0;
      }
      err.writeln(
        'dsync archive clear: no archive for profile '
        '"${rest.single}".',
      );
      return 3;
    }

    var freed = 0;
    for (final archive in doomed) {
      try {
        await inventory.delete(archive.logPath);
      } on ReplicaLockHeldException catch (e) {
        // SPEC §4.3, §11.5: a run is using this replica right now. Stop at
        // the one that is in use rather than skipping past it — what has
        // been deleted so far is reported below, so the user knows what to
        // re-run this for.
        err.writeln('dsync archive clear: $e — a run is in progress.');
        _reportFreed(freed);
        return 3;
      }
      freed += archive.sizeBytes;
      out.writeln('deleted: ${archive.logPath} (${archive.sizeBytes} byte(s))');
    }
    _reportFreed(freed);
    out.writeln(
      'The next run over ${_subject(doomed, all: all)} rescans and rehashes '
      'from scratch. No replica file was touched.',
    );
    return 0;
  }

  void _reportFreed(int bytes) => out.writeln('freed: $bytes byte(s)');

  /// What the "next run" sentence is about, in the user's own terms: the
  /// profile they named, or however many profiles `--all` turned out to
  /// cover.
  String _subject(List<StoredArchive> doomed, {required bool all}) {
    if (!all) return 'this profile';
    final profiles = {for (final a in doomed) a.profileId}.length;
    return profiles == 1 ? 'this profile' : 'each of these $profiles profiles';
  }
}
