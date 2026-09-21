/// What a folder holds, one row per child, with SPEC §9's ignore verdict
/// already applied — the listing a filter browser draws.
///
/// Produced by `FilterPreview.listFolder`, which lists exactly one folder
/// and never descends: browsing has to stay instant on a tree whose totals
/// take seconds to count, so the two are separate calls and only the
/// totals cost a walk.
class FilterFolderEntry {
  const FilterFolderEntry({
    required this.name,
    required this.path,
    required this.kind,
    required this.sizeBytes,
    required this.excludedBy,
  });

  /// The child's own name, as the folder listed it.
  final String name;

  /// Root-relative, `/`-separated — what a rule is matched against, and
  /// what an "exclude this exact path" rule would be written as.
  final String path;

  final FilterEntryKind kind;

  /// The file's size, or `null` for anything that is not a regular file.
  final int? sizeBytes;

  /// The `ignore` pattern that keeps this out of the sync, or `null` when
  /// nothing does — [RuleSet.ignorePatternFor] over [path], so a child of
  /// an excluded folder names the folder's rule rather than looking
  /// included on its own.
  final String? excludedBy;

  /// Whether a sync would carry this, as far as the rules can say.
  ///
  /// [FilterEntryKind.other] is never in the sync: the head sets no
  /// `follow` rules, so SPEC §5.1 leaves a symlink unfollowed and reports
  /// it as skipped. That is a fact about the entry, not about the user's
  /// rules, which is why it does not produce an [excludedBy] — there is no
  /// rule to remove to bring it back.
  bool get syncs => excludedBy == null && kind != FilterEntryKind.other;
}

/// What a listed child is, as far as a preview needs to tell them apart.
enum FilterEntryKind {
  /// A regular file: it has a size and is counted.
  file,

  /// A directory: it can be opened, and its totals come from the walked
  /// report rather than from this listing.
  folder,

  /// A symlink, a device node, a socket — everything a replica does not
  /// carry (SPEC §5.1). Listed rather than hidden, because a user looking
  /// for a file they can see in a file manager has to find it here too,
  /// and be told why it is not syncing.
  other,
}
