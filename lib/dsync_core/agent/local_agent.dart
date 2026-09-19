import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/write_path_stats.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';
import 'package:dsync/dsync_core/temp_file.dart';
import 'package:path/path.dart' as p;

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

  /// How a `/`-normalized root-relative path is joined back onto [rootPath]
  /// for every filesystem call this agent makes (SPEC §3's write-side
  /// conversion, the mirror of [Scanner]'s read-side one) — see
  /// [resolveWithinRoot]. Same shape as `Scanner.pathStyle`: a plain value
  /// threaded in rather than a `Platform.pathSeparator` read here, defaulted
  /// to [p.Style.posix], with the two real callers on a Windows host
  /// threading [p.Style.windows] in via `HostPlatform.pathStyle`.
  final p.Style _pathStyle;

  /// This replica's resolved archive log path, reported back in [hello]'s
  /// [ReplicaInfo] (SPEC §11.4's run header, task ee190c). Optional because
  /// [archiveStore] is already the thing that actually reads and writes the
  /// archive — this is only a label the caller who built [archiveStore]
  /// already knows and hands in, not re-derived here, and plenty of callers
  /// (most tests) have no reason to supply it.
  final String? archivePath;

  /// Set once `chmod` is known not to work on this host. See [_applyMode].
  ///
  /// Starts however [isWindowsReplica] says: `true` skips straight to the
  /// no-op path from the very first call, since a Windows replica's lack of
  /// `chmod` (SPEC §3, §7.4) is known ahead of time rather than something to
  /// discover by paying one guaranteed-to-fail process spawn per
  /// differing-mode file. It can still *become* `true` on a non-Windows host
  /// too, the same way it always could: a spawn throwing `ProcessException`
  /// for some other reason latches it there instead (SPEC §3 already flags
  /// Android's external storage as a place metadata writes can be
  /// rejected). Either way, [_applyMode] treats it identically.
  bool _chmodUnavailable;

  /// The `chmod` executable [_applyMode] shells out to. A plain value
  /// rather than the literal `'chmod'` inline, so a test can point it at a
  /// binary guaranteed not to exist and deterministically exercise the
  /// `ProcessException` fallback [_chmodUnavailable] latches on, without
  /// touching this host's real `PATH` — the same "overridable for tests"
  /// shape `SshChannel.connect`'s own `executable` parameter already uses,
  /// for the same reason.
  final String chmodExecutable;

  /// Distinguishes this agent's scratch files from each other. See
  /// [tempPathFor].
  int _nextTempSequence = 0;

  /// What [writeFile] has spent, step by step, over this session (SPEC §17).
  ///
  /// **Held here rather than handed to a recorder**, for the reason
  /// `FlushedSink`'s figures are: this object is the only one that sees the
  /// steps, it is cumulative, and whoever reports it reads it when it has
  /// something to say. A served replica has no recorder of its own — the
  /// report is assembled on the initiator's side — so this crosses the wire
  /// on the `unlock` reply instead (`AgentServer`).
  WritePathStats writePath = const WritePathStats();

  /// [isWindowsReplica] recognizes a Windows replica ahead of time (SPEC
  /// §3, §7.4) rather than [_applyMode] discovering it empirically — see
  /// that field's own doc comment. A plain value rather than a
  /// `Platform.operatingSystem` (or `Platform.isWindows`) read here: this
  /// class never reads the real host itself, the same convention every
  /// other CLI-edge-resolved value in this codebase follows. The real
  /// answer, for a real run, is `lib/cli/host_platform.dart`'s
  /// `HostPlatform.isWindowsReplica`, resolved once at the CLI edge as one
  /// property of the same value that also carries this replica's
  /// [Scanner.pathStyle] and state-directory rule.
  ///
  /// `pathStyle` can't default to `p.Style.posix` directly, for the reason
  /// [Scanner]'s constructor gives: `Style`'s constants are `static final`,
  /// not `const`, so the fallback is applied here instead.
  LocalAgent({
    required this.rootPath,
    required this.archiveStore,
    required this.replicaLock,
    Scanner? scanner,
    this.archivePath,
    bool isWindowsReplica = false,
    this.chmodExecutable = 'chmod',
    p.Style? pathStyle,
  }) : scanner = scanner ?? Scanner(),
       _chmodUnavailable = isWindowsReplica,
       _pathStyle = pathStyle ?? p.Style.posix;

  @override
  Future<ReplicaInfo> hello() async {
    return ReplicaInfo(
      lastCommitTime: await archiveStore.lastCommitTime(),
      archivePath: archivePath,
    );
  }

  @override
  Future<void> lock() => replicaLock.acquire();

  /// Makes this replica's commits durable, then releases the lock (SPEC
  /// §4.3, §8.2).
  ///
  /// The flush is here, and here is where it has to be: commits are batched
  /// (`JsonlArchiveStore`), and the lock is what says this replica is this
  /// session's. Giving it up with commits still in memory would turn the
  /// bounded crash window batching accepts into ordinary, silent loss on
  /// every clean exit. Unlock is also the one operation both ends run on
  /// every exit path — `RunController`'s `finally` for a local replica,
  /// `AgentServer`'s for a served one — which `disconnect` is not.
  @override
  Future<void> unlock() async {
    await archiveStore.flush();
    await replicaLock.release();
  }

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
    // Every step timed separately (SPEC §17). Nine filesystem round trips
    // hide behind one `far` figure otherwise, and they have nothing in
    // common: the directory create is removable, the mode step may be a
    // process spawn, the rename is neither.
    final step = Stopwatch()..start();
    var at = Duration.zero;
    Duration since() {
      final now = step.elapsed;
      final taken = now - at;
      at = now;
      return taken;
    }

    final target = File(_absolute(path));
    await target.parent.create(recursive: true);
    final createTaken = since();
    final temp = File(tempPathFor(target.path, _nextTempSequence++));

    final Duration writeTaken;
    final Duration mtimeTaken;
    final _ModeStep modeStep;
    final Duration renameTaken;
    try {
      final sink = temp.openWrite();
      await sink.addStream(data);
      await sink.flush();
      await sink.close();
      // Contains the wait for the frames, which arrive at the link's pace —
      // `FarSideReport.inboundWait` is that wait, measured where they are
      // consumed, and the difference is what writing cost.
      writeTaken = since();

      try {
        await temp.setLastModified(DateTime.fromMicrosecondsSinceEpoch(mtime));
      } on FileSystemException {
        // Best-effort (SPEC §7.4): the stat below archives whatever mtime
        // actually landed, so a setter failure here isn't fatal.
      }
      mtimeTaken = since();
      modeStep = await _applyMode(temp, mode);

      await temp.rename(target.path);
      renameTaken = since();
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }

    final stat = await target.stat();
    writePath = writePath.plus(
      create: createTaken,
      write: writeTaken,
      mtime: mtimeTaken,
      mode: modeStep.taken,
      chmodSpawns: modeStep.spawned ? 1 : 0,
      rename: renameTaken,
      stat: since(),
    );
    return FileMetadata(
      size: stat.size,
      mtime: stat.modified.microsecondsSinceEpoch,
      // Recorded as-is, on every platform including Windows (SPEC §7.4:
      // "record the actual post-write state ... rather than the intended
      // one") — never suppressed or special-cased here.
      //
      // CI runs this write on a real Windows host with the pinned SDK
      // (SPEC §3), so the call itself is exercised there; what the value it
      // records actually *means* on a Windows-written file is asserted by no
      // test, on the same footing as the Android mtime question SPEC §3
      // carries. What is documented: the
      // Dart SDK's own Windows `dart:io` implementation
      // (`AttributesToStatMode` in `runtime/bin/file_win.cc`) does not
      // return a POSIX permission set read off the filesystem — it derives
      // a pseudo-mode from `GetFileAttributesW`, largely tied to the
      // read-only attribute: read is always set; write is set unless
      // `FILE_ATTRIBUTE_READONLY`; execute is set for directories and for a
      // handful of executable extensions; and owner bits are copied into
      // group and other. So the archived `mode` for a Windows replica is
      // expected to be one of a small, low-cardinality set of values keyed
      // mostly to one attribute bit, not a meaningful permission set — but
      // that expectation is documented behavior, not a verified one, and
      // nothing here acts on it beyond recording whatever this call
      // actually returns.
      mode: stat.mode & 0xFFF,
    );
  }

  /// Sets [file]'s permission bits, best-effort (SPEC §7.4).
  ///
  /// Dart has no chmod, so this shells out — which costs a process spawn, on
  /// a path that runs once per copied file. Three things keep that off the
  /// common case: a freshly created file usually already carries the mode
  /// being asked for, which a stat settles far more cheaply than a spawn;
  /// a replica the constructor already knows is on Windows never reaches
  /// the spawn at all — Windows has no `chmod` and no POSIX permission-bit
  /// model to translate one into, so [_chmodUnavailable] starts `true`
  /// there instead of this method discovering the same fact empirically,
  /// once, at the cost of a process-spawn attempt guaranteed to fail; and a
  /// host lacking `chmod` for some other reason (SPEC §3 flags Android
  /// storage as a place metadata writes can be rejected) is still
  /// discovered once instead of once per file, the same way it always was.
  Future<_ModeStep> _applyMode(File file, int mode) async {
    final step = Stopwatch()..start();
    if (_chmodUnavailable) return _ModeStep(step.elapsed, spawned: false);

    final current = await file.stat();
    if (current.mode & 0xFFF == mode) {
      return _ModeStep(step.elapsed, spawned: false);
    }

    try {
      await Process.run(chmodExecutable, [mode.toRadixString(8), file.path]);
    } on ProcessException {
      _chmodUnavailable = true;
    }
    // Counted as a spawn whether or not it changed anything: a `chmod` that
    // runs and silently fails to take — which is what a filesystem that does
    // not carry POSIX modes gives — costs a fork and an exec every time, and
    // is indistinguishable from a working one except by this count next to
    // the mode step's total.
    return _ModeStep(step.elapsed, spawned: true);
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

  /// Records each commit in turn against this replica's store.
  ///
  /// No batch call on [ArchiveStore], deliberately: its commits are already
  /// buffered and fsynced together (SPEC §8.2), so a store-level batch would
  /// be a rename of this loop. What `Agent.archiveCommit` batches is the
  /// round trip a `RemoteAgent` pays, which is invisible from here.
  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) async {
    for (final commit in commits) {
      switch (commit) {
        case ArchiveUpsert(:final entry):
          await archiveStore.commitUpsert(entry);
        case ArchiveTombstone(:final path):
          await archiveStore.commitDelete(path);
      }
    }
  }

  @override
  Future<void> compact() => archiveStore.compact();

  @override
  Future<void> disconnect() async {}

  String _absolute(String relativePath) =>
      resolveWithinRoot(rootPath, relativePath, pathStyle: _pathStyle);
}

/// The parent of a root-relative path, or `null` when [path] is already
/// top-level — i.e. there is no ancestor directory short of the root itself,
/// which [LocalAgent.removeEmptyDirs] must never remove.
///
/// Deliberately still a literal `/` split, not a platform-aware one (SPEC
/// §3): the only caller is [LocalAgent.removeEmptyDirs], whose own only
/// caller (`Applier._delete`) passes it a [PlanAction.path] — a
/// [ScanEntry.path] the reconciler carried through unchanged — which
/// `Scanner._walkChildren` (task a6efc7) already normalized to `/`-joined
/// before this ever runs, on every platform. Over the wire the same holds:
/// `AgentServer` hands this the `path` a peer sent, and SPEC §4.2 requires
/// that peer to have sent it `/`-joined already. [path] is consequently
/// never OS-spelled here, so there is nothing for this function itself to
/// convert.
///
/// That stays true now that [resolveWithinRoot] emits a native-spelled
/// (`\`-joined, on Windows) absolute path: `removeEmptyDirs` walks *up* on
/// the root-relative form — this function's output is fed straight back
/// into itself and into `_absolute`, never the other way round — so a native
/// path is produced fresh from each ancestor and never handed back here.
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
///
/// The escape checks run on the `/`-normalized form [rootRelativePath]
/// always arrives in (SPEC §4.2): split on `/`, reject empty, a leading `/`,
/// and any `..` segment. Only the final join is platform-aware — the
/// write-side half of SPEC §3's conversion, the mirror of the read side
/// `Scanner._walkChildren` already does (task a6efc7) — routing the segments
/// through a `package:path` `Context` in [pathStyle] rather than gluing them
/// on with a literal `/`. Win32 does tolerate `/` mixed with a native root,
/// so the literal was not a known crash; but it left the one Windows path
/// that depended on an API tolerance rather than on this project's own code,
/// and the extended-length `\\?\` prefix is exactly where that tolerance
/// is absent. `pathStyle` defaults to [p.Style.posix] for the same
/// non-`const` reason [Scanner]'s does; [LocalAgent] threads its own in.
String resolveWithinRoot(
  String rootPath,
  String rootRelativePath, {
  p.Style? pathStyle,
}) {
  final segments = rootRelativePath.split('/');
  if (rootRelativePath.isEmpty ||
      rootRelativePath.startsWith('/') ||
      segments.contains('..')) {
    throw PathEscapesRootException(root: rootPath, path: rootRelativePath);
  }
  final context = p.Context(style: pathStyle ?? p.Style.posix);
  return context.joinAll([rootPath, ...segments]);
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

/// What one call of `LocalAgent._applyMode` cost, and whether it forked.
class _ModeStep {
  final Duration taken;
  final bool spawned;

  const _ModeStep(this.taken, {required this.spawned});
}
