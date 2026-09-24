/// One entry of a browsed folder.
final class FilterRow {
  const FilterRow({
    required this.path,
    required this.name,
    required this.size,
    required this.isFolder,
    required this.excludedBy,
    required this.syncs,
  });

  final String path;
  final String name;

  /// A file's size; `null` for a folder or anything no run carries.
  final int? size;
  final bool isFolder;
  final String? excludedBy;

  /// Whether a run would carry it.
  final bool syncs;
}
