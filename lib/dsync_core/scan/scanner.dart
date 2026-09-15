import 'dart:io';
import 'dart:isolate';

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
  /// Hashing concurrency (SPEC §5.2: "hashing runs in isolates, parallelism
  /// configurable"). A property of this host's resources, unlike the rules,
  /// which belong to the run.
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
  /// two real callers on a Windows host thread [p.Style.windows] in instead,
  /// resolved once via `lib/cli/host_platform.dart`'s
  /// `HostPlatform.pathStyle`.
  final p.Context _pathContext;

  /// How two paths are compared for SPEC §16's collision check: both map
  /// through this to a key, and two different paths landing on the same key
  /// is the collision — two live paths, or a live path and an archived one
  /// (§5.1). `null` — the default — when this replica's filesystem does not
  /// fold anything, so [scan] skips the check entirely rather than compute a
  /// no-op key for every path it visits.
  ///
  /// A function rather than a `bool foldsCase`, so nothing case-specific is
  /// baked into [scan] itself: v1 only ever supplies a case-folding
  /// transform (`lib/cli/host_platform.dart`'s `caseFoldKeyFor`, built on
  /// `path.toLowerCase()`), but SPEC §16 names Unicode normalization
  /// (NFC/NFD) as the same shape of problem, deferred for the same reason
  /// and expected to reuse this exact mechanism — a different transform
  /// supplied here, not a second collision check grown alongside this one.
  ///
  /// Whether *this* replica's filesystem folds at all is resolved once, per
  /// replica, at the CLI edge (`detectsCaseFolding`) by probing the
  /// filesystem actually mounted at its root — never assumed from the host
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

      switch (await FileSystemEntity.type(child.path, followLinks: false)) {
        case FileSystemEntityType.directory:
          await _walk(Directory(child.path), relativePath, context);
        case FileSystemEntityType.file:
          await _visitFile(File(child.path), relativePath, context);
        case FileSystemEntityType.link:
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

  Future<void> _visitFile(
    File file,
    String relativePath,
    _ScanContext context,
  ) async {
    context.seen.add(relativePath);
    final stat = await file.stat();
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

  /// Hashes every [_ScanContext.pendingHash] candidate with at most [jobs]
  /// concurrent isolates.
  ///
  /// A candidate whose read fails — permission denied, or the file vanished
  /// between the directory listing and the hash — yields no [ScanEntry] and
  /// is recorded on [context] instead (SPEC §5's per-path failure rule). The
  /// path stays in [_ScanContext.seen], so it is not then synthesised as
  /// `deleted`: the scan knows the file was there, only not what is in it.
  ///
  /// Failures are collected into a slot-per-candidate array and appended
  /// afterwards rather than pushed onto [context] from inside the workers.
  /// The workers interleave at every `await`, so pushing directly would order
  /// the report by whichever read happened to fail first; this keeps it in
  /// walk order, the same order every other part of a scan reports in.
  Future<List<ScanEntry>> _hashAll(_ScanContext context) async {
    final candidates = context.pendingHash;
    if (candidates.isEmpty) return const [];

    final results = List<ScanEntry?>.filled(candidates.length, null);
    final failures = List<SkippedPath?>.filled(candidates.length, null);
    var next = 0;

    Future<void> worker() async {
      while (next < candidates.length) {
        final index = next++;
        final candidate = candidates[index];
        try {
          results[index] = await candidate.hash();
        } on FileSystemException catch (error) {
          failures[index] = SkippedPath.unreadable(
            candidate.path,
            describeFileSystemFailure(error),
          );
        }
      }
    }

    final workerCount = jobs.clamp(1, candidates.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));
    context.skipped.addAll(failures.whereType<SkippedPath>());
    return results.whereType<ScanEntry>().toList();
  }
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

/// Files at least this large are hashed in their own isolate; smaller ones
/// are hashed inline.
///
/// SPEC §5.2 puts hashing in isolates so that a big file neither stalls the
/// event loop nor monopolises one core. Neither concern applies below this
/// size: SHA-256 over a couple of hundred kilobytes finishes in well under a
/// millisecond, while spawning an isolate costs more than that — a tree of
/// many small files would spend most of the scan starting isolates.
const _isolateThresholdBytes = 256 * 1024;

/// The SHA-256 of the file at [absolutePath], as a hex string.
Future<String> _digestOf(String absolutePath, int size) {
  return size >= _isolateThresholdBytes
      ? Isolate.run(() => _hashFile(absolutePath))
      : _hashFile(absolutePath);
}

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

  Future<ScanEntry> hash() async {
    final digest = await _digestOf(absolutePath, size);

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
