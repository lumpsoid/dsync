import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/state_dir.dart';

/// Append-only JSON Lines [ArchiveStore] (SPEC §8.2, chosen in §15).
///
/// The first line is the header (SPEC §8.1); every line after it is one
/// commit — an upsert or a tombstone. Commits are buffered and appended in
/// batches, one fsync per batch (see [_batchSize]); [flush] is what makes
/// everything recorded so far durable. [load] checks the header,
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

  /// How many commits are buffered before a batch is written and fsynced
  /// (SPEC §8.2).
  ///
  /// The cost this exists to remove is measured: a phone-to-desktop run of a
  /// 14k-file tree spent 85.4 s of its 133 s apply phase inside this store on
  /// the initiating side alone, one fsync per path, and the far side another
  /// 143 s (SPEC §17). One fsync per 256 paths takes that to 57 flushes.
  ///
  /// The number is chosen from what a lost batch costs, which is the only
  /// thing that gets worse: a crash loses at most 256 commits, and SPEC §7.3
  /// already converges on exactly that state without intervention — the
  /// stale side rehashes those paths on the next run and they resolve as
  /// commit-only. 256 paths of a 14k tree is under 2% of one scan's hashing,
  /// against a saving measured in minutes. Larger batches stop paying: the
  /// fsyncs are already amortised to nothing by here, while the window a
  /// crash can lose keeps growing.
  static const _batchSize = 256;

  /// How long a commit may sit unwritten while more are still arriving.
  ///
  /// [_batchSize] alone is a bad bound when commits are slow rather than
  /// dense — a plan of a few large files would hold its handful of commits
  /// for the whole transfer. This is checked as each commit arrives rather
  /// than driven by a timer: a timer would need cancelling on every exit
  /// path to let a process exit, and it would only ever fire in the case
  /// [flush] already covers, which is "no more commits are coming".
  static const _batchAge = Duration(seconds: 1);

  final File _logFile;
  final ArchiveHeader _header;

  /// Mutated in place by each commit. [snapshot] is what hands out a stable
  /// view, so a commit costs one map write rather than a copy of the whole
  /// archive — a run that commits every path would otherwise be quadratic in
  /// the size of the tree.
  final Map<String, ArchiveEntry> _entries = {};

  /// Paths whose last line is an intent (SPEC §7.6). Mutated in place like
  /// [_entries], and for the same reason.
  final Set<String> _intents = {};

  /// Completes when the commit currently in progress is finished with the
  /// log — see [_serialized].
  Future<void> _committing = Future<void>.value();

  /// Commits recorded but not yet written, oldest first. Already applied to
  /// [_entries], so this replica's own view of its archive does not depend
  /// on when they reach the disk — only its survival of a crash does.
  final List<Map<String, Object?>> _pending = [];

  /// When the oldest entry in [_pending] was recorded, for [_batchAge].
  final Stopwatch _pendingAge = Stopwatch();

  /// Commit lines currently on disk in [_logFile], not counting the header.
  /// Compared against [_liveLineCount] to tell whether the log already holds
  /// exactly one upsert per live path — i.e. compaction would be a no-op.
  int _logLineCount = 0;

  /// Set by [load] when it dropped a half-written last line. The file still
  /// holds those bytes; appending after them would splice the fragment onto
  /// the next record and turn a recoverable tear into a corrupt line in the
  /// middle of the log. Rewriting before the next append clears it.
  bool _needsRepair = false;

  /// Whether the log file and its directory are known to be in place.
  ///
  /// A run commits once per path it touches (SPEC §7.3), and creating the
  /// state directory and stat-ing the log before every one of those is work
  /// with a fixed answer. Reset by [compact], which replaces the file.
  bool _logExists = false;

  JsonlArchiveStore(this._logFile, this._header);

  /// Resolves the standard per-replica log location (SPEC §8.1, §8.3):
  /// `$XDG_STATE_HOME/dsync/<profileId>-<side>.jsonl`, defaulting
  /// `XDG_STATE_HOME` to `~/.local/state` when unset. [platform] is required,
  /// not defaulted: every caller states which of SPEC §8.3's rules it means
  /// rather than silently getting Linux's — see [resolveArchiveLogPath].
  factory JsonlArchiveStore.forProfile({
    required String profileId,
    required String side,
    required String rootPath,
    Map<String, String> environment = const {},
    required StateDirPlatform platform,
  }) {
    return JsonlArchiveStore(
      resolveArchiveLogPath(
        profileId: profileId,
        side: side,
        environment: environment,
        platform: platform,
      ),
      ArchiveHeader(
        schemaVersion: schemaVersion,
        profileId: profileId,
        rootPath: rootPath,
      ),
    );
  }

  @override
  Future<Archive> load() => _serialized(() async {
    // Written out first: [_load] rebuilds [_entries] from what is on disk,
    // so a commit still sitting in [_pending] would be dropped without a
    // trace. `LocalAgent.scan` loads mid-session, after `_refreshFastPathKeys`
    // has committed, which is exactly that case.
    await _write();
    return _load();
  });

  Future<Archive> _load() async {
    final entries = <String, ArchiveEntry>{};
    final intents = <String>{};
    var lineCount = 0;
    var torn = false;
    _logExists = await _logFile.exists();
    if (_logExists) {
      // Streamed rather than read whole: the log holds about one line per
      // live path in steady state (SPEC §8.2), which is megabytes on a tree
      // of any size, and nothing but [entries] outlives this call. Same
      // reader as `ArchiveInventory._rootPathOf`, which wants only the first
      // line where this wants them all.
      final lines = _logFile
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      var headerSeen = false;
      // One record of lookahead. A half-written last line is tolerated and
      // anything earlier is not, and under a stream "last" is only known
      // once the stream ends — so a record is replayed when the one after it
      // arrives, which proves it was not the last.
      String? held;
      // `forEach` rather than `await for`: the callback runs as each line is
      // delivered, where `await for` suspends once per line and costs a
      // third of the load time on a 14k-path log for nothing. Errors still come out
      // of the await, so corruption mid-log aborts exactly as before
      // (SPEC §11.5 exit 3).
      await lines.forEach((line) {
        if (line.isEmpty) return;
        if (!headerSeen) {
          _verifyHeader(line);
          headerSeen = true;
          return;
        }
        final previous = held;
        if (previous != null) {
          _replay(previous, entries, intents);
          lineCount++;
        }
        held = line;
      });
      final last = held;
      if (last != null) {
        try {
          _replay(last, entries, intents);
          lineCount++;
        } on FormatException {
          // A crash partway through an append leaves a half-written last
          // line. That is the one failure an append-only log is supposed to
          // survive (SPEC §8.2), so the torn tail is dropped and repaired on
          // the next commit.
          torn = true;
        }
      }
    }
    _entries
      ..clear()
      ..addAll(entries);
    _intents
      ..clear()
      ..addAll(intents);
    _logLineCount = lineCount;
    _needsRepair = torn;
    return snapshot();
  }

  /// Folds one commit line into [entries] and [intents]; the last line for a
  /// path wins, except that an intent leaves the path's entry where it was —
  /// it says the file may no longer match it, not that the entry is gone.
  /// Throws [FormatException] when the line is not JSON — which is how
  /// [_load] tells a torn tail from corruption.
  void _replay(
    String line,
    Map<String, ArchiveEntry> entries,
    Set<String> intents,
  ) {
    final record = jsonDecode(line) as Map<String, dynamic>;
    final path = record['path'] as String;
    if (record['op'] == 'intent') {
      intents.add(path);
      return;
    }
    intents.remove(path);
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
  Future<void> commitUpsert(ArchiveEntry entry) => _serialized(() async {
    _record(_upsertRecord(entry));
    _entries[entry.path] = entry;
    _intents.remove(entry.path);
    await _writeIfDue();
  });

  @override
  Future<void> commitDelete(String path) => _serialized(() async {
    _record({'op': 'delete', 'path': path});
    _entries.remove(path);
    _intents.remove(path);
    await _writeIfDue();
  });

  @override
  Future<void> commitIntent(String path) => _serialized(() async {
    _record(_intentRecord(path));
    _intents.add(path);
    await _writeIfDue();
  });

  @override
  Future<void> flush() => _serialized(_write);

  @override
  Future<DateTime?> lastCommitTime() => _serialized(() async {
    // Written out first, so this answers about every commit made rather than
    // about every commit that happens to have reached the disk. It costs
    // nothing: `Agent.hello` asks once per session, before anything has been
    // committed at all.
    await _write();
    if (!await _logFile.exists()) return null;
    return (await _logFile.stat()).modified;
  });

  @override
  Future<void> compact() => _serialized(() async {
    // Written out first rather than dropped, even though [_compact] rebuilds
    // the log from [_entries] and would carry them anyway: its early return
    // for a log that already matches [_entries] would otherwise throw away
    // commits that never reached the disk at all.
    await _write();
    await _compact();
  });

  Future<void> _compact() async {
    if (!_needsRepair && _logLineCount == _liveLineCount) return;

    final tempFile = File('${_logFile.path}.compact.tmp');
    final lines = [
      _headerRecord(),
      for (final entry in _entries.values) _upsertRecord(entry),
      // Carried forward, after the entries they qualify: dropping one here
      // would turn a torn write back into what looks like a user's edit
      // (SPEC §7.6), and replaying it before its entry would let the entry's
      // upsert clear it.
      for (final path in _intents) _intentRecord(path),
    ].map(jsonEncode).join('\n');
    // flush: true is fsync — the replacement has to be on disk before the
    // rename swaps it in, or a crash in that window loses the whole archive
    // rather than one commit.
    await tempFile.writeAsString('$lines\n', flush: true);
    await tempFile.rename(_logFile.path);
    _logLineCount = _liveLineCount;
    _needsRepair = false;
    _logExists = true;
  }

  /// The archive as it stands, detached from later commits.
  ///
  /// Copies, because [_entries] is mutated in place: a caller holding the
  /// result across commits — [LocalAgent] does, to compare the scan against
  /// the archive it loaded — must not see it shift underneath.
  @override
  Archive snapshot() => Archive(
    header: _header,
    entries: Map.unmodifiable(_entries),
    untrusted: Set.unmodifiable(_intents),
  );

  /// How many commit lines a freshly compacted log holds: one upsert per
  /// live path and one intent per marked one.
  int get _liveLineCount => _entries.length + _intents.length;

  Map<String, Object?> _headerRecord() => {
    'op': 'header',
    'schemaVersion': _header.schemaVersion,
    'profileId': _header.profileId,
    'rootPath': _header.rootPath,
  };

  Map<String, Object?> _intentRecord(String path) => {
    'op': 'intent',
    'path': path,
  };

  Map<String, Object?> _upsertRecord(ArchiveEntry entry) => {
    'op': 'upsert',
    'path': entry.path,
    'size': entry.size,
    'mtime': entry.mtime,
    'mode': entry.mode,
    'hash': entry.hash,
  };

  /// Runs [body] after every commit already issued against this store has
  /// finished, and before every one issued after it.
  ///
  /// Required since task 0f7dfc, which lets a peer have several
  /// `archiveCommitUpsert`s outstanding at once (SPEC §4.2) and so lands
  /// several of them here concurrently. Two overlapping [_append]s would
  /// each open the log, and the header a new log needs is a second write
  /// after the first — so one commit's line could land between another's
  /// header and record. [_logLineCount] and [_entries] are read-modify-write
  /// across an `await` too, which is the same race without the file.
  ///
  /// A chain rather than a lock because that is all a single-isolate event
  /// loop needs, and it costs nothing: these operations are serialized by
  /// their own fsync anyway (SPEC §8.2), which is the floor this is nowhere
  /// near.
  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _committing.then((_) => body());
    // Chained on a future that ignores the outcome, so one failed commit
    // does not fail every commit after it — a failed action is recorded and
    // the run carries on (SPEC §7.6).
    _committing = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Buffers [record] for the next batch.
  void _record(Map<String, Object?> record) {
    if (_pending.isEmpty) {
      _pendingAge
        ..reset()
        ..start();
    }
    _pending.add(record);
  }

  /// Writes the buffered batch if it is full enough or old enough.
  Future<void> _writeIfDue() async {
    if (_pending.length < _batchSize && _pendingAge.elapsed < _batchAge) {
      return;
    }
    await _write();
  }

  /// Appends every buffered record and returns only once they are on disk.
  ///
  /// Uses [RandomAccessFile] rather than an [IOSink] because `IOSink.flush`
  /// only pushes Dart's buffers to the OS, which survives a process crash but
  /// not a power loss. SPEC §7.3's convergence argument needs a commit that
  /// is reported durable to actually be durable, so this flush is a real
  /// fsync — one per batch rather than one per path (SPEC §8.2).
  ///
  /// The batch goes out as a single `writeString`, so a crash can tear the
  /// last line but cannot interleave two records: [load] drops a
  /// half-written last line and [_needsRepair] rewrites before the next
  /// append, exactly as for a single record.
  Future<void> _write() async {
    if (_pending.isEmpty) return;

    if (_needsRepair) await _compact();

    var isNewLog = false;
    if (!_logExists) {
      await _logFile.parent.create(recursive: true);
      isNewLog = !await _logFile.exists();
    }

    // The header is written by whoever creates the log, not by load(), so a
    // run that never commits anything — a dry run — leaves no file behind.
    final records = [
      if (isNewLog) _headerRecord(),
      ..._pending,
    ].map(jsonEncode).join('\n');
    final written = _pending.length;
    _pending.clear();
    _pendingAge.stop();

    final handle = await _logFile.open(mode: FileMode.append);
    try {
      await handle.writeString('$records\n');
      await handle.flush();
    } finally {
      await handle.close();
    }
    _logExists = true;
    _logLineCount += written;
  }
}

/// The standard per-replica archive log path (SPEC §8.1, §8.3):
/// `<state dir>/<profileId>-<side>.jsonl`. See [resolveStateDir]. [platform]
/// is required, not defaulted: a hardcoded default here would silently
/// resolve the wrong directory on every platform but the one it names, which
/// is worse than a compile error naming every caller that owes one — see
/// `lib/cli/host_platform.dart` for where the CLI head's real answer comes
/// from.
File resolveArchiveLogPath({
  required String profileId,
  required String side,
  Map<String, String> environment = const {},
  required StateDirPlatform platform,
}) {
  return File(
    '${resolveStateDir(environment, platform)}/$profileId-$side.jsonl',
  );
}
