import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/models/archive.dart';

/// Append-only JSON Lines [ArchiveStore] (SPEC §8.2, chosen in §15).
///
/// Each commit appends one line — an upsert or a tombstone — and flushes
/// before returning, so a commit that returns has survived a crash. [load]
/// replays the whole log; the last line for a path wins. Compaction (folding
/// the log back down to one line per live path) is a separate concern.
class JsonlArchiveStore implements ArchiveStore {
  /// Bumped when the on-disk line format changes.
  static const schemaVersion = 1;

  final File _logFile;
  final ArchiveHeader _header;
  Map<String, ArchiveEntry> _entries = const {};

  JsonlArchiveStore(this._logFile, this._header);

  /// Resolves the standard per-replica log location (SPEC §8.1, §8.3):
  /// `$XDG_STATE_HOME/dsync/<profileId>-<side>.jsonl`, defaulting
  /// `XDG_STATE_HOME` to `~/.local/state` when unset.
  factory JsonlArchiveStore.forProfile({
    required String profileId,
    required String side,
    required String rootPath,
    Map<String, String> environment = const {},
  }) {
    return JsonlArchiveStore(
      resolveArchiveLogPath(
        profileId: profileId,
        side: side,
        environment: environment,
      ),
      ArchiveHeader(
        schemaVersion: schemaVersion,
        profileId: profileId,
        rootPath: rootPath,
      ),
    );
  }

  @override
  Future<Archive> load() async {
    final entries = <String, ArchiveEntry>{};
    if (await _logFile.exists()) {
      final lines = await _logFile.readAsLines();
      for (final line in lines) {
        if (line.isEmpty) continue;
        final record = jsonDecode(line) as Map<String, dynamic>;
        final path = record['path'] as String;
        if (record['op'] == 'delete') {
          entries.remove(path);
        } else {
          entries[path] = ArchiveEntry(
            path: path,
            size: record['size'] as int,
            mtime: record['mtime'] as int,
            mode: record['mode'] as int,
            hash: record['hash'] as String,
          );
        }
      }
    }
    _entries = entries;
    return snapshot();
  }

  @override
  Future<void> commitUpsert(ArchiveEntry entry) async {
    await _append({
      'op': 'upsert',
      'path': entry.path,
      'size': entry.size,
      'mtime': entry.mtime,
      'mode': entry.mode,
      'hash': entry.hash,
    });
    _entries = {..._entries, entry.path: entry};
  }

  @override
  Future<void> commitDelete(String path) async {
    await _append({'op': 'delete', 'path': path});
    _entries = {..._entries}..remove(path);
  }

  @override
  Archive snapshot() => Archive(header: _header, entries: _entries);

  Future<void> _append(Map<String, Object?> record) async {
    await _logFile.parent.create(recursive: true);
    final sink = _logFile.openWrite(mode: FileMode.append);
    sink.writeln(jsonEncode(record));
    await sink.flush();
    await sink.close();
  }
}

/// The standard per-replica archive log path (SPEC §8.1, §8.3):
/// `$XDG_STATE_HOME/dsync/<profileId>-<side>.jsonl`, defaulting
/// `XDG_STATE_HOME` to `~/.local/state` when unset.
///
/// Pure function of [environment] — takes no environment implicitly — so it
/// is testable without touching the filesystem or real process environment.
File resolveArchiveLogPath({
  required String profileId,
  required String side,
  Map<String, String> environment = const {},
}) {
  final stateHome =
      environment['XDG_STATE_HOME'] ?? '${environment['HOME']}/.local/state';
  return File('$stateHome/dsync/$profileId-$side.jsonl');
}
