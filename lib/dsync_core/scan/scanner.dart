import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:dsync/dsync_core/models/unreadable_paths.dart';
import 'package:dsync/dsync_core/temp_file.dart';
import 'package:path/path.dart' as p;

/// Scans a replica's file tree and compares it against its own archive
/// (SPEC §5).
///
/// Only the initiating side ever needs the archive of the *other* replica —
/// each side reports statuses relative to its own archive, which is enough
/// for reconciliation (SPEC §5, §6).
class Scanner {
  /// How many file operations this scan keeps outstanding at once: the
  /// hashing isolates of SPEC §5.2, and the `stat` batches of [_walkChildren].
  /// A property of this host's resources, unlike the rules, which belong to
  /// the run.
  ///
  /// One value for both because both are the same bet — that this host can
  /// carry more than one file operation at a time — and a host where that is
  /// true of hashing is a host where it is true of the walk. Measured on a
  /// phone, batching the walk's stats four deep took about 9% off it
  /// (SPEC §5.3).
  final int jobs;

  /// How a child's own name is read back out of [FileSystemEntity.path]
  /// (SPEC §3's read-side conversion) before [_walkChildren] rejoins it into
  /// the `/`-normalized, root-relative form [ScanResult], the wire (§4.2) and
  /// the archive (§8.1) all assume.
  ///
  /// A plain value rather than `dart:io`'s `Platform.pathSeparator` read
  /// here — this file has no branch of its own for "which host," and a value
  /// threaded in is what lets a test hand this a Windows-style path tree
  /// without a Windows host. Defaults to [p.Style.posix], correct for every
  /// platform this project can currently verify (Linux, macOS, Android); the
  /// callers on a Windows host thread [p.Style.windows] in instead, resolved
  /// once at each head's edge — `lib/cli/host_platform.dart`'s
  /// `HostPlatform.pathStyle` for the CLI, `lib/app/app_paths.dart`'s
  /// `AppPaths.fileSystem` for the Flutter head.
  final p.Context _pathContext;

  /// The style [_pathContext] was built with — what this scanner reads a
  /// child's own name with, readable by whoever built it so a composition
  /// root can be tested for having threaded the host's real answer in.
  p.Style get pathStyle => _pathContext.style;

  /// How two paths are compared for SPEC §16's collision check: both map
  /// through this to a key, and two different paths landing on the same key
  /// is the collision — two live paths, or a live path and an archived one
  /// (§5.1). `null` — the default — when this replica's filesystem does not
  /// fold anything, so [scan] skips the check entirely rather than compute a
  /// no-op key for every path it visits.
  ///
  /// A function rather than a `bool foldsCase`, so nothing case-specific is
  /// baked into [scan] itself: v1 only ever supplies a case-folding
  /// transform (`case_folding.dart`'s `caseFoldKeyFor`, built on
  /// `path.toLowerCase()`), but SPEC §16 names Unicode normalization
  /// (NFC/NFD) as the same shape of problem, deferred for the same reason
  /// and expected to reuse this exact mechanism — a different transform
  /// supplied here, not a second collision check grown alongside this one.
  ///
  /// Whether *this* replica's filesystem folds at all is resolved once, per
  /// replica, at each head's edge (`case_folding.dart`'s
  /// `detectsCaseFolding`) by probing the filesystem actually mounted at
  /// its root — never assumed from the host
  /// OS, since a case-sensitive-formatted APFS volume or a case-insensitive
  /// Linux mount each need the behaviour their filesystem actually has, not
  /// their OS's default — and threaded down here as a plain value, the same
  /// "resolved once, threaded down" shape the `pathStyle` constructor
  /// parameter above already follows. A test can hand this any transform at
  /// all, faking a filesystem that folds case without a real one to test
  /// against (task a1d635's own acceptance bar).
  final String Function(String path)? foldKey;

  // `pathStyle` can't default to `p.Style.posix` directly: `Style`'s own
  // constants are `static final`, not `const` (package:path resolves
  // `Style.platform` at load time), so the fallback is applied here instead.
  Scanner({this.jobs = 4, p.Style? pathStyle, this.foldKey})
    : _pathContext = p.Context(style: pathStyle ?? p.Style.posix);

  /// Walks [rootPath] and returns one [ScanEntry] per path that is either
  /// present on disk (and not ignored) or present in [archive] but now
  /// missing.
  ///
  /// An ignored path is reported neither way, even when [archive] still holds
  /// an entry for it: SPEC §9 says matching paths are "neither scanned nor
  /// deleted", and an entry the walk never visited is indistinguishable from
  /// one that is genuinely gone.
  ///
  /// Directories are traversed but never themselves reported (SPEC §5.1).
  /// Symlinks are skipped unless [rules] has a matching `follow` pattern, in
  /// which case the target is scanned as if it lived at the link's path
  /// (SPEC §5.1).
  ///
  /// [rules] is a parameter rather than construction state because the rules
  /// belong to the run, not to the host: they come from the initiator's
  /// profile and are handed to whichever replica is scanning (SPEC §9).
  ///
  /// A path this scan cannot read is recorded in [ScanResult.skippedPaths]
  /// and the walk continues (SPEC §5's per-path failure rule, mirroring
  /// §7.6's for the apply phase) — one locked file does not cost the user the
  /// whole run. The replica *root* is the exception: if that cannot be
  /// listed, the failure is thrown, which a caller turns into SPEC §11.5's
  /// exit 3. There is no tree left to sync, and reporting an empty one would
  /// invite mirroring the entire other replica into a directory this host
  /// cannot even read.
  ///
  /// When [foldKey] is set, two live paths — or a live path and an archived
  /// one — that map to the same key are reported in
  /// [ScanResult.skippedPaths] and excluded here exactly the way an
  /// unreadable path is (SPEC §5.1, §16): neither gets a [ScanEntry], so
  /// neither is proposed for reconciliation, because the scan cannot say
  /// which of the two a plan should treat as authoritative on a filesystem
  /// that cannot actually tell them apart. Two archived paths colliding with
  /// each other but with nothing live on disk are left alone — SPEC §16
  /// scopes the check to a collision that could still land two writes on one
  /// file, and neither archived-only path is going to be written to.
  Future<ScanResult> scan({
    required String rootPath,
    required Archive archive,
    RuleSet? rules,
  }) async {
    final context = _ScanContext(archive, rules ?? RuleSet());
    // Canonicalised so the paths on the walk stack are directly comparable
    // with a followed link's resolved target — that comparison is what stops
    // a link pointing at one of its own ancestors from recursing forever.
    final root = await Directory(rootPath).resolveSymbolicLinks();
    await _walk(Directory(root), '', context);
    final hashed = await _hashAll(context);
    // Only complete now — the walk's directory failures plus the read
    // failures `_hashAll` just appended.
    final unreadable = UnreadablePaths.from(context.skipped);

    final deletedPaths = [
      for (final path in archive.entries.keys)
        if (!context.seen.contains(path) &&
            !context.rules.ignores(path) &&
            // An archive entry under a directory the walk could not list is
            // not evidence the file is gone — the scan never got to look.
            // Reporting it `deleted` would propagate a deletion the user
            // never made to the other replica (SPEC §6's table), which is
            // the one way an unreadable path could destroy data rather than
            // merely fail to sync.
            !unreadable.covers(path))
          path,
    ];

    // SPEC §16: computed after `unreadable` above, and added to
    // `context.skipped` only now, so this never feeds back into the
    // `deletedPaths` filter it did not exist for yet.
    final foldKey = this.foldKey;
    final collisions = foldKey == null
        ? const <String, List<String>>{}
        : _foldCollisions(
            live: context.seen,
            archived: deletedPaths,
            foldKey: foldKey,
          );
    final excludedByCollision = {
      for (final group in collisions.values) ...group,
    };
    for (final group in collisions.values) {
      for (final path in group) {
        context.skipped.add(
          SkippedPath.caseFoldCollision(path, _collisionDetail(path, group)),
        );
      }
    }

    return ScanResult(
      entries: [
        ...context.fastPath.where((e) => !excludedByCollision.contains(e.path)),
        ...hashed.where((e) => !excludedByCollision.contains(e.path)),
        for (final path in deletedPaths)
          if (!excludedByCollision.contains(path)) ScanEntry.deleted(path),
      ],
      skippedPaths: context.skipped,
    );
  }

  Future<void> _walk(
    Directory dir,
    String relativePrefix,
    _ScanContext context,
  ) async {
    context.openDirs.add(dir.path);
    try {
      await _walkChildren(dir, relativePrefix, context);
    } finally {
      context.openDirs.remove(dir.path);
    }
  }

  Future<void> _walkChildren(
    Directory dir,
    String relativePrefix,
    _ScanContext context,
  ) async {
    final List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } on FileSystemException catch (error) {
      // An unreadable replica root is fatal, not per-path: see [scan]'s doc
      // comment. Only the root reaches here with an empty prefix — every
      // recursive call passes the child's own relative path.
      if (relativePrefix.isEmpty) rethrow;
      context.skipped.add(
        SkippedPath.unreadable(
          relativePrefix,
          describeFileSystemFailure(error),
        ),
      );
      return;
    }
    children.sort((a, b) => a.path.compareTo(b.path));

    // Files whose `stat` has not been issued yet, in walk order. The walk
    // otherwise keeps exactly one `stat` outstanding at a time, and on a
    // filesystem that charges a round trip per lookup — Android's emulated
    // storage charges ~330 µs — it pays every one of them end to end.
    //
    // Flushed before anything that reports, never merely at the end: a batch
    // left outstanding while a subdirectory is walked, or while a symlink is
    // recorded, would put that subtree's entries ahead of files that come
    // before it in the sort. Everything this scan reports is in walk order and
    // stays that way.
    final pending = <(File, String)>[];

    for (final child in children) {
      // Platform-aware: `child.path` is OS-spelled (SPEC §3) — `\`-joined on
      // Windows, `/`-joined everywhere else this project runs — while `name`
      // and the `relativePath` built from it below must stay `/`-joined
      // regardless, since the wire and the archive assume that on every
      // platform.
      final name = _pathContext.basename(child.path);
      final relativePath = relativePrefix.isEmpty
          ? name
          : '$relativePrefix/$name';
      if (context.rules.ignores(relativePath)) continue;
      // A scratch file a crashed write left behind (SPEC §7.2) lives inside
      // the replica; reporting it would propagate dsync's own half-written
      // data to the other side as a new file.
      if (isTempFileName(name)) continue;

      // The child's type comes from the listing, which already typed it, not
      // from a second `FileSystemEntity.type` lookup of the same path. That
      // call cost 3.50 s of a 29.9 s scan of 14,471 files on a phone
      // (task 1a341e) — Android's emulated storage charges ~333 µs for a
      // path lookup, and this was the second one per entry for information
      // `dir.list(followLinks: false)` had already returned. `followLinks`
      // is false on that listing, so a symlink arrives as a [Link] rather
      // than as whatever it points at, which is the distinction SPEC §5.1
      // turns on.
      //
      // What the lookup did buy is the vanished-file case: a path removed
      // between the listing and the switch typed as `notFound` and fell to
      // `default`. [_visitFile] carries that check now, off the `stat` it
      // already makes, so the race costs nothing extra instead of costing a
      // syscall per entry.
      switch (child) {
        case Directory():
          await _flush(pending, context);
          await _walk(Directory(child.path), relativePath, context);
        case File():
          pending.add((File(child.path), relativePath));
          if (pending.length >= jobs) await _flush(pending, context);
        case Link():
          await _flush(pending, context);
          if (context.rules.follows(relativePath)) {
            await _visitLink(child.path, relativePath, context);
          } else {
            // SPEC §5.1: skipped *and reported* — a link silently missing
            // from a sync is exactly the kind of surprise this tool is
            // supposed to avoid.
            context.skipped.add(
              SkippedPath.symlink(relativePath, 'no follow rule matched'),
            );
          }
        default:
          break;
      }
    }
    await _flush(pending, context);
  }

  /// Stats every file in [pending] at once, then records them in the order
  /// they were added.
  ///
  /// The two halves are separate on purpose. `Future.wait` resolves in
  /// completion order, so recording from inside the wait would order this
  /// scan's entries by whichever `stat` came back first — which is what
  /// [_hashAll] avoids for the same reason, and would make the report's
  /// ordering depend on the filesystem's mood. The stats overlap; the
  /// recording does not.
  Future<void> _flush(
    List<(File, String)> pending,
    _ScanContext context,
  ) async {
    if (pending.isEmpty) return;
    final batch = [...pending];
    pending.clear();
    final stats = await Future.wait([
      for (final (file, _) in batch) file.stat(),
    ]);
    for (var i = 0; i < batch.length; i++) {
      final (file, relativePath) = batch[i];
      await _recordFile(file, relativePath, stats[i], context);
    }
  }

  Future<void> _visitLink(
    String linkPath,
    String relativePath,
    _ScanContext context,
  ) async {
    final String target;
    try {
      target = await Link(linkPath).resolveSymbolicLinks();
    } on FileSystemException {
      // Broken link: nothing to scan, but the user asked to follow it, so
      // saying nothing would be the worst answer.
      context.skipped.add(SkippedPath.symlink(relativePath, 'broken link'));
      return;
    }

    switch (await FileSystemEntity.type(target)) {
      case FileSystemEntityType.directory:
        if (context.openDirs.contains(target)) {
          // The link points at a directory this walk is already inside, so
          // following it would descend through itself without end.
          context.skipped.add(
            SkippedPath.symlink(
              relativePath,
              'target is a directory this walk is already inside',
            ),
          );
          return;
        }
        await _walk(Directory(target), relativePath, context);
      case FileSystemEntityType.file:
        await _visitFile(File(target), relativePath, context);
      default:
        context.skipped.add(
          SkippedPath.symlink(
            relativePath,
            'target is neither a regular file nor a directory',
          ),
        );
    }
  }

  /// One file, stat'd and recorded on its own — the followed-symlink path
  /// (SPEC §5.1), which reaches a single target rather than a directory's
  /// worth of children and so has no batch to join.
  Future<void> _visitFile(
    File file,
    String relativePath,
    _ScanContext context,
  ) async => _recordFile(file, relativePath, await file.stat(), context);

  /// Records one file against [_ScanContext], given the [FileStat] already
  /// taken for it.
  ///
  /// Takes the stat rather than making it, so a caller can have taken several
  /// at once ([_flush]) without giving up the order it records them in.
  Future<void> _recordFile(
    File file,
    String relativePath,
    FileStat stat,
    _ScanContext context,
  ) async {
    // The file went away between the directory listing and this `stat`.
    // Reported rather than silently dropped, and — the part that matters —
    // *not* added to [_ScanContext.seen], so an archived path that really is
    // gone still reaches `deletedPaths` below. `FileStat` answers this
    // without a syscall of its own: it is the reading of the `stat` that had
    // to happen anyway, which is what let the per-entry type lookup go
    // (task 1a341e).
    if (stat.type == FileSystemEntityType.notFound) {
      context.skipped.add(
        SkippedPath.unreadable(relativePath, await _statFailureReason(file)),
      );
      return;
    }
    context.seen.add(relativePath);
    final size = stat.size;
    final mtime = stat.modified.microsecondsSinceEpoch;
    final mode = stat.mode & 0xFFF; // permission + setuid/setgid/sticky bits
    final existing = context.archive.entries[relativePath];

    // Deliberately keyed on size and mtime alone (SPEC §5.2): a mode-only
    // change leaves the file `unchanged` and is not propagated, which §7.4
    // states outright.
    if (existing != null && existing.size == size && existing.mtime == mtime) {
      context.fastPath.add(
        ScanEntry(
          path: relativePath,
          reason: ScanReason.metadataMatched,
          size: size,
          mtime: mtime,
          mode: mode,
          hash: existing.hash,
        ),
      );
      return;
    }

    context.pendingHash.add(
      _HashCandidate(
        absolutePath: file.path,
        path: relativePath,
        size: size,
        mtime: mtime,
        mode: mode,
        existing: existing,
      ),
    );
  }

  /// Why a [FileStat] came back as [FileSystemEntityType.notFound], in the
  /// OS's own words.
  ///
  /// [FileStat] collapses every failure into that one sentinel and carries no
  /// [OSError], so the reason has to be asked for separately — and SPEC §5
  /// says it is worth asking: "permission denied" and "no such file or
  /// directory" are exactly what tell a locked file apart from one that
  /// vanished mid-scan, and only the second is gone by the time anyone reads
  /// the report. Calling it "vanished" because `stat` said `notFound` would
  /// mislabel every locked file as a deleted one.
  ///
  /// One extra syscall, on the failure path only — [File.length] is the
  /// cheapest call here that throws rather than returning a sentinel. The
  /// per-entry cost this whole change exists to remove (task 1a341e) is not
  /// reintroduced: a tree with no unreadable paths never reaches this.
  Future<String> _statFailureReason(File file) async {
    try {
      await file.length();
    } on FileSystemException catch (error) {
      return describeFileSystemFailure(error);
    }
    // It answered the second time. Nothing is known about what the first call
    // hit, so nothing is claimed about it.
    return 'could not be read';
  }

  /// Hashes every [_ScanContext.pendingHash] candidate across at most [jobs]
  /// isolates (SPEC §5.2: "hashing runs in isolates, parallelism
  /// configurable").
  ///
  /// **Batched per isolate, not per file** (task 1a341e). An earlier shape
  /// spawned an isolate only for files past a size threshold and hashed
  /// everything smaller inline, which meant a tree of small files did all its
  /// hashing on the calling isolate: SHA-256 is synchronous CPU work, so [jobs]
  /// async workers on one isolate interleave at the reads and then queue for
  /// the one core. Measured on a phone, a tree of 14,471 files averaging
  /// 12.7 KiB spent 15.6 s of a 29.9 s scan hashing; measured on a desktop
  /// over the same tree shape, that inline path plateaus at ~93 MiB/s however
  /// high [jobs] goes, while the same bytes across real isolates scale
  /// linearly — 100, 196, 384, 653 MiB/s at 1, 2, 4 and 8. The threshold was
  /// not wrong about spawning being dear relative to hashing 13 KiB; it was
  /// wrong that the alternative was hashing on the caller.
  ///
  /// Each isolate still streams one file at a time, so peak memory is one
  /// file per isolate rather than one shard — see [_hashFile].
  ///
  /// A candidate whose read fails — permission denied, or the file vanished
  /// between the directory listing and the hash — yields no [ScanEntry] and
  /// is recorded on [context] instead (SPEC §5's per-path failure rule). The
  /// path stays in [_ScanContext.seen], so it is not then synthesised as
  /// `deleted`: the scan knows the file was there, only not what is in it.
  ///
  /// Failures are collected into a slot-per-candidate array and appended
  /// afterwards rather than pushed onto [context] from inside the shards.
  /// The shards finish in whatever order they finish; this keeps the report in
  /// walk order, the same order every other part of a scan reports in.
  Future<List<ScanEntry>> _hashAll(_ScanContext context) async {
    final candidates = context.pendingHash;
    if (candidates.isEmpty) return const [];

    final results = List<ScanEntry?>.filled(candidates.length, null);
    final failures = List<SkippedPath?>.filled(candidates.length, null);

    await Future.wait([
      for (final shard in _shards(candidates))
        () async {
          // Built out here, not inside the closure below: a closure that
          // reached for `candidates` would copy every [_HashCandidate] — and
          // its [ArchiveEntry] — into the isolate. Only the paths need to
          // cross.
          final paths = [for (final i in shard) candidates[i].absolutePath];
          final (digests, errors) = shard.length == candidates.length
              // One shard is the whole job, so there is no second isolate to
              // run alongside and nothing to gain by leaving this one — and
              // for the same reason its reads stay asynchronous: a blocking
              // read here would block the caller's own isolate, which is the
              // 69 s shape SPEC §5.3 measured.
              ? await _hashBatch(paths, blocking: false)
              : await Isolate.run(() => _hashBatch(paths, blocking: true));
          for (var slot = 0; slot < shard.length; slot++) {
            final index = shard[slot];
            if (digests[slot] case final digest?) {
              results[index] = candidates[index].entryFor(digest);
            } else {
              failures[index] = SkippedPath.unreadable(
                candidates[index].path,
                errors[slot] ?? 'could not be read',
              );
            }
          }
        }(),
    ]);

    context.skipped.addAll(failures.whereType<SkippedPath>());
    return results.whereType<ScanEntry>().toList();
  }

  /// Splits [candidates] into at most [jobs] lists of indices, balanced by
  /// total bytes.
  ///
  /// Largest first into whichever shard is currently lightest — the standard
  /// greedy fit. Dealing them round-robin in walk order would be simpler and
  /// is fine until a tree has a few large files among many small ones, which
  /// is precisely the tree this project keeps meeting: the shard that drew
  /// them becomes the straggler every other isolate waits on, and the
  /// parallelism this method exists for is spent waiting.
  ///
  /// One shard when the whole job is smaller than [_isolateBatchFloorBytes]:
  /// below that, spawning costs more than the hashing, which is the one thing
  /// the old per-file threshold had right.
  List<List<int>> _shards(List<_HashCandidate> candidates) {
    final totalBytes = candidates.fold<int>(0, (sum, c) => sum + c.size);
    final count = totalBytes < _isolateBatchFloorBytes
        ? 1
        : jobs.clamp(1, candidates.length);
    if (count == 1) {
      return [
        [for (var i = 0; i < candidates.length; i++) i],
      ];
    }

    final order = [for (var i = 0; i < candidates.length; i++) i]
      ..sort((a, b) => candidates[b].size.compareTo(candidates[a].size));
    final shards = List.generate(count, (_) => <int>[]);
    final load = List<int>.filled(count, 0);
    for (final index in order) {
      var lightest = 0;
      for (var shard = 1; shard < count; shard++) {
        if (load[shard] < load[lightest]) lightest = shard;
      }
      shards[lightest].add(index);
      load[lightest] += candidates[index].size;
    }
    // Walk order within a shard, so a shard reads its files roughly in the
    // order they sit on disk rather than in the size order it was packed in.
    for (final shard in shards) {
      shard.sort();
    }
    return shards;
  }
}

/// SHA-256 of each of [paths], in order: per slot either a digest or, in the
/// other list, the OS's reason it could not be read (SPEC §5).
///
/// Top-level and returning plain strings because this is what crosses into an
/// isolate: a [FileSystemException] thrown here would have to be rebuilt on
/// the other side, and one failed path must not cost the rest of the batch.
///
/// [blocking] picks which read the digests are computed from, and the caller
/// sets it by whether this batch has an isolate to itself. **The rule is not
/// that blocking reads are faster; it is that a blocking read needs a thread
/// of its own** — SPEC §5.3 measured a serial `listSync`/`statSync` walk on
/// one isolate at 69 s against the asynchronous walk's 10.5 s, and that is
/// what this flag exists to keep away from the caller. Where the batch does
/// own its isolate, `ReadProbe` measures blocking reads on this phone's tree
/// at 28.4 MiB/s against `openRead`'s 10.9 at the same four-way spread, and
/// 35.1 against 18.7 at eight (task 9d2158 §15).
Future<(List<String?>, List<String?>)> _hashBatch(
  List<String> paths, {
  required bool blocking,
}) async {
  final digests = List<String?>.filled(paths.length, null);
  final errors = List<String?>.filled(paths.length, null);
  // One buffer for the whole batch, not one per file: the point of reading
  // in blocks is that peak memory is a block per isolate rather than a file,
  // and allocating 64 KiB per file would spend on the allocator what the
  // syscall just saved.
  final buffer = blocking ? Uint8List(_readBlockBytes) : null;
  for (var i = 0; i < paths.length; i++) {
    try {
      digests[i] = buffer == null
          ? await _hashFile(paths[i])
          : _hashFileSync(paths[i], buffer);
    } on FileSystemException catch (error) {
      errors[i] = describeFileSystemFailure(error);
    }
  }
  return (digests, errors);
}

/// Groups `live` ∪ `archived` by `foldKey`, keeping only the groups SPEC §16
/// actually wants reported: two or more distinct paths sharing a key, at
/// least one of them live. A group that is entirely archived is dropped —
/// [Scanner.scan]'s own doc comment says why.
///
/// Pure and free of [Scanner] state, so it is testable — and re-testable for
/// a future Unicode-normalization `foldKey` — with plain values, no scanner
/// or filesystem involved (CLAUDE.md: "rules live with their data").
Map<String, List<String>> _foldCollisions({
  required Set<String> live,
  required List<String> archived,
  required String Function(String path) foldKey,
}) {
  final groups = <String, List<String>>{};
  for (final path in {...live, ...archived}) {
    (groups[foldKey(path)] ??= []).add(path);
  }
  groups.removeWhere(
    (key, paths) => paths.length < 2 || !paths.any(live.contains),
  );
  return groups;
}

/// [SkippedPath.detail] for one member of a [_foldCollisions] `group`: which
/// other path(s) it folds onto, so the reader knows what to go look at
/// without having to work it out from [SkippedPath.path] alone.
String _collisionDetail(String path, List<String> group) {
  final others = [...group]
    ..remove(path)
    ..sort();
  return 'folds to the same path as ${others.map((o) => '"$o"').join(', ')}';
}

/// The OS's own reason for a failed read, for [SkippedPath.detail] — "Permission
/// denied", "No such file or directory" — rather than the whole
/// [FileSystemException.toString], which leads with a Dart type name and
/// repeats the absolute path the caller is already reporting.
///
/// The distinction it carries is the one a user cannot recover for
/// themselves: a locked file is still there to inspect, while a file that
/// vanished mid-scan is not, and "no such file or directory" against a path
/// that plainly exists is the only clue that something rewrote it underneath
/// the run.
String describeFileSystemFailure(FileSystemException error) =>
    error.osError?.message ?? error.message;

/// Accumulates walk results so the recursive walk methods stay narrow.
class _ScanContext {
  final Archive archive;
  final RuleSet rules;
  final Set<String> seen = {};

  /// Absolute paths of the directories the walk is currently inside — the
  /// chain from the root down to where it is now. A followed symlink whose
  /// target is already in here would send the walk back through itself.
  final Set<String> openDirs = {};

  final List<ScanEntry> fastPath = [];
  final List<SkippedPath> skipped = [];
  final List<_HashCandidate> pendingHash = [];

  _ScanContext(this.archive, this.rules);
}

/// A scan with less than this much to hash in total does it on the calling
/// isolate rather than spawning any.
///
/// Spawning costs more than hashing a couple of hundred kilobytes, so a scan
/// that finds one changed file should not pay for an isolate to hash it. This
/// is a floor on the *whole job*, not on one file (task 1a341e): as a
/// per-file threshold it sent every small file to the calling isolate, which
/// on a tree of many small files is the entire tree.
const _isolateBatchFloorBytes = 256 * 1024;

/// How much of a file is read per syscall by [_hashFileSync].
///
/// 64 KiB because that is what `dart:io`'s own stream uses (`_blockSize` in
/// the SDK's `file_impl.dart`), so a file under it costs one read either way
/// and the comparison between the two paths is the syscall's shape and not
/// the block size. This replica's mean file is 12.7 KiB, so most files are a
/// single read.
const _readBlockBytes = 64 * 1024;

/// Streams the file through the hash rather than reading it whole.
///
/// Only the path crosses into the isolate. Reading the bytes first and
/// hashing them there would do the I/O on the calling isolate and then copy
/// the entire file into the new one, so peak memory was twice the file size
/// per job — enough to kill the process on a large file, times [Scanner.jobs].
Future<String> _hashFile(String absolutePath) async {
  final digest = await sha256.bind(File(absolutePath).openRead()).first;
  return digest.toString();
}

/// [_hashFile]'s digest, from blocking reads into [buffer].
///
/// Same bytes, same hash, one syscall per 64 KiB instead of a message to the
/// VM's native port per block — which is the whole of the difference
/// `ReadProbe` measures between its two modes. Only ever called where the
/// batch owns its isolate; see [_hashBatch].
///
/// Chunked rather than `readAsBytesSync` so the memory promise [_hashFile]'s
/// doc makes is kept exactly: a block per isolate, not a file. A replica with
/// one multi-gigabyte file must not cost [Scanner.jobs] copies of it.
String _hashFileSync(String absolutePath, Uint8List buffer) {
  final file = File(absolutePath).openSync();
  try {
    final sink = _DigestSink();
    final hash = sha256.startChunkedConversion(sink);
    while (true) {
      final read = file.readIntoSync(buffer);
      if (read == 0) break;
      // `addSlice` rather than `sublist`: the buffer is reused, so a copy per
      // block is the one allocation this path exists to avoid.
      hash.addSlice(buffer, 0, read, false);
    }
    hash.close();
    return sink.value.toString();
  } finally {
    file.closeSync();
  }
}

/// Catches the one [Digest] a chunked conversion emits on close.
class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// A file whose fast path (SPEC §5.2 step 1) didn't resolve it, so its
/// content must be hashed to tell unchanged, created, and modified apart.
class _HashCandidate {
  final String absolutePath;
  final String path;
  final int size;
  final int mtime;
  final int mode;
  final ArchiveEntry? existing;

  _HashCandidate({
    required this.absolutePath,
    required this.path,
    required this.size,
    required this.mtime,
    required this.mode,
    required this.existing,
  });

  /// This candidate's [ScanEntry], given the digest [_hashBatch] computed for
  /// it.
  ///
  /// Separate from the hashing so the hashing can happen in another isolate:
  /// what comes back across is a string, and the SPEC §5.2 branch it implies
  /// is decided here, against the [ArchiveEntry] that never had to leave.
  ScanEntry entryFor(String digest) {
    final existing = this.existing;
    final reason = existing == null
        ? ScanReason.created
        : (existing.hash == digest
              ? ScanReason.hashMatched
              : ScanReason.modified);

    return ScanEntry(
      path: path,
      reason: reason,
      size: size,
      mtime: mtime,
      mode: mode,
      hash: digest,
    );
  }
}
