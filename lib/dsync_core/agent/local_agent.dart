import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
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
  Future<List<ScanEntry>> scan() async {
    final archive = await archiveStore.load();
    return scanner.scan(rootPath: rootPath, archive: archive);
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
  Future<void> delete(String path) => File(_absolute(path)).delete();

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

  String _absolute(String relativePath) => '$rootPath/$relativePath';
}

/// The parent of a root-relative path, or `null` when [path] is already
/// top-level — i.e. there is no ancestor directory short of the root itself,
/// which [LocalAgent.removeEmptyDirs] must never remove.
String? _parentOf(String path) {
  final lastSlash = path.lastIndexOf('/');
  return lastSlash == -1 ? null : path.substring(0, lastSlash);
}
