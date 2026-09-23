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
/// Despite the name, this covers every [SkippedReason], not only
/// [SkippedReason.unreadable]. [SkippedReason.caseFoldCollision] (SPEC §16)
/// is here because a path this scan found on one filesystem folding onto
/// another is a fact the reconciler cannot resolve any more than a
/// permission failure is — see [SkippedReason.isFailure]'s own doc comment.
///
/// [SkippedReason.symlink] is here too, and is not a failure. A skipped link
/// has no status for the same reason an unreadable file has none, and
/// planning around it anyway writes onto it: a regular file on the other
/// side at the link's path was copied *through* the link into whatever it
/// points at, and one beneath a skipped directory link through that
/// directory. And an archived file the user replaced with a link was
/// reported deleted and deleted from the other side. Excluding the path
/// from both questions is Unison's answer for a link it does not sync,
/// which reports the pair and propagates neither (SPEC §5.1).
///
/// The name is kept rather than widened to something like `ExcludedPaths`,
/// since every caller of this class already reads `unreadable` at a call
/// site that means "a path the scan could not stand behind a status for".
class UnreadablePaths {
  /// Root-relative paths of what the scan could not read or could not
  /// disambiguate: a file, or a directory standing in for everything under
  /// it.
  final List<String> roots;

  const UnreadablePaths(this.roots);

  /// Nothing was unreadable — what a scan with no failures reports, and the
  /// default for a caller that has no scan to speak of.
  static const none = UnreadablePaths([]);

  /// Every path across [skipped], which may be one side's list or both
  /// sides' concatenated: a path neither replica could assess and a path
  /// only one of them could are the same thing to a reconciler, which needs
  /// both sides' facts to decide anything.
  factory UnreadablePaths.from(Iterable<SkippedPath> skipped) =>
      UnreadablePaths([for (final entry in skipped) entry.path]);

  /// Whether [path] is one of [roots] or lives beneath one.
  ///
  /// Prefix-matched with the separator appended, so an unreadable `sub` does
  /// not swallow a perfectly readable `submarine.txt`.
  bool covers(String path) =>
      roots.any((root) => path == root || path.startsWith('$root/'));

  bool get isEmpty => roots.isEmpty;
}
