import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';

/// Scans a replica's file tree and compares it against its own archive
/// (SPEC §5).
///
/// Only the initiating side ever needs the archive of the *other* replica —
/// each side reports statuses relative to its own archive, which is enough
/// for reconciliation (SPEC §5, §6).
class Scanner {
  final RuleSet rules;

  /// Hashing concurrency (SPEC §5.2: "hashing runs in isolates, parallelism
  /// configurable").
  final int jobs;

  Scanner({RuleSet? rules, this.jobs = 4}) : rules = rules ?? RuleSet();

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
  Future<List<ScanEntry>> scan({
    required String rootPath,
    required Archive archive,
  }) async {
    final context = _ScanContext(archive);
    await _walk(Directory(rootPath), '', context);
    final hashed = await _hashAll(context.pendingHash);

    return [
      ...context.fastPath,
      ...hashed,
      for (final path in archive.entries.keys)
        if (!context.seen.contains(path) && !rules.ignores(path))
          ScanEntry.deleted(path),
    ];
  }

  Future<void> _walk(
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
      if (rules.ignores(relativePath)) continue;

      switch (await FileSystemEntity.type(child.path, followLinks: false)) {
        case FileSystemEntityType.directory:
          await _walk(Directory(child.path), relativePath, context);
        case FileSystemEntityType.file:
          await _visitFile(File(child.path), relativePath, context);
        case FileSystemEntityType.link:
          if (rules.follows(relativePath)) {
            await _visitLink(child.path, relativePath, context);
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
      return; // broken link: nothing to scan
    }

    switch (await FileSystemEntity.type(target)) {
      case FileSystemEntityType.directory:
        await _walk(Directory(target), relativePath, context);
      case FileSystemEntityType.file:
        await _visitFile(File(target), relativePath, context);
      default:
        break;
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

    if (existing != null && existing.size == size && existing.mtime == mtime) {
      context.fastPath.add(
        ScanEntry(
          path: relativePath,
          status: ScanStatus.unchanged,
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
        file: file,
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
  final Set<String> seen = {};
  final List<ScanEntry> fastPath = [];
  final List<_HashCandidate> pendingHash = [];

  _ScanContext(this.archive);
}

/// A file whose fast path (SPEC §5.2 step 1) didn't resolve it, so its
/// content must be hashed to tell unchanged, created, and modified apart.
class _HashCandidate {
  final File file;
  final String path;
  final int size;
  final int mtime;
  final int mode;
  final ArchiveEntry? existing;

  _HashCandidate({
    required this.file,
    required this.path,
    required this.size,
    required this.mtime,
    required this.mode,
    required this.existing,
  });

  Future<ScanEntry> hash() async {
    final bytes = await file.readAsBytes();
    final digest = await Isolate.run(() => sha256.convert(bytes).toString());

    final existing = this.existing;
    final status = existing == null
        ? ScanStatus.created
        : (existing.hash == digest
              ? ScanStatus.unchanged
              : ScanStatus.modified);

    return ScanEntry(
      path: path,
      status: status,
      size: size,
      mtime: mtime,
      mode: mode,
      hash: digest,
    );
  }
}
