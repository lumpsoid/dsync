import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/stored_archive.dart';
import 'package:dsync/dsync_core/state_dir.dart';

/// Every archive log this host keeps, and the one way to remove one (SPEC
/// §8.1, §8.3).
///
/// A concrete class over a real directory, with no interface: there is one
/// implementation and a test runs it against a temp directory, so an
/// abstraction here would be a rename (see CLAUDE.md, "abstraction lives at
/// the border").
///
/// **What deleting an archive means.** The archive is what lets a run skip
/// the work it already did — the record of every path as of its last
/// successful propagation (SPEC §2). Removing it does not touch either
/// replica's files: it makes the next run rescan and rehash the whole tree
/// and treat every path as new, exactly as the first run over those folders
/// did. That is the operation this class exists for, and the reason it is
/// worth exposing: the archive is the only dsync state that grows with the
/// tree, and a profile the user is finished with keeps its log forever
/// otherwise.
///
/// **Why deleting takes the replica lock.** SPEC §4.3's lock is what
/// serializes a run against anything else touching the same replica's state,
/// and a log deleted from under a run in progress is exactly that: the run
/// would rebuild the log from what it holds in memory and the next run would
/// refuse the result as a mismatched header (SPEC §8.1). The guard is the
/// one the rest of the project already uses, and it holds against every
/// other holder on the host — another `dsync` process, and this process's
/// own run, which `ReplicaLock` covers deliberately rather than by luck (see
/// its doc comment). A delete is never granted while a run has the replica.
class ArchiveInventory {
  /// The directory the logs live in (SPEC §8.3). Not required to exist: a
  /// host that has never synced has no state directory, and that is an empty
  /// list, not a failure.
  final Directory stateDir;

  ArchiveInventory(this.stateDir);

  /// The inventory over the state directory SPEC §8.3 resolves for
  /// [platform], the same way `JsonlArchiveStore.forProfile` and
  /// `ReplicaLock.forProfile` resolve theirs. [platform] is required for the
  /// reason those two require it: a default here would quietly answer for
  /// the wrong host.
  factory ArchiveInventory.forStateDir({
    Map<String, String> environment = const {},
    required StateDirPlatform platform,
  }) => ArchiveInventory(Directory(resolveStateDir(environment, platform)));

  /// Every archive log in [stateDir], oldest-written last, each with what it
  /// costs on disk.
  ///
  /// Only files named the way `resolveArchiveLogPath` names them
  /// (`<profileId>-<side>.jsonl`) are reported: the state directory also
  /// holds the device identity, the paired-device store and the locks, and
  /// `compact` leaves a `.compact.tmp` beside a log it is replacing. None of
  /// those is an archive, and none of them is this page's to offer for
  /// deletion.
  Future<List<StoredArchive>> list() async {
    if (!await stateDir.exists()) return const [];
    final archives = <StoredArchive>[];
    await for (final entity in stateDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith(_logSuffix)) continue;
      final stem = name.substring(0, name.length - _logSuffix.length);
      final split = stem.lastIndexOf('-');
      // A `.jsonl` with no side suffix was not written by
      // `resolveArchiveLogPath`; whatever it is, it is not ours to delete.
      if (split <= 0 || split == stem.length - 1) continue;
      final stat = await entity.stat();
      archives.add(
        StoredArchive(
          logPath: entity.path,
          profileId: stem.substring(0, split),
          side: stem.substring(split + 1),
          rootPath: await _rootPathOf(entity),
          sizeBytes: stat.size,
          lastModified: stat.modified,
        ),
      );
    }
    archives.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    return archives;
  }

  /// Deletes the log at [logPath], so the next run over that replica starts
  /// with no archive at all — see the class doc comment for what that costs
  /// and what it leaves alone.
  ///
  /// Throws [ReplicaLockHeldException] when anything holds the replica's
  /// lock (SPEC §4.3) — another process, or a run in this one: a run is
  /// using the archive being asked for, and the caller has to be told rather
  /// than have the file pulled out from under it. A log that is already gone
  /// is not an error — the outcome asked for is the outcome there is.
  ///
  /// The lock file itself is left behind. It is empty by construction — the
  /// lock is the OS's, not its contents — so it is not archive state and
  /// removing it would only race the next acquirer.
  Future<void> delete(String logPath) async {
    final lock = ReplicaLock(File(_lockPathFor(logPath)));
    await lock.acquire();
    try {
      final log = File(logPath);
      if (await log.exists()) await log.delete();
    } finally {
      await lock.release();
    }
  }

  /// The replica root the log's header names, or `null` when there is no
  /// readable header (SPEC §8.1).
  ///
  /// Reads the first line and stops, rather than loading the log:
  /// `JsonlArchiveStore.load` replays every commit because it is about to
  /// sync against them; this only needs the one line that says whose log
  /// this is, and the logs this reports on are measured in megabytes.
  Future<String?> _rootPathOf(File log) async {
    final String line;
    try {
      line = await log
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
    } on StateError {
      return null; // Empty file: created by a run that never committed.
    } on FormatException {
      return null; // Not UTF-8 at all.
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic> || decoded['op'] != 'header') {
      return null; // A schema 1 log, whose first line is a commit.
    }
    return decoded['rootPath'] as String?;
  }

  static const _logSuffix = '.jsonl';

  /// The lock that guards the replica this log belongs to (SPEC §4.3, §8.3):
  /// the same path with `.lock` in place of `.jsonl`, which is what
  /// `resolveLockPath` produces for the same profile and side.
  static String _lockPathFor(String logPath) =>
      '${logPath.substring(0, logPath.length - _logSuffix.length)}.lock';
}
