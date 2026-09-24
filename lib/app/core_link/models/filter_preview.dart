import 'filter_folder_summary.dart';

/// What the ignore rules keep of a tree (SPEC §9): every folder in
/// pre-order, how many files each rule removed, and the folders that could
/// not be listed.
final class FilterPreview {
  const FilterPreview({
    required this.folders,
    required this.excludedByRule,
    required this.unreadableFolders,
  });

  final List<FilterFolderSummary> folders;
  final Map<String, int> excludedByRule;
  final List<String> unreadableFolders;
}
