import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';

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

  LocalAgent({
    required this.rootPath,
    required this.archiveStore,
    required this.replicaLock,
    Scanner? scanner,
  }) : scanner = scanner ?? Scanner();

  @override
  Future<void> hello() async {}

  @override
  Future<void> lock() => replicaLock.acquire();

  @override
  Future<void> unlock() => replicaLock.release();

  @override
  Future<ScanResult> scan(RuleSet rules) async {
    final archive = await archiveStore.load();
    return scanner.scan(rootPath: rootPath, archive: archive, rules: rules);
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
    final temp = File('${target.path}.dsync.tmp');

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
      try {
        await Process.run('chmod', [mode.toRadixString(8), temp.path]);
      } on ProcessException {
        // Best-effort mode propagation (SPEC §7.4).
      }

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
