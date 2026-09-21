/// What a [RuleSet] would keep and drop over one replica root, counted by
/// walking it — the answer to "which files enter the sync after filtering"
/// (SPEC §9).
///
/// **Counted, not scanned.** A [Scanner] run answers a different question
/// (what changed since the archive) and pays for it with a hash of every
/// file whose metadata drifted. A preview needs neither hashes nor an
/// archive: it needs a listing, a size per file, and SPEC §9's ignore
/// decision. So this is produced by `FilterPreview`, not by the scanner,
/// and nothing in a run reads it.
///
/// **Directories only.** The tree under [root] holds one node per folder
/// with the subtree totals beneath it, and no node per file: a browser
/// showing one folder at a time lists that folder's files from disk in a
/// single cheap call, while the numbers it shows beside a *subfolder* are
/// exactly what a walk had to visit the whole subtree to know. Holding
/// every file path here instead would mean carrying a hundred thousand
/// strings to render twenty rows.
class FilterPreviewReport {
  const FilterPreviewReport({
    required this.rootPath,
    required this.root,
    required this.excludedFilesByPattern,
    required this.unreadableFolders,
  });

  /// The absolute path the walk covered — the local replica root.
  final String rootPath;

  /// The root folder's node: its totals are the whole tree's.
  final FilterPreviewFolder root;

  /// Every `ignore` pattern in the rule set this was walked with, mapped to
  /// the number of files it excluded — `0` for a pattern that matched
  /// nothing.
  ///
  /// Present with a zero rather than absent, because "this rule removes
  /// nothing" is the fact a user most needs off a rule list: it is what a
  /// typo in a pattern looks like. A file excluded by several rules is
  /// counted against one of them only — the one [RuleSet.ignorePatternFor]
  /// names — so these sum to [excludedFiles] instead of double-counting.
  final Map<String, int> excludedFilesByPattern;

  /// Root-relative paths of folders the walk could not list, in the order
  /// it met them.
  ///
  /// Reported rather than swallowed: their contents are in neither total,
  /// so a summary that stayed silent about them would be quietly short by
  /// however much is under them. A run meets the same folders and records
  /// them as SPEC §5 skipped paths.
  final List<String> unreadableFolders;

  /// Files that would enter the sync.
  int get includedFiles => root.includedFiles;

  /// Bytes those files hold.
  int get includedBytes => root.includedBytes;

  /// Files the rules keep out.
  int get excludedFiles => root.excludedFiles;

  /// Bytes those files hold.
  int get excludedBytes => root.excludedBytes;

  /// The node for [relativePath] — `''` for the root — or `null` when the
  /// walk never recorded such a folder, which is what a folder created
  /// since this preview ran looks like.
  FilterPreviewFolder? folderAt(String relativePath) {
    if (relativePath.isEmpty) return root;
    var folder = root;
    for (final segment in relativePath.split('/')) {
      FilterPreviewFolder? next;
      for (final child in folder.folders) {
        if (child.name == segment) {
          next = child;
          break;
        }
      }
      if (next == null) return null;
      folder = next;
    }
    return folder;
  }
}

/// One folder in a [FilterPreviewReport], with its whole subtree's counts.
///
/// The counts are subtree totals, not this folder's own files: the number
/// a browser puts beside a folder row is what syncing that folder costs,
/// and a figure that stopped at its direct children would read as that but
/// not be it.
class FilterPreviewFolder {
  const FilterPreviewFolder({
    required this.path,
    required this.excludedBy,
    required this.includedFiles,
    required this.includedBytes,
    required this.excludedFiles,
    required this.excludedBytes,
    required this.folders,
  });

  /// Root-relative, `/`-separated; `''` for the replica root itself.
  final String path;

  /// The `ignore` pattern that excludes this folder and everything under
  /// it, or `null` when the folder itself is in the sync.
  ///
  /// A folder with this set still carries counts, and they land in
  /// [excludedFiles]: a preview that pruned where the scan prunes could
  /// say a folder is excluded but never how much that excludes, which is
  /// the number the user is deciding on.
  final String? excludedBy;

  final int includedFiles;
  final int includedBytes;
  final int excludedFiles;
  final int excludedBytes;

  /// Direct subfolders, in the order the walk listed them.
  final List<FilterPreviewFolder> folders;

  /// The folder's own name — its last path segment, and `''` for the root.
  String get name => path.split('/').last;
}
