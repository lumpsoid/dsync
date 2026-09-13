import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/state_dir.dart';

/// Append-only JSON Lines [ArchiveStore] (SPEC §8.2, chosen in §15).
///
/// The first line is the header (SPEC §8.1); every line after it is one
/// commit — an upsert or a tombstone — appended and fsynced before returning,
/// so a commit that returns has survived a crash. [load] checks the header,
/// then replays the log; the last line for a path wins. A half-written last
/// line — the state a crash mid-append leaves behind — is dropped on load and
/// repaired before the next commit. [compact] folds the log back down to one
/// line per live path by writing a fresh file and renaming it over the log,
/// atomic on the same filesystem.
class JsonlArchiveStore implements ArchiveStore {
  /// Bumped when the on-disk line format changes. Version 2 added the header
  /// line, so a version 1 log — which starts straight in on commits — is
  /// correctly rejected as belonging to an older schema.
  static const schemaVersion = 2;

  final File _logFile;
  final ArchiveHeader _header;
  Map<String, ArchiveEntry> _entries = const {};

  /// Commit lines currently on disk in [_logFile], not counting the header.
  /// Compared against `_entries.length` to tell whether the log already holds
  /// exactly one upsert per live path — i.e. compaction would be a no-op.
  int _logLineCount = 0;

  /// Set by [load] when it dropped a half-written last line. The file still
  /// holds those bytes; appending after them would splice the fragment onto
  /// the next record and turn a recoverable tear into a corrupt line in the
  /// middle of the log. Rewriting before the next append clears it.
  bool _needsRepair = false;

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
    var lineCount = 0;
    var torn = false;
    if (await _logFile.exists()) {
      final lines = (await _logFile.readAsLines())
        ..removeWhere((line) => line.isEmpty);
      if (lines.isNotEmpty) {
        _verifyHeader(lines.first);
        final records = lines.skip(1).toList();
        for (var i = 0; i < records.length; i++) {
          final Map<String, dynamic> record;
          try {
            record = jsonDecode(records[i]) as Map<String, dynamic>;
          } on FormatException {
            // A crash partway through an append leaves a half-written last
            // line. That is the one failure an append-only log is supposed to
            // survive (SPEC §8.2), so the torn tail is dropped and repaired on
            // the next commit. The same damage anywhere earlier is real
            // corruption and still aborts the run (SPEC §11.5 exit 3).
            if (i != records.length - 1) rethrow;
            torn = true;
            break;
          }
          lineCount++;
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
    }
    _entries = entries;
    _logLineCount = lineCount;
    _needsRepair = torn;
    return snapshot();
  }

  /// Checks that the log's first line identifies the replica this store was
  /// constructed for (SPEC §8.1). Anything else — an older schema, another
  /// profile, a root that has since been repointed — aborts the run rather
  /// than replaying entries that describe a different tree.
  void _verifyHeader(String line) {
    final found = _headerFromLine(line);
    if (found.schemaVersion != _header.schemaVersion ||
        found.profileId != _header.profileId ||
        found.rootPath != _header.rootPath) {
      throw ArchiveMismatchException(
        path: _logFile.path,
        expected: _header,
        found: found,
      );
    }
  }

  /// The header a log line describes, or a zeroed stand-in when the line is
  /// not a header at all — a schema 1 log, whose first line is a commit.
  /// Reported as a mismatch rather than a parse error, because that is what
  /// it is.
  ArchiveHeader _headerFromLine(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return const ArchiveHeader(
        schemaVersion: 0,
        profileId: '<unreadable>',
        rootPath: '<unreadable>',
      );
    }
    if (decoded is! Map<String, dynamic> || decoded['op'] != 'header') {
      return const ArchiveHeader(
        schemaVersion: 0,
        profileId: '<no header>',
        rootPath: '<no header>',
      );
    }
    return ArchiveHeader(
      schemaVersion: decoded['schemaVersion'] as int,
      profileId: decoded['profileId'] as String,
      rootPath: decoded['rootPath'] as String,
    );
  }

  @override
  Future<void> commitUpsert(ArchiveEntry entry) async {
    await _append(_upsertRecord(entry));
    _entries = {..._entries, entry.path: entry};
  }

  @override
  Future<void> commitDelete(String path) async {
    await _append({'op': 'delete', 'path': path});
    _entries = {..._entries}..remove(path);
  }

  @override
  Future<void> compact() async {
    if (!_needsRepair && _logLineCount == _entries.length) return;

    final tempFile = File('${_logFile.path}.compact.tmp');
    final lines = [
      _headerRecord(),
      for (final entry in _entries.values) _upsertRecord(entry),
    ].map(jsonEncode).join('\n');
    // flush: true is fsync — the replacement has to be on disk before the
    // rename swaps it in, or a crash in that window loses the whole archive
    // rather than one commit.
    await tempFile.writeAsString('$lines\n', flush: true);
    await tempFile.rename(_logFile.path);
    _logLineCount = _entries.length;
    _needsRepair = false;
  }

  @override
  Archive snapshot() => Archive(header: _header, entries: _entries);

  Map<String, Object?> _headerRecord() => {
    'op': 'header',
    'schemaVersion': _header.schemaVersion,
    'profileId': _header.profileId,
    'rootPath': _header.rootPath,
  };

  Map<String, Object?> _upsertRecord(ArchiveEntry entry) => {
    'op': 'upsert',
    'path': entry.path,
    'size': entry.size,
    'mtime': entry.mtime,
    'mode': entry.mode,
    'hash': entry.hash,
  };

  /// Appends one record and returns only once it is on disk.
  ///
  /// Uses [RandomAccessFile] rather than an [IOSink] because `IOSink.flush`
  /// only pushes Dart's buffers to the OS, which survives a process crash but
  /// not a power loss. SPEC §7.3 commits per path so that an interrupted run
  /// converges on the next one; that argument needs the commit to be durable,
  /// so this flush is a real fsync.
  Future<void> _append(Map<String, Object?> record) async {
    if (_needsRepair) await compact();
    await _logFile.parent.create(recursive: true);
    final isNewLog = !await _logFile.exists();
    final handle = await _logFile.open(mode: FileMode.append);
    try {
      // The header is written by whoever creates the log, not by load(), so a
      // run that never commits anything — a dry run — leaves no file behind.
      if (isNewLog) {
        await handle.writeString('${jsonEncode(_headerRecord())}\n');
      }
      await handle.writeString('${jsonEncode(record)}\n');
      await handle.flush();
    } finally {
      await handle.close();
    }
    _logLineCount++;
  }
}

/// The standard per-replica archive log path (SPEC §8.1, §8.3):
/// `<state dir>/<profileId>-<side>.jsonl`. See [resolveStateDir].
File resolveArchiveLogPath({
  required String profileId,
  required String side,
  Map<String, String> environment = const {},
}) {
  return File('${resolveStateDir(environment)}/$profileId-$side.jsonl');
}
