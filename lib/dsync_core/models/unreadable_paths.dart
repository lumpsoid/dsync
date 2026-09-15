import 'package:dsync/dsync_core/models/skipped_path.dart';

/// The paths a scan could not stand behind a status for, as the question
/// both the scan and the reconciler actually ask of them: *does this cover
/// the path I am holding?* (SPEC §5, §16.)
///
/// A rule rather than a list, because "covered" is not "equal". A directory
/// whose listing failed is reported as one path — the directory — but what it
/// hides is every path beneath it, and neither caller can ask its question
/// without expanding that. Extracted here rather than left in either caller
/// because both need it and they must agree: the scan uses it to decide what
/// not to call `deleted`, and the reconciler to decide what not to plan, and
/// a path one of them thought was covered while the other did not is exactly
/// the gap this closes.
///
/// Despite the name, this is not only [SkippedReason.unreadable] — it is
/// every reason [SkippedReason.isFailure] calls a failure, which today is
/// that plus [SkippedReason.caseFoldCollision] (SPEC §16): a path this scan
/// found on one filesystem folding onto another is a fact the reconciler
/// cannot resolve any more than a permission failure is, for the same
/// reason — see [SkippedReason.isFailure]'s own doc comment. The name is
/// kept rather than widened to something like `ExcludedPaths`, since every
/// caller of this class already reads `unreadable` at a call site that means
/// "path §5's per-path tolerance already covers" — SPEC §11.5 folds both
/// reasons into the same "some paths were skipped" exit-1 bucket, so callers
/// have never needed to tell them apart.
///
/// [SkippedReason.symlink] is deliberately not covered. A skipped symlink is
/// §9's rules being obeyed, and excluding those paths from reconciliation
/// would silently change how a symlink on one side and a real file on the
/// other resolve today — a separate question from this one.
class UnreadablePaths {
  /// Root-relative paths of what the scan could not read or could not
  /// disambiguate: a file, or a directory standing in for everything under
  /// it.
  final List<String> roots;

  const UnreadablePaths(this.roots);

  /// Nothing was unreadable — what a scan with no failures reports, and the
  /// default for a caller that has no scan to speak of.
  static const none = UnreadablePaths([]);

  /// Every failing path across [skipped] (see [SkippedReason.isFailure]),
  /// which may be one side's list or both sides' concatenated: a path
  /// neither replica could assess and a path only one of them could are the
  /// same thing to a reconciler, which needs both sides' facts to decide
  /// anything.
  factory UnreadablePaths.from(Iterable<SkippedPath> skipped) =>
      UnreadablePaths([
        for (final entry in skipped)
          if (entry.reason.isFailure) entry.path,
      ]);

  /// Whether [path] is one of [roots] or lives beneath one.
  ///
  /// Prefix-matched with the separator appended, so an unreadable `sub` does
  /// not swallow a perfectly readable `submarine.txt`.
  bool covers(String path) =>
      roots.any((root) => path == root || path.startsWith('$root/'));

  bool get isEmpty => roots.isEmpty;
}
