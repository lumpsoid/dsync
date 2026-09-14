import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/temp_file.dart';

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

  Scanner({this.jobs = 4});

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
    final hashed = await _hashAll(context.pendingHash);

    return ScanResult(
      entries: [
        ...context.fastPath,
        ...hashed,
        for (final path in archive.entries.keys)
          if (!context.seen.contains(path) && !context.rules.ignores(path))
            ScanEntry.deleted(path),
      ],
      skippedSymlinks: context.skippedSymlinks,
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
    final children = await dir.list(followLinks: false).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final child in children) {
      final name = child.path.split('/').last;
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
            context.skippedSymlinks.add(relativePath);
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
      context.skippedSymlinks.add(relativePath);
      return;
    }

    switch (await FileSystemEntity.type(target)) {
      case FileSystemEntityType.directory:
        if (context.openDirs.contains(target)) {
          // The link points at a directory this walk is already inside, so
          // following it would descend through itself without end.
          context.skippedSymlinks.add(relativePath);
          return;
        }
        await _walk(Directory(target), relativePath, context);
      case FileSystemEntityType.file:
        await _visitFile(File(target), relativePath, context);
      default:
        context.skippedSymlinks.add(relativePath);
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

  /// Hashes every candidate with at most [jobs] concurrent isolates.
  Future<List<ScanEntry>> _hashAll(List<_HashCandidate> candidates) async {
    if (candidates.isEmpty) return const [];

    final results = List<ScanEntry?>.filled(candidates.length, null);
    var next = 0;

    Future<void> worker() async {
      while (next < candidates.length) {
        final index = next++;
        results[index] = await candidates[index].hash();
      }
    }

    final workerCount = jobs.clamp(1, candidates.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results.cast<ScanEntry>();
  }
}

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
  final List<String> skippedSymlinks = [];
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
