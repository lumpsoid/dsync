/// One folder of a filter preview. A folder's subfolders follow it in the
/// preview's list, one [depth] deeper.
final class FilterFolderSummary {
  const FilterFolderSummary({
    required this.path,
    required this.depth,
    required this.excludedBy,
    required this.includedFiles,
    required this.includedBytes,
    required this.excludedFiles,
    required this.excludedBytes,
  });

  /// `null`: the root.
  final String? path;
  final int depth;
  final String? excludedBy;
  final int includedFiles;
  final int includedBytes;
  final int excludedFiles;
  final int excludedBytes;
}
