/// Answers "what would these rules sync?" over a replica root, without
/// syncing anything (SPEC §9).
///
/// Two calls, because a filter screen asks two questions at two prices:
/// [listFilterFolder] opens one folder and costs one listing, so browsing
/// is instant; [previewFilters] counts a whole tree and costs a walk, so
/// it is something a user asks for. Both apply the same [RuleSet], through
/// [RuleSet.ignorePatternFor], so a folder shown as excluded in the
/// browser is excluded in the totals for the rule the browser named.
///
/// **Neither hashes, neither opens a file.** This is a listing plus a stat
/// per file, which is why it can run over a tree a scan would take a
/// minute on. It follows that the numbers are about *files present*, not
/// about work a run would do: a run skips what both replicas already
/// agree on, so a preview's "1,204 files will sync" is what the sync
/// covers, not what it transfers.
///
/// **Symlinks are listed and counted as neither.** The walk lists with
/// `followLinks: false` and a link lands as [FilterEntryKind.other]: the
/// head sets no `follow` rules, so SPEC §5.1 has a scan report the link as
/// skipped and carry nothing. Counting a link's target would claim bytes
/// no run would move, and following one would let a link out of the tree
/// inflate the total with a folder that is not in the replica at all.
library;

import 'dart:io';

import 'package:dsync/dsync_core/models/filter_folder_entry.dart';
import 'package:dsync/dsync_core/models/filter_preview_report.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:path/path.dart' as p;

/// Walks [rootPath] and counts what [rules] keeps and drops.
///
/// Unlike a scan, the walk **descends into an excluded folder** instead of
/// pruning it. Pruning is right for a run — a pruned subtree must never
/// read as a tree of deletions — but a preview exists to say how much a
/// rule removes, and a walk that stopped at the folder could only say
/// "some". Everything under an excluded folder is attributed to that
/// folder's rule, which is the rule that would have to go for any of it to
/// sync.
///
/// A folder that cannot be listed is recorded in
/// [FilterPreviewReport.unreadableFolders] and the walk continues, the way
/// SPEC §5's per-path rule has a scan continue. The **root** is the
/// exception and throws, for the reason `Scanner.scan` gives: there is no
/// tree to report on, and reporting an empty one would read as "these
/// rules exclude everything".
Future<FilterPreviewReport> previewFilters({
  required String rootPath,
  required RuleSet rules,
}) async {
  final excludedByPattern = {
    for (final pattern in rules.ignorePatterns) pattern: 0,
  };
  final unreadable = <String>[];
  final counters = _Counters(excludedByPattern, unreadable);

  // Listed here rather than inside the recursion so a root that cannot be
  // read throws instead of being recorded as one more unreadable folder.
  final entries = await Directory(rootPath).list(followLinks: false).toList();
  final root = await _walkFolder(
    rootPath: rootPath,
    relativePath: '',
    entries: entries,
    excludedBy: null,
    rules: rules,
    counters: counters,
  );

  return FilterPreviewReport(
    rootPath: rootPath,
    root: root,
    excludedFilesByPattern: excludedByPattern,
    unreadableFolders: unreadable,
  );
}

/// The children of [relativePath] under [rootPath] — `''` for the root
/// itself — each with [rules]' verdict already on it.
///
/// Ordered folders first, then files and everything else, each group by
/// name, case-insensitively: a browser's order is part of whether it can
/// be scanned by eye, and putting it here keeps every caller's order the
/// same as the walk's.
///
/// Throws [FileSystemException] when the folder cannot be listed — a
/// browser has nothing to draw in that case, and the caller says so.
Future<List<FilterFolderEntry>> listFilterFolder({
  required String rootPath,
  required String relativePath,
  required RuleSet rules,
}) async {
  final directory = Directory(_osPath(rootPath, relativePath));
  final entries = <FilterFolderEntry>[];
  await for (final entity in directory.list(followLinks: false)) {
    final name = p.basename(entity.path);
    final path = relativePath.isEmpty ? name : '$relativePath/$name';
    final kind = _kindOf(entity);
    entries.add(
      FilterFolderEntry(
        name: name,
        path: path,
        kind: kind,
        sizeBytes: kind == FilterEntryKind.file ? await _sizeOf(entity) : null,
        excludedBy: kind == FilterEntryKind.other
            ? null
            : rules.ignorePatternFor(path),
      ),
    );
  }
  entries.sort(_byFoldersThenName);
  return entries;
}

int _byFoldersThenName(FilterFolderEntry a, FilterFolderEntry b) {
  final aFolder = a.kind == FilterEntryKind.folder;
  final bFolder = b.kind == FilterEntryKind.folder;
  if (aFolder != bFolder) return aFolder ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// Accumulates one folder's subtree into a [FilterPreviewFolder].
///
/// [excludedBy] is the pattern that already excludes an ancestor, or
/// `null`; it wins over anything this folder's own path matches, so the
/// rule reported is the shallowest one — the same rule
/// [RuleSet.ignorePatternFor] names for a path under it.
Future<FilterPreviewFolder> _walkFolder({
  required String rootPath,
  required String relativePath,
  required List<FileSystemEntity> entries,
  required String? excludedBy,
  required RuleSet rules,
  required _Counters counters,
}) async {
  entries.sort(
    (a, b) => p
        .basename(a.path)
        .toLowerCase()
        .compareTo(p.basename(b.path).toLowerCase()),
  );

  var includedFiles = 0;
  var includedBytes = 0;
  var excludedFiles = 0;
  var excludedBytes = 0;
  final folders = <FilterPreviewFolder>[];

  for (final entity in entries) {
    final name = p.basename(entity.path);
    final path = relativePath.isEmpty ? name : '$relativePath/$name';
    final entryExcludedBy = excludedBy ?? rules.ignorePatternFor(path);

    switch (_kindOf(entity)) {
      case FilterEntryKind.folder:
        final List<FileSystemEntity> children;
        try {
          children = await Directory(entity.path)
              .list(followLinks: false)
              .toList();
        } on FileSystemException {
          counters.unreadable.add(path);
          continue;
        }
        final folder = await _walkFolder(
          rootPath: rootPath,
          relativePath: path,
          entries: children,
          excludedBy: entryExcludedBy,
          rules: rules,
          counters: counters,
        );
        folders.add(folder);
        includedFiles += folder.includedFiles;
        includedBytes += folder.includedBytes;
        excludedFiles += folder.excludedFiles;
        excludedBytes += folder.excludedBytes;
      case FilterEntryKind.file:
        // A file that vanished between the listing and the stat is left
        // out of both totals rather than guessed at: it is not there to
        // sync, and a preview is a picture of the tree as it is now.
        final size = await _sizeOf(entity);
        if (size == null) continue;
        if (entryExcludedBy == null) {
          includedFiles += 1;
          includedBytes += size;
        } else {
          excludedFiles += 1;
          excludedBytes += size;
          counters.bump(entryExcludedBy);
        }
      case FilterEntryKind.other:
        // Carried by no run, so counted against no rule — see the library
        // doc comment.
        continue;
    }
  }

  return FilterPreviewFolder(
    path: relativePath,
    excludedBy: excludedBy,
    includedFiles: includedFiles,
    includedBytes: includedBytes,
    excludedFiles: excludedFiles,
    excludedBytes: excludedBytes,
    folders: folders,
  );
}

FilterEntryKind _kindOf(FileSystemEntity entity) => switch (entity) {
  Directory() => FilterEntryKind.folder,
  File() => FilterEntryKind.file,
  _ => FilterEntryKind.other,
};

/// The file's size, or `null` when it can no longer be stat'ed.
Future<int?> _sizeOf(FileSystemEntity entity) async {
  final stat = await entity.stat();
  if (stat.type == FileSystemEntityType.notFound) return null;
  return stat.size;
}

/// The two running totals a walk threads through every folder: the
/// per-rule counts and the folders it could not read. One object rather
/// than two parameters repeated down the recursion, and mutable on
/// purpose — a walk that rebuilt a map per file would allocate one per
/// file.
class _Counters {
  const _Counters(this.excludedByPattern, this.unreadable);

  final Map<String, int> excludedByPattern;
  final List<String> unreadable;

  void bump(String pattern) {
    excludedByPattern[pattern] = (excludedByPattern[pattern] ?? 0) + 1;
  }
}

/// [relativePath] as a path on this host, under [rootPath].
String _osPath(String rootPath, String relativePath) => relativePath.isEmpty
    ? rootPath
    : p.joinAll([rootPath, ...relativePath.split('/')]);
