/// What is already at a copy's destination, as far as choosing how to write
/// it goes (SPEC §7.2).
///
/// A copy writes in place (§7.6) unless that would change something the
/// user did not ask to sync, or would fail where replacing the file would
/// not. Those are the cases [writesInPlace] turns down, and each falls back
/// to writing a scratch file beside the target and renaming it over:
///
/// - **More than one hard link.** The other names share the target's
///   bytes, so an in-place write changes every one of them — including a
///   name outside the replica, with no record. A rename points only this
///   name at new bytes, which is §5.1's "hardlinks are independent regular
///   files".
/// - **Not writable.** Opening a read-only file for writing fails, and a
///   failed copy keeps its mark, so it would fail the same way on every run.
///   A rename needs the directory's permission, not the file's, and §7.4
///   sets the source's mode afterwards anyway.
/// - **Unknown.** A host whose facts could not be read gets the write that
///   is safe whatever the answer would have been.
///
/// Read *through* a followed symlink (SPEC §5.1): the facts are the
/// target's, because that is the file the write lands on.
sealed class WriteTarget {
  const WriteTarget();

  bool get writesInPlace;
}

/// Nothing at the destination yet: there are no other names and nothing to
/// be refused, so the write creates the file in place.
final class AbsentWriteTarget extends WriteTarget {
  const AbsentWriteTarget();

  @override
  bool get writesInPlace => true;
}

/// A file already at the destination, and the two facts about it that
/// decide the write.
final class ExistingWriteTarget extends WriteTarget {
  /// How many directory entries name this file — `st_nlink` on POSIX,
  /// `nNumberOfLinks` on Windows.
  final int linkCount;

  /// Whether this process may open the file for writing.
  final bool writable;

  const ExistingWriteTarget({required this.linkCount, required this.writable});

  @override
  bool get writesInPlace => linkCount <= 1 && writable;
}

/// The facts could not be read on this host at all — no binding for its
/// ABI, or the symbol is missing from its C library.
final class UnknownWriteTarget extends WriteTarget {
  final String reason;

  const UnknownWriteTarget(this.reason);

  @override
  bool get writesInPlace => false;
}
