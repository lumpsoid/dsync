import 'file_status.dart';

/// A path the reconciler will not resolve on its own (SPEC §6). `null`: that
/// side has no record of it. [interrupted]: a side holds an uncommitted
/// write.
final class ConflictInfo {
  const ConflictInfo({
    required this.path,
    required this.a,
    required this.b,
    required this.interrupted,
  });

  final String path;
  final FileStatus? a;
  final FileStatus? b;
  final bool interrupted;

  /// Whether both sides hold a file - two versions, so "keep both" can
  /// save the peer's beside this device's (SPEC §7.2). A deleted or
  /// never-written side holds none.
  bool get bothHoldAFile => _holdsAFile(a) && _holdsAFile(b);

  static bool _holdsAFile(FileStatus? status) => switch (status) {
    StatusUnchanged() ||
    StatusCreated() ||
    StatusModified() ||
    StatusUntrusted() => true,
    StatusDeleted() || StatusUntrustedAbsent() || null => false,
  };
}
