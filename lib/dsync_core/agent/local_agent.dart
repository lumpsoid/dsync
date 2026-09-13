import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';
import 'package:dsync/dsync_core/temp_file.dart';

/// [Agent] implementation over the real filesystem (SPEC §4.1).
///
/// Used both for a replica whose location resolves to this machine and,
/// behind the agent server handler, as the thing a `RemoteAgent` on the other
/// end of a `Channel` is actually driving. No protocol or channel code lives
/// here — that layer wraps this.
class LocalAgent implements Agent {
  final String rootPath;
  final ArchiveStore archiveStore;
  final ReplicaLock replicaLock;
  final Scanner scanner;

  /// Set once `chmod` has turned out not to exist on this host. See
  /// [_applyMode].
  bool _chmodUnavailable = false;

  /// Distinguishes this agent's scratch files from each other. See
  /// [tempPathFor].
  int _nextTempSequence = 0;

  LocalAgent({
    required this.rootPath,
    required this.archiveStore,
    required this.replicaLock,
    Scanner? scanner,
  }) : scanner = scanner ?? Scanner();

  @override
  Future<ReplicaInfo> hello() async {
    return ReplicaInfo(lastCommitTime: await archiveStore.lastCommitTime());
  }

  @override
  Future<void> lock() => replicaLock.acquire();

  @override
  Future<void> unlock() => replicaLock.release();

  @override
  Future<ScanResult> scan(RuleSet rules) async {
    final archive = await archiveStore.load();
    final result = await scanner.scan(
      rootPath: rootPath,
      archive: archive,
      rules: rules,
    );
    await _refreshFastPathKeys(result.entries, archive);
    return result;
  }

  /// Writes back the size and mtime of files a rehash proved unchanged (SPEC
  /// §5.2 step 2: "the archive entry's `size`/`mtime` are refreshed at
  /// commit").
  ///
  /// Nothing else ever does this. The fast path keys on size and mtime; when
  /// they drift but the content does not — a touch, a restore from backup, a
  /// filesystem that rounds mtimes (SPEC §15.6) — the scan rehashes and
  /// reports `unchanged`, and the §6 table resolves `unchanged / unchanged`
  /// to "nothing". So no action's commit refreshes the keys, and the same
  /// file is rehashed on every run, forever, against SPEC §1's "skip work
  /// whenever the stored state allows it".
  ///
  /// Only the fast-path keys move; the hash — the one authoritative field —
  /// is carried over untouched, because it is precisely what the rehash
  /// confirmed. That is also why this is safe during a `--dry-run` (SPEC
  /// §11.2): it updates a cache, not a record of what is synced, and leaves
  /// the replicas alone.
  Future<void> _refreshFastPathKeys(
    List<ScanEntry> entries,
    Archive archive,
  ) async {
    for (final entry in entries) {
      if (entry.status != ScanStatus.unchanged) continue;
      final archived = archive.entries[entry.path];
      final size = entry.size;
      final mtime = entry.mtime;
      final mode = entry.mode;
      if (archived == null || size == null || mtime == null || mode == null) {
        continue;
      }
      if (archived.size == size && archived.mtime == mtime) continue;

      await archiveStore.commitUpsert(
        ArchiveEntry(
          path: entry.path,
          size: size,
          mtime: mtime,
          mode: mode,
          hash: archived.hash,
        ),
      );
    }
  }

  @override
  Stream<List<int>> readFile(String path) => File(_absolute(path)).openRead();

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) async {
    final target = File(_absolute(path));
    await target.parent.create(recursive: true);
    final temp = File(tempPathFor(target.path, _nextTempSequence++));

    try {
      final sink = temp.openWrite();
      await sink.addStream(data);
      await sink.flush();
      await sink.close();

      try {
        await temp.setLastModified(DateTime.fromMicrosecondsSinceEpoch(mtime));
      } on FileSystemException {
        // Best-effort (SPEC §7.4): the stat below archives whatever mtime
        // actually landed, so a setter failure here isn't fatal.
      }
      await _applyMode(temp, mode);

      await temp.rename(target.path);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }

    final stat = await target.stat();
    return FileMetadata(
      size: stat.size,
      mtime: stat.modified.microsecondsSinceEpoch,
      mode: stat.mode & 0xFFF,
    );
  }

  /// Sets [file]'s permission bits, best-effort (SPEC §7.4).
  ///
  /// Dart has no chmod, so this shells out — which costs a process spawn, on
  /// a path that runs once per copied file. Two things keep that off the
  /// common case: a freshly created file usually already carries the mode
  /// being asked for, which a stat settles far more cheaply than a spawn; and
  /// a host without a `chmod` at all (SPEC §3 flags Android storage as a
  /// place metadata writes can be rejected) is discovered once instead of
  /// once per file.
  Future<void> _applyMode(File file, int mode) async {
    if (_chmodUnavailable) return;

    final current = await file.stat();
    if (current.mode & 0xFFF == mode) return;

    try {
      await Process.run('chmod', [mode.toRadixString(8), file.path]);
    } on ProcessException {
      _chmodUnavailable = true;
    }
  }

  @override
  // `async` rather than expression-bodied so a rejected path surfaces through
  // the returned Future like every other failure, not as a synchronous throw.
  Future<void> delete(String path) async {
    await File(_absolute(path)).delete();
  }

  @override
  Future<void> removeEmptyDirs(String path) async {
    var ancestor = _parentOf(path);
    while (ancestor != null) {
      final dir = Directory(_absolute(ancestor));
      if (!await dir.exists() || !await dir.list().isEmpty) break;
      await dir.delete();
      ancestor = _parentOf(ancestor);
    }
  }

  @override
  Future<void> archiveCommitUpsert(ArchiveEntry entry) =>
      archiveStore.commitUpsert(entry);

  @override
  Future<void> archiveCommitDelete(String path) =>
      archiveStore.commitDelete(path);

  @override
  Future<void> compact() => archiveStore.compact();

  @override
  Future<void> disconnect() async {}

  String _absolute(String relativePath) =>
      resolveWithinRoot(rootPath, relativePath);
}

/// The parent of a root-relative path, or `null` when [path] is already
/// top-level — i.e. there is no ancestor directory short of the root itself,
/// which [LocalAgent.removeEmptyDirs] must never remove.
String? _parentOf(String path) {
  final lastSlash = path.lastIndexOf('/');
  return lastSlash == -1 ? null : path.substring(0, lastSlash);
}

/// Joins [rootRelativePath] onto [rootPath], refusing anything that would
/// land outside the replica.
///
/// Every path a [LocalAgent] acts on arrives from the other end of the
/// connection, and an agent reached over ssh has no reason to trust the far
/// side: `../../.ssh/authorized_keys` would otherwise be written with the
/// agent user's privileges. Nothing the engine itself produces is affected —
/// scan paths are built by walking the tree — so a rejection here always
/// means the request was malformed or hostile.
///
/// Pure string logic, so it is testable without a filesystem.
String resolveWithinRoot(String rootPath, String rootRelativePath) {
  final segments = rootRelativePath.split('/');
  if (rootRelativePath.isEmpty ||
      rootRelativePath.startsWith('/') ||
      segments.contains('..')) {
    throw PathEscapesRootException(root: rootPath, path: rootRelativePath);
  }
  return '$rootPath/$rootRelativePath';
}

/// Thrown when a peer asks an agent to act on a path outside its replica
/// root — fatal for that operation, and reported to the peer as a failure.
class PathEscapesRootException implements Exception {
  final String root;
  final String path;

  const PathEscapesRootException({required this.root, required this.path});

  @override
  String toString() => 'Path escapes the replica root $root: "$path"';
}
